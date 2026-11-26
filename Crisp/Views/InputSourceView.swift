import SwiftUI

// The Input row on a display card (#196): which input the monitor shows, and a
// checkmark list to switch it. Switching away disconnects the display, so the way
// back is its Reconnect row (InputSwitchService).

func inputLabel(_ value: UInt16) -> String {
    DDCInputSource.name(for: value) ?? String(localized: "Input \(String(format: "0x%02X", value))")
}

struct InputHeadBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var service = InputSwitchService.shared

    var body: some View {
        Group {
            if service.isAvailable(for: display) {
                ExpandableRow(
                    icon: "cable.connector",
                    iconActive: false,
                    label: "Input",
                    subtitle: service.macInput[display.displayUUID].map(inputLabel),
                    isExpanded: state.openBinding(\.inputOpenIDs, display.displayID)
                )
            }
        }
        .task { await service.refreshInput(display) }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            Task { await service.refreshInput(display) }
        }
    }
}

struct InputBodyBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = InputSwitchService.shared
    @State private var pending: UInt16?
    @State private var message: String?

    private var uuid: String { display.displayUUID }
    private var isOpen: Bool { state.inputOpenIDs.contains(display.displayID) }

    var body: some View {
        if service.isAvailable(for: display) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.reading.contains(uuid) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Reading the inputs from the monitor…")
                }
                .caption()
            }

            // LG's side-channel inputs (DDCInputSource.lg) follow the monitor's own, set apart
            // by a divider: the connector names repeat, and the two groups use different channels.
            let options = service.options(for: display)
            let standard = options.filter { !DDCInputSource.isLG($0) }
            let lgInputs = options.filter(DDCInputSource.isLG)
            ForEach(standard, id: \.self) { row($0) }
            if !standard.isEmpty, !lgInputs.isEmpty {
                Divider().padding(.leading, 24).padding(.vertical, 3)
            }
            // Until this Mac's input is an LG code, the first click on an LG input marks it.
            // Worded as a fallback: many LG monitors switch fine with the inputs above.
            if service.awaitsLGMark(display) {
                Text("If the standard inputs don't switch, first choose the (LG) input this Mac is on.").caption()
            }
            ForEach(lgInputs, id: \.self) { row($0) }

            if service.macInput[uuid] == nil {
                Text("Crisp could not read which input this Mac is on. Choose it once.").caption()
            } else if PhysicalDisplayToggleService.shared.wouldLeaveNoActiveDisplay(display.displayID) {
                Text("This is the only display, so it stays connected while it shows the other input.").caption()
            } else {
                Text("Another input disconnects this display. Reconnect it here to switch back.").caption()
            }
            if service.offersChoosingAgain(display) {
                Button("Choose Again") { service.forgetMark(for: display) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 24)
                    .padding(.bottom, 4)
            }

            if let message {
                Text(message).caption().foregroundColor(.red)
            }
        }
        .onChange(of: isOpen) { _, open in
            if open { Task { await service.readListIfNeeded(display) } }
        }
    }

    private func row(_ value: UInt16) -> some View {
        CheckmarkRow(
            label: inputLabel(value),
            isSelected: service.macInput[uuid] == value,
            isPending: pending == value
        ) { choose(value) }
    }

    private func choose(_ value: UInt16) {
        // The checked row is this Mac's input: choosing it again would only re-send it.
        guard pending == nil, value != service.macInput[uuid] else { return }
        guard !service.choiceMarks(value, for: display) else {
            service.mark(value, for: display)
            message = nil
            return
        }
        pending = value
        Task { @MainActor in
            let result = await service.switchInput(display, to: value)
            pending = nil
            displayManager.refreshDisplays()
            if case .failure(let error) = result { show(error.description) }
        }
    }

    private func show(_ text: String) {
        message = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if message == text { message = nil }
        }
    }
}

private extension View {
    func caption() -> some View {
        font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
    }
}
