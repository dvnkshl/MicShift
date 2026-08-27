import XCTest
@testable import DJIMicAutoSwitch

final class ModelsTests: XCTestCase {
    @MainActor
    func testActiveStatusIconCombinesMicrophoneAndBattery() {
        let icon = StatusIconFactory.activeMicrophone(
            battery: .medium,
            accessibilityLabel: "TX1 linked · battery medium"
        )

        XCTAssertNotNil(icon)
        XCTAssertEqual(icon?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(icon?.isTemplate, true)
        XCTAssertEqual(icon?.accessibilityDescription, "TX1 linked · battery medium")
    }

    @MainActor
    func testMenuBarStatusIconRemainsTemplateForSystemDisplayTinting() {
        let source = StatusIconFactory.activeMicrophone(
            battery: .full,
            accessibilityLabel: "TX1 linked"
        )
        let icon = StatusIconFactory.menuBarImage(source)

        XCTAssertEqual(icon?.isTemplate, true)
        XCTAssertEqual(icon?.accessibilityDescription, "TX1 linked")
        XCTAssertEqual(icon?.size, NSSize(width: 18, height: 18))
    }

    @MainActor
    func testOfflineStatusIconUsesTheSameMicrophoneCanvas() {
        let icon = StatusIconFactory.offlineMicrophone(accessibilityLabel: "Receiver offline")
        let unknownBatteryIcon = StatusIconFactory.activeMicrophone(
            battery: .unknown,
            accessibilityLabel: "Battery unknown"
        )

        XCTAssertEqual(icon?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(icon?.isTemplate, true)
        XCTAssertEqual(icon?.accessibilityDescription, "Receiver offline")
        XCTAssertNotEqual(icon?.tiffRepresentation, unknownBatteryIcon?.tiffRepresentation)
        XCTAssertEqual(StatusIconFactory.menuBarTintColor, NSColor.white)
        XCTAssertEqual(StatusIconFactory.marketingTintColor.alphaComponent, 1, accuracy: 0.001)
    }

    func testBatteryGaugeMapsToHonestBands() {
        let expected: [(Int?, TransmitterBatteryBand)] = [
            (nil, .unknown),
            (0, .unknown),
            (1, .full),
            (2, .high),
            (3, .high),
            (4, .medium),
            (5, .low),
            (6, .low),
            (7, .empty),
        ]

        for (battery, band) in expected {
            let tx = TransmitterSnapshot(
                slot: 1,
                charging: false,
                battery: battery,
                level: nil,
                productName: nil
            )
            XCTAssertEqual(tx.batteryBand, band, "Unexpected band for gauge \(String(describing: battery))")
        }
    }

    func testLowestUsableBatteryUsesMostDepletedLinkedTransmitter() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(slot: 1, charging: false, battery: 2, level: 5, productName: nil),
                TransmitterSnapshot(slot: 2, charging: false, battery: 6, level: 5, productName: nil),
            ]
        )

        XCTAssertEqual(snapshot.lowestUsableBatteryBand, .low)
    }

    func testChargingTransmitterDoesNotDriveActiveBatteryIcon() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(slot: 1, charging: true, battery: 7, level: 0, productName: nil),
                TransmitterSnapshot(slot: 2, charging: false, battery: 2, level: 5, productName: nil),
            ]
        )

        XCTAssertEqual(snapshot.lowestUsableBatteryBand, .high)
    }

    func testV2LinkedTransmitterIsUsable() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [TransmitterSnapshot(slot: 1, charging: false, battery: 3, level: 12, productName: "DJI Mic Mini 2")]
        )
        XCTAssertTrue(snapshot.hasUsableTransmitter)
    }

    func testDockedTransmitterIsNotUsable() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [TransmitterSnapshot(slot: 1, charging: true, battery: 2, level: 0, productName: "DJI Mic Mini 2")]
        )
        XCTAssertFalse(snapshot.hasUsableTransmitter)
    }

    func testOneChargingAndOneLinkedKeepsDJIUsable() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(slot: 1, charging: true, battery: 1, level: 0, productName: "DJI Mic Mini 2"),
                TransmitterSnapshot(slot: 2, charging: false, battery: 4, level: 8, productName: "DJI Mic Mini 2")
            ]
        )
        XCTAssertTrue(snapshot.hasUsableTransmitter)
    }

    func testV1LinkedTransmitterWithoutChargingFieldIsUsable() {
        let snapshot = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 1,
            transmitters: [TransmitterSnapshot(slot: 1, charging: nil, battery: nil, level: 5, productName: nil)]
        )
        XCTAssertTrue(snapshot.hasUsableTransmitter)
    }

    func testLinkLossIsNotUsable() {
        XCTAssertFalse(LinkSnapshot.unavailable.hasUsableTransmitter)
    }

    func testAudioLevelChangesDoNotChangePresentationState() {
        let first = snapshot(level: 2, battery: 4, charging: false)
        let speaking = snapshot(level: 28, battery: 4, charging: false)

        XCTAssertNotEqual(first, speaking)
        XCTAssertEqual(first.presentationState, speaking.presentationState)
    }

    func testBatteryAndLinkChangesUpdatePresentationState() {
        let baseline = snapshot(level: 2, battery: 4, charging: false)

        XCTAssertNotEqual(
            baseline.presentationState,
            snapshot(level: 2, battery: 6, charging: false).presentationState
        )
        XCTAssertNotEqual(
            baseline.presentationState,
            snapshot(level: 2, battery: 4, charging: true).presentationState
        )
        XCTAssertNotEqual(baseline.presentationState, LinkSnapshot.unavailable.presentationState)
    }

    func testVisibleTransmitterMetadataChangesPresentationState() {
        let baseline = snapshot(level: 2, battery: 4, charging: false)
        let renamed = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(
                    slot: 2,
                    charging: false,
                    battery: 4,
                    level: 2,
                    productName: "Another Wireless Mic"
                )
            ]
        )

        XCTAssertNotEqual(baseline.presentationState, renamed.presentationState)
    }

    func testTenThousandOnlineOfflineTransitionsRemainDeterministic() {
        let linked = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(
                    slot: 1,
                    charging: false,
                    battery: 4,
                    level: 8,
                    productName: "DJI Mic Mini 2"
                )
            ]
        )
        let docked = LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(
                    slot: 1,
                    charging: true,
                    battery: 4,
                    level: 0,
                    productName: "DJI Mic Mini 2"
                )
            ]
        )

        for iteration in 0..<10_000 {
            let snapshot = iteration.isMultiple(of: 2) ? linked : docked
            XCTAssertEqual(snapshot.hasUsableTransmitter, iteration.isMultiple(of: 2))
            XCTAssertEqual(
                snapshot.lowestUsableBatteryBand,
                iteration.isMultiple(of: 2) ? .medium : .unknown
            )
        }
    }

    func testDiscoveryDeviceDecodesHelperSnakeCaseSchema() throws {
        let json = #"""
        {
          "vendor_id": 11427,
          "product_id": 16401,
          "device_version": 0,
          "manufacturer": "DJI Technology Co., Ltd.",
          "product": "Wireless Mic Rx",
          "serial_redacted": true,
          "known_model": "DJI Mic Mini",
          "capture_supported": true,
          "interfaces": [{
            "number": 6,
            "alternate_setting": 0,
            "class": 255,
            "subclass": 240,
            "protocol": 0,
            "endpoints": [{
              "address": 134,
              "direction": "in",
              "transfer_type": "bulk",
              "max_packet_size": 64,
              "interval": 0
            }]
          }]
        }
        """#.data(using: .utf8)!

        let device = try JSONDecoder().decode(USBDiscoveryDevice.self, from: json)
        XCTAssertEqual(device.usbIdentifier, "2ca3:4011")
        XCTAssertEqual(device.knownModel, "DJI Mic Mini")
        XCTAssertTrue(device.captureSupported)
        XCTAssertEqual(device.interfaces.first?.endpoints.first?.transferType, "bulk")
    }

    private func snapshot(level: Int, battery: Int, charging: Bool) -> LinkSnapshot {
        LinkSnapshot(
            receiverPresent: true,
            receiverAccessible: true,
            receiverStreaming: true,
            deviceID: "rx",
            protocolVersion: 2,
            transmitters: [
                TransmitterSnapshot(
                    slot: 1,
                    charging: charging,
                    battery: battery,
                    level: level,
                    productName: "DJI Mic Mini 2"
                )
            ]
        )
    }
}
