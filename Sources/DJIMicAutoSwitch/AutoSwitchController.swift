import Foundation

@MainActor
final class AutoSwitchController {
    static let enabledKey = "automaticSwitchingEnabled"
    static let preferredDJIKey = "preferredDJIUID"
    static let explicitFallbackKey = "explicitFallbackUID"
    static let rememberedFallbackKey = "rememberedFallbackUID"

    var onUpdate: (() -> Void)?

    private let audio: AudioDeviceManager
    private let defaults: UserDefaults
    private(set) var snapshot: LinkSnapshot?
    private(set) var state: ControllerState = .waiting
    private(set) var inputs: [AudioInputDevice] = []
    private(set) var currentInput: AudioInputDevice?
    private(set) var lastError: String?
    private(set) var lastKnownBatteryBand: TransmitterBatteryBand = .unknown
    private(set) var mayBeFullyChargedInCase = false
    private var timer: Timer?

    init(audio: AudioDeviceManager = AudioDeviceManager(), defaults: UserDefaults = .standard) {
        self.audio = audio
        self.defaults = defaults
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            evaluate()
        }
    }

    var preferredDJIUID: String? {
        defaults.string(forKey: Self.preferredDJIKey)
    }

    var explicitFallbackUID: String? {
        defaults.string(forKey: Self.explicitFallbackKey)
    }

    func start() {
        evaluate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
    }

    func receive(_ snapshot: LinkSnapshot) {
        let previous = self.snapshot
        if !snapshot.transmitters.isEmpty {
            let gauges = snapshot.transmitters.compactMap(\.battery)
            if let mostDepleted = gauges.max() {
                lastKnownBatteryBand = TransmitterSnapshot(
                    slot: 0,
                    charging: false,
                    battery: mostDepleted,
                    level: nil,
                    productName: nil
                ).batteryBand
            }
        }

        if snapshot.transmitters.contains(where: { $0.charging == true }) {
            mayBeFullyChargedInCase = false
        } else if snapshot.receiverStreaming,
                  snapshot.transmitters.isEmpty,
                  previous?.transmitters.contains(where: { $0.charging == true }) == true {
            // At full charge this firmware removes the TX slot and clears the
            // physical-link mask. Preserve only an honest transition hint;
            // the current packet alone cannot distinguish a full docked TX
            // from power-off, battery depletion, or radio loss.
            mayBeFullyChargedInCase = true
        } else if !snapshot.transmitters.isEmpty || !snapshot.receiverPresent {
            mayBeFullyChargedInCase = false
        }

        self.snapshot = snapshot
        lastError = nil
        evaluate()
    }

    func receiveError(_ message: String) {
        lastError = message
        if snapshot == nil {
            state = .error(message)
        }
        onUpdate?()
    }

    func chooseDJI(uid: String?) {
        if let uid {
            defaults.set(uid, forKey: Self.preferredDJIKey)
        } else {
            defaults.removeObject(forKey: Self.preferredDJIKey)
        }
        evaluate()
    }

    func chooseFallback(uid: String?) {
        if let uid {
            defaults.set(uid, forKey: Self.explicitFallbackKey)
        } else {
            defaults.removeObject(forKey: Self.explicitFallbackKey)
        }
        evaluate()
    }

    func evaluate() {
        do {
            inputs = try audio.inputDevices()
            currentInput = try audio.currentDefaultInput()

            guard isEnabled else {
                state = .paused
                onUpdate?()
                return
            }
            guard let snapshot else {
                state = .waiting
                onUpdate?()
                return
            }

            if snapshot.hasUsableTransmitter {
                switchToDJI()
            } else {
                switchToFallback()
            }
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
        onUpdate?()
    }

    private func switchToDJI() {
        guard let dji = audio.preferredDJI(uid: preferredDJIUID, among: inputs) else {
            state = .linkedButAudioDeviceMissing
            return
        }

        if let currentInput, currentInput.id != dji.id, explicitFallbackUID == nil {
            defaults.set(currentInput.uid, forKey: Self.rememberedFallbackKey)
        }
        do {
            if currentInput?.id != dji.id {
                try audio.setDefaultInput(dji)
                currentInput = dji
            }
            state = .usingDJI
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }

    private func switchToFallback() {
        let designatedDJI = audio.preferredDJI(uid: preferredDJIUID, among: inputs)
        let fallback = audio.preferredFallback(
            explicitUID: explicitFallbackUID,
            rememberedUID: defaults.string(forKey: Self.rememberedFallbackKey),
            excludingUID: designatedDJI?.uid,
            among: inputs
        )

        if snapshot?.receiverPresent == true && snapshot?.receiverAccessible == false {
            state = .receiverBusy
        }

        guard let fallback else {
            state = .error("No fallback microphone is available")
            return
        }
        do {
            if currentInput?.id != fallback.id {
                try audio.setDefaultInput(fallback)
                currentInput = fallback
            }
            if state != .receiverBusy {
                state = .usingFallback
            }
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }
}
