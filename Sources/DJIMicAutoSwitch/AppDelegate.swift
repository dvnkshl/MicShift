import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AutoSwitchController()
    private let monitor = LinkMonitor()
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusItem: NSStatusItem!
    private var discoveryWindowController: ProtocolDiscoveryWindowController?
    private var monitorPausedForDiscovery = false
    private var launchAtLoginError: String?
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let headerView = StatusMenuHeaderView(frame: .zero)
    private let transmittersItem = NSMenuItem(title: "Transmitters", action: nil, keyEquivalent: "")
    private let automaticItem = NSMenuItem(title: "Automatic Switching", action: #selector(toggleEnabled), keyEquivalent: "")
    private let djiInputItem = NSMenuItem(title: "DJI Input", action: nil, keyEquivalent: "")
    private let fallbackInputItem = NSMenuItem(title: "Fallback Input", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let errorSeparator = NSMenuItem.separator()
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let discoveryLaunch = CommandLine.arguments.contains("--protocol-discovery")
        NSApp.setActivationPolicy(discoveryLaunch ? .regular : .accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        controller.onUpdate = { [weak self] in self?.refreshMenu() }
        monitor.onSnapshot = { [weak self] snapshot in self?.controller.receive(snapshot) }
        monitor.onError = { [weak self] error in self?.controller.receiveError(error) }

        controller.start()
        monitor.start()
        buildMenu()
        refreshMenu()

        if discoveryLaunch {
            openProtocolDiscovery()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        controller.stop()
    }

    private func buildMenu() {
        menu.delegate = self
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(.separator())

        automaticItem.target = self
        menu.addItem(automaticItem)
        menu.addItem(djiInputItem)
        menu.addItem(fallbackInputItem)
        menu.addItem(.separator())
        menu.addItem(transmittersItem)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let discovery = NSMenuItem(
            title: "Help Add a Microphone…",
            action: #selector(openProtocolDiscovery),
            keyEquivalent: ""
        )
        discovery.target = self
        menu.addItem(discovery)
        errorItem.isEnabled = false
        menu.addItem(errorSeparator)
        menu.addItem(errorItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MicShift", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshMenu() {
        let presentation = statusPresentation()
        configureStatusButton()
        headerView.update(
            icon: presentation.icon,
            title: presentation.title,
            subtitle: presentation.subtitle,
            currentInput: controller.currentInput?.name ?? "Unavailable",
            battery: presentation.battery
        )

        if let snapshot = controller.snapshot, snapshot.receiverPresent {
            transmittersItem.isHidden = false
            updateTransmitterMenu(snapshot: snapshot)
        } else {
            transmittersItem.isHidden = true
        }

        automaticItem.state = controller.isEnabled ? .on : .off
        updateDeviceMenuItem(djiInputItem, isDJI: true)
        updateDeviceMenuItem(fallbackInputItem, isDJI: false)
        updateLaunchAtLoginItem()

        if let error = launchAtLoginError ?? controller.lastError {
            errorItem.title = "Issue: \(error)"
            errorSeparator.isHidden = false
            errorItem.isHidden = false
        } else {
            errorSeparator.isHidden = true
            errorItem.isHidden = true
        }
        menu.update()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func configureStatusButton() {
        let presentation = statusPresentation()
        statusItem.button?.image = StatusIconFactory.menuBarImage(presentation.icon)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = "MicShift — \(presentation.title): \(presentation.subtitle)"
    }

    private struct StatusPresentation {
        let icon: NSImage?
        let title: String
        let subtitle: String
        let battery: String
    }

    private func statusPresentation() -> StatusPresentation {
        let accessibility = stateText()
        switch controller.state {
        case .usingDJI:
            let linked = controller.snapshot?.transmitters
                .filter(\.isUsable)
                .map { "TX\($0.slot) linked" }
                .joined(separator: " · ") ?? "Transmitter linked"
            let band = controller.snapshot?.lowestUsableBatteryBand ?? .unknown
            return StatusPresentation(
                icon: StatusIconFactory.activeMicrophone(battery: band, accessibilityLabel: accessibility),
                title: "Connected",
                subtitle: linked,
                battery: batteryText(for: band)
            )

        case .usingFallback:
            let subtitle: String
            if controller.snapshot?.receiverPresent == false {
                subtitle = "Receiver not connected · using fallback"
            } else {
                subtitle = "Wireless mic unavailable · using fallback"
            }
            return StatusPresentation(
                icon: StatusIconFactory.offlineMicrophone(accessibilityLabel: accessibility),
                title: "Offline",
                subtitle: subtitle,
                battery: batteryText(for: controller.lastKnownBatteryBand, prefixLastKnown: true)
            )

        case .paused:
            return StatusPresentation(
                icon: StatusIconFactory.offlineMicrophone(accessibilityLabel: accessibility),
                title: "Paused",
                subtitle: "Automatic switching is off",
                battery: batteryText(for: controller.lastKnownBatteryBand, prefixLastKnown: true)
            )

        case .waiting:
            return StatusPresentation(
                icon: StatusIconFactory.offlineMicrophone(accessibilityLabel: accessibility),
                title: "Checking microphone…",
                subtitle: "Waiting for receiver state",
                battery: "Unavailable"
            )

        case .linkedButAudioDeviceMissing:
            return StatusPresentation(
                icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: accessibility),
                title: "Input unavailable",
                subtitle: "Choose the receiver under DJI Input",
                battery: batteryText(for: controller.snapshot?.lowestUsableBatteryBand ?? .unknown)
            )

        case .receiverBusy:
            return StatusPresentation(
                icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: accessibility),
                title: "Receiver busy",
                subtitle: "Close the other DJI control app",
                battery: "Unavailable"
            )

        case let .error(message):
            return StatusPresentation(
                icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: accessibility),
                title: "Needs attention",
                subtitle: message,
                battery: "Unavailable"
            )
        }
    }

    private func batteryText(
        for band: TransmitterBatteryBand,
        prefixLastKnown: Bool = false
    ) -> String {
        let value: String
        switch band {
        case .unknown: value = "Unavailable"
        case .full: value = "Full"
        case .high: value = "High"
        case .medium: value = "Medium"
        case .low: value = "Low"
        case .empty: value = "Empty"
        }
        if prefixLastKnown, band != .unknown {
            return "Last seen · \(value)"
        }
        return value
    }

    private func stateText() -> String {
        switch controller.state {
        case .paused:
            return "Automatic switching paused"
        case .waiting:
            return "Waiting for receiver state…"
        case .usingDJI:
            let transmitters = controller.snapshot?.transmitters.map { tx in
                var text = "TX\(tx.slot) linked"
                if tx.batteryBand != .unknown {
                    text += " · \(tx.batteryBand.label.lowercased())"
                }
                return text
            }.joined(separator: ", ") ?? "Transmitter linked"
            return transmitters
        case .usingFallback:
            if controller.snapshot?.receiverPresent == false { return "Receiver not connected · using fallback" }
            return "Wireless mic offline · using fallback"
        case .linkedButAudioDeviceMissing:
            return "Transmitter linked, but DJI audio input is unavailable"
        case .receiverBusy:
            return "Receiver is busy in another DJI control app · using fallback"
        case let .error(message):
            return message
        }
    }

    private func updateTransmitterMenu(snapshot: LinkSnapshot) {
        let submenu = NSMenu(title: "Transmitters")

        if snapshot.transmitters.isEmpty {
            let none = NSMenuItem(title: "No transmitter linked", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for tx in snapshot.transmitters.sorted(by: { $0.slot < $1.slot }) {
                let state = tx.charging == true ? "Offline · not in use" : "Connected · in use"
                let battery = batteryText(for: tx.batteryBand)
                let batteryLabel = battery == "Unavailable" ? "Battery unavailable" : "\(battery) battery"
                let item = NSMenuItem(
                    title: "TX\(tx.slot) · \(batteryLabel) · \(state)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.image = NSImage(
                    systemSymbolName: tx.batteryBand.systemSymbolName,
                    accessibilityDescription: tx.batteryBand.label
                )
                item.isEnabled = false
                submenu.addItem(item)

                if let productName = tx.productName, !productName.isEmpty {
                    let product = NSMenuItem(title: productName, action: nil, keyEquivalent: "")
                    product.isEnabled = false
                    product.indentationLevel = 1
                    submenu.addItem(product)
                }
            }
        }

        let note = NSMenuItem(
            title: "Battery is a device gauge; exact time remaining is unavailable",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        if !snapshot.transmitters.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(note)
        transmittersItem.submenu = submenu
    }

    private func updateDeviceMenuItem(_ parent: NSMenuItem, isDJI: Bool) {
        let submenu = NSMenu(title: parent.title)
        let selectedUID = isDJI ? controller.preferredDJIUID : controller.explicitFallbackUID

        let automaticTitle = isDJI ? "Automatic Detection" : "Automatic"
        let automatic = NSMenuItem(title: automaticTitle, action: isDJI ? #selector(selectAutomaticDJI) : #selector(selectAutomaticFallback), keyEquivalent: "")
        automatic.target = self
        automatic.state = selectedUID == nil ? .on : .off
        submenu.addItem(automatic)

        let candidates: [AudioInputDevice]
        if isDJI {
            // Automatic detection is only a convenience. Every viable input
            // remains available for explicit designation as the DJI receiver.
            candidates = controller.inputs
        } else if let designatedDJIUID = controller.preferredDJIUID {
            candidates = controller.inputs.filter { $0.uid != designatedDJIUID }
        } else {
            candidates = controller.inputs.filter { !$0.isDJIMic }
        }
        if !candidates.isEmpty { submenu.addItem(.separator()) }
        for device in candidates {
            let detectedSuffix = isDJI && device.isDJIMic ? " (Detected)" : ""
            let item = NSMenuItem(title: device.name + detectedSuffix, action: isDJI ? #selector(selectDJI(_:)) : #selector(selectFallback(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selectedUID == device.uid ? .on : .off
            item.isEnabled = device.isAlive && device.canBeDefault && !device.isHidden
            submenu.addItem(item)
        }
        parent.submenu = submenu
    }

    private func updateLaunchAtLoginItem() {
        switch launchAtLogin.state {
        case .enabled:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .on
            launchAtLoginItem.isEnabled = true
        case .disabled:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = true
        case .requiresApproval:
            launchAtLoginItem.title = "Launch at Login (Approval Needed)"
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.isEnabled = true
        case .unavailable:
            launchAtLoginItem.title = "Launch at Login (Move App to Applications)"
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = true
        }
    }

    @objc private func toggleEnabled() {
        controller.isEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.toggle()
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at Login: \(error.localizedDescription)"
        }
        refreshMenu()
    }

    @objc private func selectAutomaticDJI() {
        controller.chooseDJI(uid: nil)
    }

    @objc private func selectAutomaticFallback() {
        controller.chooseFallback(uid: nil)
    }

    @objc private func selectDJI(_ sender: NSMenuItem) {
        controller.chooseDJI(uid: sender.representedObject as? String)
    }

    @objc private func selectFallback(_ sender: NSMenuItem) {
        controller.chooseFallback(uid: sender.representedObject as? String)
    }

    @objc private func openProtocolDiscovery() {
        let discovery: ProtocolDiscoveryWindowController
        if let existing = discoveryWindowController {
            discovery = existing
        } else {
            discovery = ProtocolDiscoveryWindowController()
            discovery.onCaptureStarted = { [weak self] in
                guard let self, !self.monitorPausedForDiscovery else { return }
                self.monitorPausedForDiscovery = true
                self.monitor.stop()
                self.controller.receive(.unavailable)
            }
            discovery.onCaptureStopped = { [weak self] in
                guard let self, self.monitorPausedForDiscovery else { return }
                self.monitorPausedForDiscovery = false
                self.monitor.start()
            }
            discoveryWindowController = discovery
        }
        discovery.showAndScan()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
