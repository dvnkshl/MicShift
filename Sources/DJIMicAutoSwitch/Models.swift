import Foundation

enum TransmitterBatteryBand: String, Equatable {
    case unknown
    case full
    case high
    case medium
    case low
    case empty

    var label: String {
        switch self {
        case .unknown: "Battery unknown"
        case .full: "Battery full"
        case .high: "Battery high"
        case .medium: "Battery medium"
        case .low: "Battery low"
        case .empty: "Battery empty"
        }
    }

    var systemSymbolName: String {
        switch self {
        case .unknown: "battery.0percent"
        case .full: "battery.100percent"
        case .high: "battery.75percent"
        case .medium: "battery.50percent"
        case .low: "battery.25percent"
        case .empty: "battery.0percent"
        }
    }

    var fillFraction: CGFloat {
        switch self {
        case .unknown, .empty: 0
        case .low: 0.25
        case .medium: 0.5
        case .high: 0.75
        case .full: 1
        }
    }
}

struct TransmitterSnapshot: Codable, Equatable {
    let slot: Int
    let charging: Bool?
    let battery: Int?
    let level: Int?
    let productName: String?

    var isUsable: Bool {
        // v1 firmware does not expose charging, so nil means linked/usable.
        charging != true
    }

    var batteryBand: TransmitterBatteryBand {
        // The protocol exposes an ordinal 1...7 gauge, not a percentage.
        // 1 is full, 7 is terminal/empty, and 6 triggers DJI's low warning.
        switch battery {
        case 1: .full
        case 2, 3: .high
        case 4: .medium
        case 5, 6: .low
        case 7: .empty
        default: .unknown
        }
    }
}

struct LinkSnapshot: Codable, Equatable {
    let receiverPresent: Bool
    let receiverAccessible: Bool
    let receiverStreaming: Bool
    let deviceID: String?
    let protocolVersion: Int?
    let transmitters: [TransmitterSnapshot]

    var hasUsableTransmitter: Bool {
        receiverStreaming && transmitters.contains(where: \.isUsable)
    }

    var lowestUsableBatteryBand: TransmitterBatteryBand {
        let gauges = transmitters
            .filter(\.isUsable)
            .compactMap(\.battery)
        guard let mostDepleted = gauges.max() else { return .unknown }
        return TransmitterSnapshot(
            slot: 0,
            charging: false,
            battery: mostDepleted,
            level: nil,
            productName: nil
        ).batteryBand
    }

    static let unavailable = LinkSnapshot(
        receiverPresent: false,
        receiverAccessible: false,
        receiverStreaming: false,
        deviceID: nil,
        protocolVersion: nil,
        transmitters: []
    )

    /// State that can change switching behavior or anything visible in the
    /// menu. Audio-level samples are intentionally excluded so speaking does
    /// not trigger Core Audio enumeration and menu redraws.
    var presentationState: LinkPresentationState {
        LinkPresentationState(
            receiverPresent: receiverPresent,
            receiverAccessible: receiverAccessible,
            receiverStreaming: receiverStreaming,
            transmitters: transmitters.map {
                LinkPresentationState.Transmitter(
                    slot: $0.slot,
                    charging: $0.charging,
                    battery: $0.battery,
                    productName: $0.productName
                )
            }
        )
    }
}

struct LinkPresentationState: Equatable {
    struct Transmitter: Equatable {
        let slot: Int
        let charging: Bool?
        let battery: Int?
        let productName: String?
    }

    let receiverPresent: Bool
    let receiverAccessible: Bool
    let receiverStreaming: Bool
    let transmitters: [Transmitter]
}

enum DesiredInputMode: Equatable {
    case dji
    case fallback
}

enum ControllerState: Equatable {
    case paused
    case waiting
    case usingDJI
    case usingFallback
    case linkedButAudioDeviceMissing
    case receiverBusy
    case error(String)
}
