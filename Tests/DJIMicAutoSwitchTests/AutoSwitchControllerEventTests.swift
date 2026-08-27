import CoreAudio
import XCTest
@testable import DJIMicAutoSwitch

@MainActor
final class AutoSwitchControllerEventTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AutoSwitchControllerEventTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStartUsesEventObserverAndInitialDeviceRefresh() {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)

        controller.start()
        defer { controller.stop() }

        XCTAssertEqual(audio.startObservationCallCount, 1)
        XCTAssertEqual(audio.inputDevicesCallCount, 1)
        XCTAssertEqual(audio.currentInputCallCount, 1)
        XCTAssertEqual(controller.state, .waiting)
        XCTAssertEqual(AutoSwitchController.watchdogInterval(observingAudioChanges: true), 30)
        XCTAssertEqual(AutoSwitchController.watchdogInterval(observingAudioChanges: false), 1)
    }

    func testObserverFailureUsesOneSecondRecoveryWatchdog() async {
        let audio = FakeAudioDeviceManager()
        audio.failObservation = true
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        controller.start()
        defer { controller.stop() }

        try? await Task.sleep(nanoseconds: 1_250_000_000)

        XCTAssertGreaterThanOrEqual(audio.inputDevicesCallCount, 2)
        XCTAssertGreaterThanOrEqual(audio.currentInputCallCount, 2)
    }

    func testDefaultInputEventReusesCachedDeviceList() async {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        controller.start()
        defer { controller.stop() }

        audio.emit(.defaultInput)
        await settleAudioEvents()

        XCTAssertEqual(audio.inputDevicesCallCount, 1)
        XCTAssertEqual(audio.currentInputCallCount, 2)
    }

    func testDeviceEventRefreshesDeviceList() async {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        controller.start()
        defer { controller.stop() }

        audio.emit(.devices)
        await settleAudioEvents()

        XCTAssertEqual(audio.inputDevicesCallCount, 2)
        XCTAssertEqual(audio.currentInputCallCount, 2)
    }

    func testRapidDeviceAndDefaultEventsCoalesceWithoutLosingRefresh() async {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        controller.start()
        defer { controller.stop() }

        audio.emit(.devices)
        audio.emit(.defaultInput)
        audio.emit(.defaultInput)
        await settleAudioEvents()

        XCTAssertEqual(audio.inputDevicesCallCount, 2)
        XCTAssertEqual(audio.currentInputCallCount, 2)
    }

    func testSpeakingLevelPacketsDoNotReevaluateOrPublish() {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        var updateCount = 0
        controller.onUpdate = { updateCount += 1 }
        controller.start()
        defer { controller.stop() }

        controller.receive(linkedSnapshot(level: 2, battery: 4))
        let evaluationsAfterLink = audio.currentInputCallCount
        let updatesAfterLink = updateCount
        controller.receive(linkedSnapshot(level: 30, battery: 4))

        XCTAssertEqual(audio.currentInputCallCount, evaluationsAfterLink)
        XCTAssertEqual(updateCount, updatesAfterLink)
    }

    func testBatteryChangePublishesWithoutReenumeratingDevices() {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        var updateCount = 0
        controller.onUpdate = { updateCount += 1 }
        controller.start()
        defer { controller.stop() }

        controller.receive(linkedSnapshot(level: 2, battery: 4))
        let enumerationsAfterLink = audio.inputDevicesCallCount
        let updatesAfterLink = updateCount
        controller.receive(linkedSnapshot(level: 2, battery: 6))

        XCTAssertEqual(audio.inputDevicesCallCount, enumerationsAfterLink)
        XCTAssertEqual(updateCount, updatesAfterLink + 1)
        XCTAssertEqual(controller.lastKnownBatteryBand, .low)
    }

    func testValidSnapshotClearsTransientHelperErrorEvenWhenPresentationIsUnchanged() {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        var updateCount = 0
        controller.onUpdate = { updateCount += 1 }
        controller.start()
        defer { controller.stop() }

        let snapshot = linkedSnapshot(level: 2, battery: 4)
        controller.receive(snapshot)
        controller.receiveError("temporary helper error")
        let updatesWithError = updateCount
        controller.receive(linkedSnapshot(level: 20, battery: 4))

        XCTAssertNil(controller.lastError)
        XCTAssertEqual(updateCount, updatesWithError + 1)
    }

    func testManualRefreshForcesEnumerationAndMenuUpdate() {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        var updateCount = 0
        controller.onUpdate = { updateCount += 1 }
        controller.start()
        defer { controller.stop() }
        let initialUpdates = updateCount

        controller.refresh()

        XCTAssertEqual(audio.inputDevicesCallCount, 2)
        XCTAssertEqual(updateCount, initialUpdates + 1)
    }

    func testStopCancelsPendingAudioEvaluationAndRemovesObservers() async {
        let audio = FakeAudioDeviceManager()
        let controller = AutoSwitchController(audio: audio, defaults: defaults)
        controller.start()
        audio.emit(.devices)
        controller.stop()

        await settleAudioEvents()

        XCTAssertEqual(audio.inputDevicesCallCount, 1)
        XCTAssertEqual(audio.stopObservationCallCount, 1)
    }

    private func settleAudioEvents() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func linkedSnapshot(level: Int, battery: Int) -> LinkSnapshot {
        LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(
                    slot: 1,
                    charging: false,
                    battery: battery,
                    level: level,
                    productName: "DJI Mic Mini 2"
                )
            ]
        )
    }
}

private final class FakeAudioDeviceManager: AudioDeviceManaging {
    enum TestError: Error {
        case observationUnavailable
    }

    private(set) var inputDevicesCallCount = 0
    private(set) var currentInputCallCount = 0
    private(set) var startObservationCallCount = 0
    private(set) var stopObservationCallCount = 0
    var failObservation = false
    private var observationHandler: ((AudioHardwareChange) -> Void)?

    private let builtIn = AudioInputDevice(
        id: 1,
        uid: "built-in",
        name: "MacBook Pro Microphone",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        isAlive: true,
        canBeDefault: true,
        isHidden: false,
        isAliveSettable: false,
        canBeDefaultSettable: false,
        isHiddenSettable: false
    )
    private let wireless = AudioInputDevice(
        id: 2,
        uid: "dji-wireless",
        name: "DJI Wireless Mic",
        transportType: kAudioDeviceTransportTypeUSB,
        isAlive: true,
        canBeDefault: true,
        isHidden: false,
        isAliveSettable: false,
        canBeDefaultSettable: false,
        isHiddenSettable: false
    )
    private var currentID: AudioDeviceID = 1

    func inputDevices() throws -> [AudioInputDevice] {
        inputDevicesCallCount += 1
        return [builtIn, wireless]
    }

    func currentDefaultInput(among devices: [AudioInputDevice]) throws -> AudioInputDevice? {
        currentInputCallCount += 1
        return devices.first(where: { $0.id == currentID })
    }

    func setDefaultInput(_ device: AudioInputDevice) throws {
        currentID = device.id
    }

    func preferredDJI(uid: String?, among devices: [AudioInputDevice]) -> AudioInputDevice? {
        if let uid { return devices.first(where: { $0.uid == uid }) }
        return devices.first(where: { $0.id == wireless.id })
    }

    func preferredFallback(
        explicitUID: String?,
        rememberedUID: String?,
        excludingUID: String?,
        among devices: [AudioInputDevice]
    ) -> AudioInputDevice? {
        let allowed = devices.filter { $0.uid != excludingUID }
        if let explicitUID, let device = allowed.first(where: { $0.uid == explicitUID }) {
            return device
        }
        if let rememberedUID, let device = allowed.first(where: { $0.uid == rememberedUID }) {
            return device
        }
        return allowed.first(where: { $0.id == builtIn.id })
    }

    func startObservingChanges(_ handler: @escaping (AudioHardwareChange) -> Void) throws {
        startObservationCallCount += 1
        if failObservation { throw TestError.observationUnavailable }
        observationHandler = handler
    }

    func stopObservingChanges() {
        stopObservationCallCount += 1
        observationHandler = nil
    }

    func emit(_ change: AudioHardwareChange) {
        observationHandler?(change)
    }
}
