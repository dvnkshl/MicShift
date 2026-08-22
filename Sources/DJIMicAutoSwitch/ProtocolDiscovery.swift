import AppKit
import Foundation
import UniformTypeIdentifiers

struct USBDiscoveryEndpoint: Codable, Equatable {
    let address: Int
    let direction: String
    let transferType: String
    let maxPacketSize: Int
    let interval: Int

    private enum CodingKeys: String, CodingKey {
        case address
        case direction
        case transferType = "transfer_type"
        case maxPacketSize = "max_packet_size"
        case interval
    }
}

struct USBDiscoveryInterface: Codable, Equatable {
    let number: Int
    let alternateSetting: Int
    let `class`: Int
    let subclass: Int
    let `protocol`: Int
    let endpoints: [USBDiscoveryEndpoint]

    private enum CodingKeys: String, CodingKey {
        case number
        case alternateSetting = "alternate_setting"
        case `class`
        case subclass
        case `protocol`
        case endpoints
    }
}

struct USBDiscoveryDevice: Codable, Equatable {
    let vendorID: Int
    let productID: Int
    let deviceVersion: Int
    let manufacturer: String?
    let product: String?
    let serialRedacted: Bool
    let knownModel: String?
    let captureSupported: Bool
    let interfaces: [USBDiscoveryInterface]

    private enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case deviceVersion = "device_version"
        case manufacturer
        case product
        case serialRedacted = "serial_redacted"
        case knownModel = "known_model"
        case captureSupported = "capture_supported"
        case interfaces
    }

    var displayName: String {
        let productName = product?.nonEmpty ?? "USB device"
        let manufacturerName = manufacturer?.nonEmpty
        let prefix = manufacturerName.map { "\($0) · " } ?? ""
        return "\(prefix)\(productName) [\(usbIdentifier)]"
    }

    var usbIdentifier: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    var capabilitySummary: String {
        if let knownModel {
            return "Known protocol: \(knownModel). Read-only status capture is available."
        }
        if captureSupported {
            return "Unknown protocol. A readable vendor-status endpoint is available for discovery."
        }
        return "No readable vendor-status endpoint was found. A descriptor report can still be shared."
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct DiscoveryMarker: Codable, Equatable {
    let label: String
    let timestampMS: UInt64
    let recordIndex: Int
}

final class DiscoveryCaptureProcess {
    var onLine: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private let lock = NSLock()
    private var stopping = false

    func start(device: USBDiscoveryDevice) throws {
        guard let helperURL = Self.helperURL() else {
            throw NSError(
                domain: "DJIMicAuto.Discovery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled USB helper is missing."]
            )
        }

        stopping = false
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--capture-discovery", "0x\(String(format: "%04x", device.vendorID))", "0x\(String(format: "%04x", device.productID))"]
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onError?(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        process.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.onExit?()
            }
        }

        try process.run()
        self.process = process
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            lines.append(buffer[..<newline])
            buffer.removeSubrange(...newline)
        }
        lock.unlock()

        for data in lines where !data.isEmpty {
            guard let line = String(data: data, encoding: .utf8) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }

    static func listDevices(completion: @escaping (Result<[USBDiscoveryDevice], Error>) -> Void) {
        guard let helperURL = helperURL() else {
            completion(.failure(NSError(
                domain: "DJIMicAuto.Discovery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled USB helper is missing."]
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = helperURL
                process.arguments = ["--list-discovery-devices"]
                process.standardOutput = stdout
                process.standardError = stderr
                try process.run()
                process.waitUntilExit()
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 {
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?.nonEmpty ?? "USB scan failed."
                    throw NSError(
                        domain: "DJIMicAuto.Discovery",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
                let devices = try JSONDecoder().decode([USBDiscoveryDevice].self, from: output)
                DispatchQueue.main.async { completion(.success(devices)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func helperURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DJI_LINK_MONITOR_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "dji-link-monitor", withExtension: nil)
    }
}

@MainActor
final class ProtocolDiscoveryWindowController: NSWindowController, NSWindowDelegate {
    var onCaptureStarted: (() -> Void)?
    var onCaptureStopped: (() -> Void)?

    private let devicePopup = NSPopUpButton()
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let modelField = NSTextField()
    private let capabilityLabel = NSTextField(wrappingLabelWithString: "Connect a receiver to begin.")
    private let markerPopup = NSPopUpButton()
    private let startButton = NSButton(title: "Start Read-Only Scan", target: nil, action: nil)
    private let markButton = NSButton(title: "Mark Current State", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Report…", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()

    private var devices: [USBDiscoveryDevice] = []
    private var capture: DiscoveryCaptureProcess?
    private var captureRecords: [String] = []
    private var markers: [DiscoveryMarker] = []
    private var captureActive = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 535),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Help Add a Wireless Microphone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndScan() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        loadDevices()
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Help us add your microphone")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let intro = NSTextField(wrappingLabelWithString:
            "This creates a privacy-redacted USB status report that can be attached to a GitHub issue. It never records microphone audio, exports the USB serial descriptor, or sends commands to the receiver. Long text found inside packets is redacted automatically."
        )
        intro.textColor = .secondaryLabelColor

        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        devicePopup.setAccessibilityLabel("USB microphone receiver")
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        rescanButton.bezelStyle = .rounded

        let deviceRow = NSStackView(views: [devicePopup, rescanButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 8
        devicePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modelField.placeholderString = "For example, DJI Mic 2"
        modelField.setAccessibilityLabel("Microphone model name")

        capabilityLabel.textColor = .secondaryLabelColor

        markerPopup.addItems(withTitles: [
            "Receiver connected, no transmitter",
            "Transmitter linked and active",
            "Transmitter in charging case",
            "Transmitter powered off",
            "Wireless link lost / out of range",
            "Transmitter reconnected",
            "Second transmitter linked",
        ])
        markerPopup.setAccessibilityLabel("Physical microphone state")

        startButton.target = self
        startButton.action = #selector(startScan)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        markButton.target = self
        markButton.action = #selector(markState)
        markButton.bezelStyle = .rounded
        markButton.isEnabled = false

        saveButton.target = self
        saveButton.action = #selector(saveReport)
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false

        let actionRow = NSStackView(views: [startButton, markButton, saveButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.distribution = .fillProportionally

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [progress, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let stack = NSStackView(views: [
            title,
            intro,
            labeled("USB receiver", deviceRow),
            labeled("Model name (optional)", modelField),
            capabilityLabel,
            separator(),
            NSTextField(wrappingLabelWithString: "Start the scan, place the hardware in each state below, wait two seconds, then mark that state. These markers let maintainers compare exactly which protocol bytes changed."),
            labeled("Current physical state", markerPopup),
            actionRow,
            statusRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -22),
            deviceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            capabilityLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func labeled(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func loadDevices() {
        guard !captureActive else { return }
        progress.startAnimation(nil)
        statusLabel.stringValue = "Scanning USB devices…"
        devicePopup.removeAllItems()
        devicePopup.addItem(withTitle: "Scanning…")
        devicePopup.isEnabled = false
        rescanButton.isEnabled = false
        startButton.isEnabled = false
        saveButton.isEnabled = false

        DiscoveryCaptureProcess.listDevices { [weak self] result in
            guard let self else { return }
            self.progress.stopAnimation(nil)
            self.rescanButton.isEnabled = true
            switch result {
            case let .success(devices):
                self.devices = devices
                self.devicePopup.removeAllItems()
                if devices.isEmpty {
                    self.devicePopup.addItem(withTitle: "No candidate receiver found")
                    self.devicePopup.isEnabled = false
                    self.startButton.isEnabled = false
                    self.saveButton.isEnabled = false
                    self.capabilityLabel.stringValue = "Connect the receiver directly by USB, then rescan."
                    self.statusLabel.stringValue = "No USB audio receiver with a vendor-control interface was detected."
                    return
                }
                self.devicePopup.addItems(withTitles: devices.map(\.displayName))
                self.devicePopup.isEnabled = true
                self.statusLabel.stringValue = "USB serial descriptors are omitted. Review the report before sharing because unknown binary fields may remain."
                self.updateSelectedDevice()
            case let .failure(error):
                self.devices = []
                self.devicePopup.removeAllItems()
                self.devicePopup.addItem(withTitle: "USB scan unavailable")
                self.devicePopup.isEnabled = false
                self.capabilityLabel.stringValue = error.localizedDescription
                self.statusLabel.stringValue = ""
            }
        }
    }

    @objc private func rescan() {
        loadDevices()
    }

    @objc private func deviceChanged() {
        updateSelectedDevice()
    }

    private func updateSelectedDevice() {
        guard let device = selectedDevice else { return }
        capabilityLabel.stringValue = device.capabilitySummary
        startButton.isEnabled = device.captureSupported
        saveButton.isEnabled = true
        if modelField.stringValue.isEmpty, let knownModel = device.knownModel {
            modelField.stringValue = knownModel
        }
    }

    @objc private func startScan() {
        guard let device = selectedDevice, device.captureSupported, !captureActive else { return }
        captureRecords.removeAll(keepingCapacity: true)
        markers.removeAll(keepingCapacity: true)
        let capture = DiscoveryCaptureProcess()
        capture.onLine = { [weak self] line in
            guard let self else { return }
            self.captureRecords.append(line)
            self.statusLabel.stringValue = "Scanning read-only USB status · \(self.captureRecords.count) records · mark each physical state after two seconds."
        }
        capture.onError = { [weak self] message in
            self?.statusLabel.stringValue = message
        }
        capture.onExit = { [weak self] in
            guard let self, self.captureActive else { return }
            self.finishCaptureUI(message: "The USB scan stopped. You can still save the records collected so far.")
        }

        do {
            onCaptureStarted?()
            try capture.start(device: device)
            self.capture = capture
            captureActive = true
            devicePopup.isEnabled = false
            rescanButton.isEnabled = false
            startButton.isEnabled = false
            markButton.isEnabled = true
            saveButton.isEnabled = true
            saveButton.title = "Stop & Save Report…"
            progress.startAnimation(nil)
            addMarker(label: "Scan started")
            statusLabel.stringValue = "Scanning read-only USB status…"
        } catch {
            onCaptureStopped?()
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func markState() {
        guard captureActive, markerPopup.indexOfSelectedItem >= 0 else { return }
        addMarker(label: markerPopup.titleOfSelectedItem ?? "Unlabelled state")
        NSSound(named: "Tink")?.play()
        statusLabel.stringValue = "Marked “\(markerPopup.titleOfSelectedItem ?? "state")” at record \(captureRecords.count). Continue to the next hardware state."
    }

    private func addMarker(label: String) {
        markers.append(DiscoveryMarker(
            label: label,
            timestampMS: UInt64(Date().timeIntervalSince1970 * 1_000),
            recordIndex: captureRecords.count
        ))
    }

    @objc private func saveReport() {
        guard let device = selectedDevice else { return }
        if captureActive {
            stopCapture()
        }

        let panel = NSSavePanel()
        panel.title = "Save Privacy-Redacted Discovery Report"
        panel.nameFieldStringValue = "mic-discovery-\(device.usbIdentifier.replacingOccurrences(of: ":", with: "-"))-\(Self.dateStamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.writeReport(to: url, device: device)
                self.statusLabel.stringValue = "Saved \(url.lastPathComponent). Review it before attaching it to a public issue."
            } catch {
                self.statusLabel.stringValue = "Could not save report: \(error.localizedDescription)"
            }
        }
    }

    private func writeReport(to url: URL, device: USBDiscoveryDevice) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let deviceObject = try JSONSerialization.jsonObject(with: encoder.encode(device))
        let markerObjects = try markers.map { marker in
            try JSONSerialization.jsonObject(with: encoder.encode(marker))
        }
        let records = captureRecords.compactMap { line -> Any? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report: [String: Any] = [
            "schema_version": 1,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "app_version": appVersion,
            "platform": "macOS",
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "model_label": modelField.stringValue,
            "privacy": [
                "microphone_audio_captured": false,
                "usb_commands_sent": false,
                "usb_serial_descriptors_exported": false,
                "ascii_runs_in_packets_redacted": true,
                "unknown_binary_fields_may_remain": true,
            ],
            "device": deviceObject,
            "markers": markerObjects,
            "capture_records": records,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func stopCapture() {
        guard captureActive else { return }
        captureActive = false
        capture?.onExit = nil
        capture?.stop()
        capture = nil
        onCaptureStopped?()
        finishCaptureUI(message: "Scan stopped · \(captureRecords.count) records and \(markers.count) state markers are ready to save.")
    }

    private func finishCaptureUI(message: String) {
        captureActive = false
        progress.stopAnimation(nil)
        devicePopup.isEnabled = !devices.isEmpty
        rescanButton.isEnabled = true
        startButton.isEnabled = selectedDevice?.captureSupported == true
        markButton.isEnabled = false
        saveButton.isEnabled = selectedDevice != nil
        saveButton.title = "Save Report…"
        statusLabel.stringValue = message
    }

    private var selectedDevice: USBDiscoveryDevice? {
        guard devicePopup.indexOfSelectedItem >= 0, devicePopup.indexOfSelectedItem < devices.count else { return nil }
        return devices[devicePopup.indexOfSelectedItem]
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
