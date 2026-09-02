import AppKit
import Foundation
import IOKit
import UserNotifications
import os

/// Tells the user, once, when a display they disconnected has been plugged back in and Crisp is
/// keeping it off.
///
/// A disconnected display is switched off at the window server: it shows no signal, System
/// Settings does not list it, and replugging the cable does not undo it, because the window
/// server holds that state and not the cable. Since the choice now outlives a replug and a
/// reboot (`PhysicalDisplayToggleService.reconcile`), someone who comes back to that monitor
/// months later has every reason to think it died. This is the one moment worth interrupting
/// them for, and the banner carries the way out with it.
///
/// It tells; it never decides. Crisp does not take the disconnect back on its own: a physical
/// replug cannot be told apart from a dock re-enumerating everything on it, or from a
/// DisplayPort monitor being switched off and on, so acting on it would undo a deliberate choice
/// at times the user never asked for. Reconnecting stays the user's action, from here or from
/// the menu.
@MainActor
final class DisconnectNoticeService: NSObject {
    static let shared = DisconnectNoticeService()
    private override init() { super.init() }

    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "notice")

    private static let categoryID = "crisp.display.keptDisconnected"
    private static let reconnectAction = "crisp.display.keptDisconnected.reconnect"
    private static let lastNoticeKey = "crisp.keptDisconnected.lastNotice"
    /// A display that turns up at login or straight after a wake is the feature working, not
    /// somebody standing at the machine wondering why it is dark. Only one that arrives
    /// mid-session is worth a banner — which is also exactly the case this exists for: walking
    /// up to the monitor, plugging it in, and getting nothing.
    private static let settleWindow: TimeInterval = 60
    /// At most one banner per display per day, so a marginal cable that re-enumerates every few
    /// minutes cannot turn this into a stream.
    private static let quietPeriod: TimeInterval = 24 * 60 * 60

    private var quietUntil: Date = .distantFuture
    private var attachPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    /// False until the initial drain below has consumed the displays that were already attached.
    private var armed = false

    /// Called once at launch. Registers the category so the banner can carry a Reconnect button,
    /// and starts the post-launch quiet window. Authorization is deliberately NOT requested
    /// here; see `displayKeptDisconnected`.
    func start() {
        quietUntil = Date().addingTimeInterval(Self.settleWindow)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(
            identifier: Self.reconnectAction,
            title: String(localized: "Reconnect"),
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [action], intentIdentifiers: [])
        ])
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.quietUntil = Date().addingTimeInterval(Self.settleWindow)
                }
            }
        }
        startWatchingAttachments()
    }

    // MARK: - Watching the cable

    /// Watches IOKit for a display arriving on a cable, because above IOKit nothing happens at
    /// all. Measured live, unplugging and replugging the HDMI cable of a display Crisp was
    /// holding disconnected (registry entry IDs, and the service events as they fired):
    ///
    ///     [03:24:15] EVENT terminate id=4294977625        <- cable out
    ///     [03:24:15] framebuffer 4294969518:-             ...same object, name cleared
    ///     [03:24:23] EVENT publish   id=4294978031        <- cable back in
    ///     [03:24:24] framebuffer 4294969518:E241Y G0      ...same object, name restored
    ///
    /// Two things that decide the shape of this. The window server never moves: a disabled
    /// display does not leave `SLSGetDisplayList` and never re-enters the online list, so there
    /// is no reconfiguration callback and no CoreGraphics event to hang this on — which is the
    /// same reason the user is standing there puzzled, replugging changes nothing they can see.
    /// And the framebuffer service is the wrong thing to watch: its object outlives the cable
    /// and only its properties change, so it publishes nothing. The AV service proxy is the one
    /// that is actually created and destroyed with the cable.
    ///
    /// It carries no EDID of its own, so it is the trigger and the framebuffer is the identity:
    /// the display's name comes back about 0.4s after the event, hence the delayed reads below.
    private func startWatchingAttachments() {
        guard attachPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        attachPort = port
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let service = Unmanaged<DisconnectNoticeService>.fromOpaque(refcon).takeUnretainedValue()
            var arrived = false
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                arrived = true
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard arrived else { return }
            MainActor.assumeIsolated { service.cableArrived() }
        }
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("DCPAVServiceProxy"),
            callback, Unmanaged.passUnretained(self).toOpaque(), &attachIterator
        )
        // The first drain is every display already attached, which is not news. It is also what
        // arms the notification, so it has to happen either way.
        var entry = IOIteratorNext(attachIterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(attachIterator)
        }
        armed = true
    }

    /// A cable arrived. The display behind it names itself a moment later, so look a few times
    /// rather than once; anything already notified today is dropped by the limiter anyway.
    private func cableArrived() {
        guard armed else { return }
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.notifyHeldDisplaysPresent()
            }
        }
    }

    /// Every display currently naming itself in the registry, by the name in its own EDID.
    private func attachedProductNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: Set<String> = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let name = Self.productName(of: entry) { names.insert(name) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return names
    }

    /// The monitor's own name, as the display reports it in its EDID.
    private nonisolated static func productName(of entry: io_registry_entry_t) -> String? {
        guard let attributes = IORegistryEntryCreateCFProperty(
            entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any]
        else { return nil }
        return product["ProductName"] as? String
    }

    /// Say something for any display Crisp is holding off that is attached right now. Matched by
    /// the name the display reports: two identical monitors would share one, so the banner can
    /// name the right model on the wrong unit — acceptable for a message whose only action is to
    /// reconnect a record the user made themselves.
    private func notifyHeldDisplaysPresent() {
        let attached = attachedProductNames()
        guard !attached.isEmpty else { return }
        for record in PhysicalDisplayToggleService.shared.disconnected where attached.contains(record.name) {
            displayKeptDisconnected(record)
        }
    }

    /// Say it: a display the user disconnected is here and Crisp is keeping it off. Reached
    /// from the cable watcher above, and from the display-list path (macOS re-enabling a
    /// remembered display mid-session), which is why the day limiter below is per display rather
    /// than per event.
    func displayKeptDisconnected(_ record: PhysicalDisplayToggleService.DisconnectedDisplay) {
        guard Date() >= quietUntil, !recentlyNotified(record.uuid) else { return }
        markNotified(record.uuid)

        // Only plain strings cross into the callback below: the notification objects are not
        // Sendable, so they are built on the other side of it.
        let title = record.name
        let body = String(localized: "Crisp is keeping this display disconnected. Choose Reconnect to bring it back.")
        let displayUUID = record.uuid
        let category = Self.categoryID

        // Authorization is asked here rather than at launch, on purpose: the prompt then arrives
        // at the one moment it can be answered from experience, and someone who never reaches
        // this state is never asked at all. Repeat calls do not re-prompt, they return the
        // standing answer.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Self.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = ["uuid": displayUUID]
            let request = UNNotificationRequest(
                identifier: "crisp.keptDisconnected.\(displayUUID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { addError in
                if let addError {
                    Self.log.error("Could not post the kept-disconnected notice: \(addError.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func recentlyNotified(_ displayUUID: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: Self.lastNoticeKey) as? [String: Double] ?? [:]
        guard let last = map[displayUUID] else { return false }
        return Date().timeIntervalSinceReferenceDate - last < Self.quietPeriod
    }

    private func markNotified(_ displayUUID: String) {
        var map = UserDefaults.standard.dictionary(forKey: Self.lastNoticeKey) as? [String: Double] ?? [:]
        map[displayUUID] = Date().timeIntervalSinceReferenceDate
        UserDefaults.standard.set(map, forKey: Self.lastNoticeKey)
    }
}

extension DisconnectNoticeService: UNUserNotificationCenterDelegate {
    /// The Reconnect button. The default action (clicking the banner itself) deliberately does
    /// nothing: bringing a display back is not what someone means by dismissing a banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let displayUUID = response.notification.request.content.userInfo["uuid"] as? String
        Task { @MainActor in
            if actionID == Self.reconnectAction, let displayUUID {
                _ = await PhysicalDisplayToggleService.shared.reconnect(uuid: displayUUID)
            }
            completionHandler()
        }
    }

    /// Crisp is a menu bar app, so it can be frontmost with nothing on screen; show the banner
    /// either way.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
