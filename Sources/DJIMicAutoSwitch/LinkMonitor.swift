import Foundation

final class LinkMonitor {
    var onSnapshot: ((LinkSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private var process: Process?
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        guard let child = process else { return }
        process = nil
        if child.isRunning {
            child.terminate()
            // A menu-bar utility may stop monitoring during protocol discovery
            // or app termination. Reap the helper before returning so repeated
            // launch/quit cycles cannot leave transient orphan processes behind.
            child.waitUntilExit()
        }
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func launch() {
        guard !stopped else { return }
        guard let helperURL = helperURL() else {
            onError?("DJI protocol helper is missing")
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helperURL
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.onError?(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        process.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.onSnapshot?(.unavailable)
                self.onError?("DJI protocol helper stopped; retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.launch()
                }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            onError?("Could not start DJI protocol helper: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.launch()
            }
        }
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

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in lines where !line.isEmpty {
            do {
                let snapshot = try decoder.decode(LinkSnapshot.self, from: line)
                DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("Could not decode DJI state: \(error.localizedDescription)")
                }
            }
        }
    }

    private func helperURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DJI_LINK_MONITOR_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "dji-link-monitor", withExtension: nil)
    }
}
