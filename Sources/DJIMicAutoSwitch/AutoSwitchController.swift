import Foundation

@MainActor
final class AutoSwitchController {
    static let enabledKey = "automaticSwitchingEnabled"
    static let preferredDJIKey = "preferredDJIUID"
    static let explicitFallbackKey = "explicitFallbackUID"
    static let rememberedFallbackKey = "rememberedFallbackUID"

    var onUpdate: (() -> Void)?

    private let audio: any AudioDeviceManaging
    private let defaults: UserDefaults
    private(set) var snapshot: LinkSnapshot?
    private(set) var state: ControllerState = .waiting
    private(set) var inputs: [AudioInputDevice] = []
    private(set) var currentInput: AudioInputDevice?
    private(set) var lastError: String?
    private(set) var lastKnownBatteryBand: TransmitterBatteryBand = .unknown
    private(set) var mayBeFullyChargedInCase = false
    private var watchdogTimer: Timer?
    private var pendingAudioEvaluation: DispatchWorkItem?
    private var pendingAudioDeviceRefresh = false
    private var observingAudioChanges = false
    private var isStarted = false
    private var lastPublishedViewState: ViewState?

    private struct ViewState: Equatable {
        let snapshot: LinkPresentationState?
        let state: ControllerState
        let inputs: [AudioInputDevice]
        let currentInput: AudioInputDevice?
        let lastError: String?
        let lastKnownBatteryBand: TransmitterBatteryBand
        let isEnabled: Bool
        let preferredDJIUID: String?
        let explicitFallbackUID: String?
    }

    init(audio: any AudioDeviceManaging = AudioDeviceManager(), defaults: UserDefaults = .standard) {
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
            evaluate(forceUpdate: true)
        }
    }

    var preferredDJIUID: String? {
        defaults.string(forKey: Self.preferredDJIKey)
    }

    var explicitFallbackUID: String? {
        defaults.string(forKey: Self.explicitFallbackKey)
    }

    func start() {
        isStarted = true
        do {
            try audio.startObservingChanges { [weak self] change in
                DispatchQueue.main.async {
                    self?.scheduleEvaluation(refreshDevices: change == .devices)
                }
            }
            observingAudioChanges = true
        } catch {
            observingAudioChanges = false
        }
        evaluate(refreshDevices: true, forceUpdate: true)

        let interval = Self.watchdogInterval(observingAudioChanges: observingAudioChanges)
        let watchdog = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.evaluate(refreshDevices: true)
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        watchdogTimer = watchdog
    }

    static func watchdogInterval(observingAudioChanges: Bool) -> TimeInterval {
        observingAudioChanges ? 30 : 1
    }

    func stop() {
        isStarted = false
        pendingAudioEvaluation?.cancel()
        pendingAudioEvaluation = nil
        pendingAudioDeviceRefresh = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        audio.stopObservingChanges()
    }

    func receive(_ snapshot: LinkSnapshot) {
        let previous = self.snapshot
        let hadError = lastError != nil
        let presentationChanged = previous?.presentationState != snapshot.presentationState
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
        if presentationChanged {
            evaluate()
        } else if hadError {
            publishIfChanged()
        }
    }

    func receiveError(_ message: String) {
        lastError = message
        if snapshot == nil {
            state = .error(message)
        }
        publishIfChanged()
    }

    func chooseDJI(uid: String?) {
        if let uid {
            defaults.set(uid, forKey: Self.preferredDJIKey)
        } else {
            defaults.removeObject(forKey: Self.preferredDJIKey)
        }
        evaluate(forceUpdate: true)
    }

    func chooseFallback(uid: String?) {
        if let uid {
            defaults.set(uid, forKey: Self.explicitFallbackKey)
        } else {
            defaults.removeObject(forKey: Self.explicitFallbackKey)
        }
        evaluate(forceUpdate: true)
    }

    func refresh() {
        evaluate(refreshDevices: true, forceUpdate: true)
    }

    func evaluate(refreshDevices: Bool = false, forceUpdate: Bool = false) {
        do {
            if refreshDevices || inputs.isEmpty {
                inputs = try audio.inputDevices()
            }
            currentInput = try audio.currentDefaultInput(among: inputs)

            guard isEnabled else {
                state = .paused
                publishIfChanged(force: forceUpdate)
                return
            }
            guard let snapshot else {
                state = .waiting
                publishIfChanged(force: forceUpdate)
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
        publishIfChanged(force: forceUpdate)
    }

    private func scheduleEvaluation(refreshDevices: Bool) {
        guard isStarted else { return }
        pendingAudioDeviceRefresh = pendingAudioDeviceRefresh || refreshDevices
        pendingAudioEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.pendingAudioEvaluation = nil
                let refreshDevices = self.pendingAudioDeviceRefresh
                self.pendingAudioDeviceRefresh = false
                self.evaluate(refreshDevices: refreshDevices)
            }
        }
        pendingAudioEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func publishIfChanged(force: Bool = false) {
        let viewState = ViewState(
            snapshot: snapshot?.presentationState,
            state: state,
            inputs: inputs,
            currentInput: currentInput,
            lastError: lastError,
            lastKnownBatteryBand: lastKnownBatteryBand,
            isEnabled: isEnabled,
            preferredDJIUID: preferredDJIUID,
            explicitFallbackUID: explicitFallbackUID
        )
        guard force || viewState != lastPublishedViewState else { return }
        lastPublishedViewState = viewState
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
