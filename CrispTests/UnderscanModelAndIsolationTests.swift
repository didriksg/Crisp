import CoreGraphics
import Foundation
import XCTest

final class UnderscanModelAndIsolationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.reconditum.crisp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Value validation & min/max bounds

    func testUnderscanValueValidationAcceptsBoundaryPercentages() {
        XCTAssertEqual(UnderscanValue.validatePercentage(75), .success(75))
        XCTAssertEqual(UnderscanValue.validatePercentage(90), .success(90))
        XCTAssertEqual(UnderscanValue.validatePercentage(100), .success(100))
    }

    func testUnderscanValueValidationRejectsOutOfRangeValues() {
        XCTAssertEqual(
            UnderscanValue.validatePercentage(74),
            .failure(.invalidValue(74, 75...100))
        )
        XCTAssertEqual(
            UnderscanValue.validatePercentage(101),
            .failure(.invalidValue(101, 75...100))
        )
        XCTAssertEqual(
            UnderscanValue.validatePercentage(-5),
            .failure(.invalidValue(-5, 75...100))
        )
    }

    func testHardwareRangeValidationRejectsOverscanOrInvertedBounds() {
        XCTAssertEqual(UnderscanValue.validatedHardwareRange(minRaw: 7500, maxRaw: 10000), 7500...10000)
        XCTAssertEqual(UnderscanValue.validatedHardwareRange(minRaw: 8000, maxRaw: 10000), 8000...10000)
        XCTAssertNil(UnderscanValue.validatedHardwareRange(minRaw: 0, maxRaw: 0))
        XCTAssertNil(UnderscanValue.validatedHardwareRange(minRaw: 10000, maxRaw: 7500))
        XCTAssertNil(UnderscanValue.validatedHardwareRange(minRaw: 7500, maxRaw: 10500))
        XCTAssertNil(UnderscanValue.validatedHardwareRange(minRaw: 4000, maxRaw: 10000))
    }

    func testRawAndPercentageConversionsRoundTripCleanly() {
        XCTAssertEqual(UnderscanValue.rawValue(forPercentage: 75, clampedTo: 7500...10000), 7500)
        XCTAssertEqual(UnderscanValue.rawValue(forPercentage: 92, clampedTo: 7500...10000), 9200)
        XCTAssertEqual(UnderscanValue.rawValue(forPercentage: 100, clampedTo: 7500...10000), 10000)
        XCTAssertEqual(UnderscanValue.rawValue(forPercentage: 70, clampedTo: 8000...10000), 8000)
        XCTAssertEqual(UnderscanValue.percentage(fromRaw: 9621), 96)
        XCTAssertEqual(UnderscanValue.percentage(fromRaw: 10000), 100)
        XCTAssertEqual(UnderscanValue.percentageRange(forRawRange: 8000...10000), 80...100)
    }

    // MARK: - Display identity, reassigned IDs, and identical monitor models

    func testStableKeySurvivesDisplayIDReassignment() {
        let before = DisplayUnderscanDescriptor(
            displayID: 5,
            cgUUID: "9A885E72-A91D-4814-BBCD-501CB24E539C",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 123456,
            channelLocation: "IOService:/AppleARMPE/dispext0",
            isBuiltin: false,
            displayName: "ASUS ProArt PA278QV"
        )
        let after = DisplayUnderscanDescriptor(
            displayID: 42,
            cgUUID: "9a885e72-a91d-4814-bbcd-501cb24e539c",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 123456,
            channelLocation: "IOService:/AppleARMPE/dispext0",
            isBuiltin: false,
            displayName: "ASUS ProArt PA278QV"
        )
        XCTAssertEqual(
            DisplayUnderscanIdentity.stableKey(for: before, among: [before]),
            DisplayUnderscanIdentity.stableKey(for: after, among: [after])
        )
    }

    func testIdenticalMonitorModelsDoNotShareSettingsKey() {
        let leftProArt = DisplayUnderscanDescriptor(
            displayID: 11,
            cgUUID: "AAAA-1111",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 0,
            channelLocation: "IOService:/AppleARMPE/dispext0/port0",
            isBuiltin: false,
            displayName: "ASUS ProArt"
        )
        let rightProArt = DisplayUnderscanDescriptor(
            displayID: 12,
            cgUUID: "AAAA-1111",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 0,
            channelLocation: "IOService:/AppleARMPE/dispext1/port1",
            isBuiltin: false,
            displayName: "ASUS ProArt"
        )
        let live = [leftProArt, rightProArt]
        let leftKey = DisplayUnderscanIdentity.stableKey(for: leftProArt, among: live)
        let rightKey = DisplayUnderscanIdentity.stableKey(for: rightProArt, among: live)
        XCTAssertNotEqual(leftKey, rightKey)
        XCTAssertTrue(leftKey.contains("@loc-"))
        XCTAssertTrue(rightKey.contains("@loc-"))
    }

    func testIdenticalUnserializedMonitorsWithDifferentUUIDsStillDisambiguateByLocation() {
        let monitorA = DisplayUnderscanDescriptor(
            displayID: 21,
            cgUUID: "UUID-A",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 0,
            channelLocation: "port-left",
            isBuiltin: false,
            displayName: "ASUS ProArt"
        )
        let monitorB = DisplayUnderscanDescriptor(
            displayID: 22,
            cgUUID: "UUID-B",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 0,
            channelLocation: "port-right",
            isBuiltin: false,
            displayName: "ASUS ProArt"
        )
        let keyA = DisplayUnderscanIdentity.stableKey(for: monitorA, among: [monitorA, monitorB])
        let keyB = DisplayUnderscanIdentity.stableKey(for: monitorB, among: [monitorA, monitorB])
        XCTAssertNotEqual(keyA, keyB)
    }

    func testPlaceholderZeroUUIDFallsBackToEDIDAndLocation() {
        let monitor = DisplayUnderscanDescriptor(
            displayID: 7,
            cgUUID: "00000000-0000-0000-0000-000000000000",
            vendorNumber: 0x58B3,
            modelNumber: 0x3700,
            serialNumber: 0,
            channelLocation: "hdmi-port-0",
            isBuiltin: false,
            displayName: "External"
        )
        let key = DisplayUnderscanIdentity.stableKey(for: monitor, among: [monitor])
        XCTAssertTrue(key.hasPrefix("edid-v58b3-m3700-s00000000@loc-"))
    }

    // MARK: - Persistence & legacy migration

    func testStorePersistsIndependentSettingsPerMonitor() {
        let store = UnderscanStore(defaults: defaults)
        var settingsA = DisplayUnderscanSettings(isEnabled: true, requestedPercentage: 92)
        settingsA.restoreAfterSleep = false
        var settingsB = DisplayUnderscanSettings(isEnabled: true, requestedPercentage: 85)
        settingsB.forceEnableExperimental = true

        store.save(settingsA, forKey: "MON-A")
        store.save(settingsB, forKey: "MON-B")

        XCTAssertEqual(store.settings(forKey: "MON-A"), settingsA)
        XCTAssertEqual(store.settings(forKey: "MON-B"), settingsB)
        XCTAssertEqual(store.settings(forKey: "MON-UNKNOWN"), DisplayUnderscanSettings())
    }

    func testStoreMigratesLegacyDisplayIDEntriesSafelyWithoutGuessingOfflineIDs() throws {
        let store = UnderscanStore(defaults: defaults)
        let liveMonitor = DisplayUnderscanDescriptor(
            displayID: 15,
            cgUUID: "LIVE-UUID-15",
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: 99,
            isBuiltin: false,
            displayName: "ProArt"
        )
        let legacyLive = DisplayUnderscanSettings(isEnabled: true, requestedPercentage: 88)
        let legacyOffline = DisplayUnderscanSettings(isEnabled: true, requestedPercentage: 80)

        defaults.set(try JSONEncoder().encode(legacyLive), forKey: DisplayUnderscanIdentity.legacyDisplayIDKey(for: 15))
        defaults.set(try JSONEncoder().encode(legacyOffline), forKey: DisplayUnderscanIdentity.legacyDisplayIDKey(for: 999))

        let migrated = store.migrateLegacyDisplayIDEntries(for: [liveMonitor])
        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(store.settings(forKey: "LIVE-UUID-15").requestedPercentage, 88)
        XCTAssertNil(defaults.data(forKey: DisplayUnderscanIdentity.legacyDisplayIDKey(for: 15)))
        // Offline legacy entry stays untouched rather than misattributed.
        XCTAssertNotNil(defaults.data(forKey: DisplayUnderscanIdentity.legacyDisplayIDKey(for: 999)))
    }

    func testPartialOrLegacySettingsPayloadDecodesWithSafeDefaults() throws {
        let partialJSON = Data(#"{"isEnabled":true,"requestedPercentage":120}"#.utf8)
        let decoded = try JSONDecoder().decode(DisplayUnderscanSettings.self, from: partialJSON)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.requestedPercentage, 100) // clamped from 120
        XCTAssertTrue(decoded.rememberValue)
        XCTAssertTrue(decoded.autoRestore)
        XCTAssertFalse(decoded.forceEnableExperimental)
        XCTAssertFalse(decoded.autoRestoreSuspended)
    }

    func testCorruptedStorePayloadDoesNotCrashAndReturnsDefaults() {
        defaults.set(Data("not-valid-json".utf8), forKey: UnderscanStore.storageKey)
        let store = UnderscanStore(defaults: defaults)
        XCTAssertEqual(store.loadAll(), [:])
        XCTAssertEqual(store.settings(forKey: "ANY"), DisplayUnderscanSettings())
    }

    // MARK: - Development build isolation

    func testProductionBundlePreservesUpstreamIdentifiersAndUpdater() {
        let prod = AppIsolation.productionBundleIdentifier
        XCTAssertFalse(AppIsolation.isIsolatedBuild(bundleIdentifier: prod))
        XCTAssertEqual(AppIsolation.lockFileName(bundleIdentifier: prod), "crisp.lock")
        XCTAssertEqual(AppIsolation.controlSocketFileName(bundleIdentifier: prod), "crispctl.sock")
        XCTAssertEqual(AppIsolation.applicationSupportDirectoryName(bundleIdentifier: prod), "Crisp")
        XCTAssertTrue(AppIsolation.shouldAutoRegisterLaunchAtLogin(bundleIdentifier: prod))
        XCTAssertTrue(AppIsolation.shouldStartSparkleUpdater(
            bundleIdentifier: prod,
            infoDictionary: ["SUFeedURL": "https://crispmac.app/appcast.xml"]
        ))
    }

    func testCustomDevelopmentBundleIsFullyIsolatedAndDisablesSparkle() {
        let dev = "com.reconditum.crisp"
        XCTAssertTrue(AppIsolation.isIsolatedBuild(bundleIdentifier: dev))
        XCTAssertEqual(AppIsolation.lockFileName(bundleIdentifier: dev), "crisp-com.reconditum.crisp.lock")
        XCTAssertEqual(AppIsolation.controlSocketFileName(bundleIdentifier: dev), "crispctl-com.reconditum.crisp.sock")
        XCTAssertEqual(AppIsolation.applicationSupportDirectoryName(bundleIdentifier: dev), "Crisp-com.reconditum.crisp")
        XCTAssertFalse(AppIsolation.shouldAutoRegisterLaunchAtLogin(bundleIdentifier: dev))
        // Even if SUFeedURL is present, isolated dev builds must never auto-update from upstream.
        XCTAssertFalse(AppIsolation.shouldStartSparkleUpdater(
            bundleIdentifier: dev,
            infoDictionary: ["SUFeedURL": "https://crispmac.app/appcast.xml"]
        ))
    }

    func testExplicitInfoPlistFlagDisablesSparkleEvenForProductionBundleID() {
        XCTAssertFalse(AppIsolation.shouldStartSparkleUpdater(
            bundleIdentifier: AppIsolation.productionBundleIdentifier,
            infoDictionary: [
                "SUFeedURL": "https://crispmac.app/appcast.xml",
                AppIsolation.disableUpdaterInfoKey: true
            ]
        ))
    }
}
