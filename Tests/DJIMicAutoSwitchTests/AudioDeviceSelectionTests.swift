import CoreAudio
import XCTest
@testable import DJIMicAutoSwitch

final class AudioDeviceSelectionTests: XCTestCase {
    private let manager = AudioDeviceManager()

    func testAutomaticDJISelectionIgnoresNonDJIDevices() {
        let devices = [
            device(id: 1, uid: "built-in", name: "MacBook Pro Microphone", builtIn: true),
            device(id: 2, uid: "dji", name: "DJI Mic Mini")
        ]
        XCTAssertEqual(manager.preferredDJI(uid: nil, among: devices)?.uid, "dji")
    }

    func testWirelessMicReceiverWithDJIIdentityIsRecognized() {
        let receiver = device(
            id: 3,
            uid: "AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:XSP12345678B:3",
            name: "Wireless Mic Rx"
        )

        XCTAssertTrue(receiver.isDJIMic)
        XCTAssertEqual(manager.preferredDJI(uid: nil, among: [receiver])?.id, 3)
    }

    func testExplicitDJISelectionOverridesAutomaticDetection() {
        let unusuallyNamedReceiver = device(
            id: 4,
            uid: "vendor-specific-stable-uid",
            name: "Camera Receiver Input"
        )

        XCTAssertFalse(unusuallyNamedReceiver.isDJIMic)
        XCTAssertNil(manager.preferredDJI(uid: nil, among: [unusuallyNamedReceiver]))
        XCTAssertEqual(
            manager.preferredDJI(uid: unusuallyNamedReceiver.uid, among: [unusuallyNamedReceiver])?.id,
            unusuallyNamedReceiver.id
        )
    }

    func testRememberedFallbackWinsInAutomaticMode() {
        let devices = [
            device(id: 1, uid: "built-in", name: "MacBook Pro Microphone", builtIn: true),
            device(id: 2, uid: "studio", name: "Studio Microphone")
        ]
        XCTAssertEqual(
            manager.preferredFallback(explicitUID: nil, rememberedUID: "studio", excludingUID: nil, among: devices)?.uid,
            "studio"
        )
    }

    func testBuiltInFallbackWinsWhenRememberedDeviceDisappears() {
        let devices = [
            device(id: 1, uid: "built-in", name: "MacBook Pro Microphone", builtIn: true),
            device(id: 2, uid: "studio", name: "Studio Microphone")
        ]
        XCTAssertEqual(
            manager.preferredFallback(explicitUID: nil, rememberedUID: "missing", excludingUID: nil, among: devices)?.uid,
            "built-in"
        )
    }

    func testDesignatedDJIDeviceCannotAlsoBecomeFallback() {
        let devices = [
            device(id: 1, uid: "built-in", name: "MacBook Pro Microphone", builtIn: true),
            device(id: 4, uid: "custom-dji", name: "Camera Receiver Input")
        ]

        XCTAssertEqual(
            manager.preferredFallback(
                explicitUID: "custom-dji",
                rememberedUID: "custom-dji",
                excludingUID: "custom-dji",
                among: devices
            )?.uid,
            "built-in"
        )
    }

    private func device(id: AudioDeviceID, uid: String, name: String, builtIn: Bool = false) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            transportType: builtIn ? kAudioDeviceTransportTypeBuiltIn : kAudioDeviceTransportTypeUSB,
            isAlive: true,
            canBeDefault: true,
            isHidden: false,
            isAliveSettable: false,
            canBeDefaultSettable: false,
            isHiddenSettable: false
        )
    }
}
