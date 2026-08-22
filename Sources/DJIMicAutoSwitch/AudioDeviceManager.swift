import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let isAlive: Bool
    let canBeDefault: Bool
    let isHidden: Bool
    let isAliveSettable: Bool
    let canBeDefaultSettable: Bool
    let isHiddenSettable: Bool

    var isDJIMic: Bool {
        let normalizedName = name.lowercased()
        let normalizedUID = uid.lowercased()
        let isMicrophone = normalizedName.contains("mic")
        let hasDJIIdentity = normalizedName.contains("dji") || normalizedUID.contains("dji")
        return isMicrophone && hasDJIIdentity
    }

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

enum AudioDeviceError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case deviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "\(operation) failed (Core Audio \(formatOSStatus(status)))"
        case let .deviceUnavailable(name):
            return "Audio input is unavailable: \(name)"
        }
    }
}

private func formatOSStatus(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return String(status)
}

final class AudioDeviceManager {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func inputDevices() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size), "List audio devices")

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids), "Read audio devices")

        return ids.compactMap { id in
            guard (try? hasInputStreams(id)) == true,
                  let uid = try? stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = try? stringProperty(id, kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                transportType: (try? uint32Property(id, kAudioDevicePropertyTransportType)) ?? 0,
                isAlive: ((try? uint32Property(id, kAudioDevicePropertyDeviceIsAlive)) ?? 0) != 0,
                canBeDefault: ((try? uint32Property(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeInput)) ?? 0) != 0,
                isHidden: ((try? uint32Property(id, kAudioDevicePropertyIsHidden)) ?? 0) != 0,
                isAliveSettable: isPropertySettable(id, kAudioDevicePropertyDeviceIsAlive),
                canBeDefaultSettable: isPropertySettable(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeInput),
                isHiddenSettable: isPropertySettable(id, kAudioDevicePropertyIsHidden)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func currentDefaultInput() throws -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id), "Read default input")
        return try inputDevices().first(where: { $0.id == id })
    }

    func setDefaultInput(_ device: AudioInputDevice) throws {
        guard device.isAlive, device.canBeDefault, !device.isHidden else {
            throw AudioDeviceError.deviceUnavailable(device.name)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &id), "Set default input")
    }

    func device(uid: String, among devices: [AudioInputDevice]) -> AudioInputDevice? {
        devices.first(where: { $0.uid == uid })
    }

    func preferredDJI(uid: String?, among devices: [AudioInputDevice]) -> AudioInputDevice? {
        let viable = devices.filter { $0.isAlive && $0.canBeDefault && !$0.isHidden }
        if let uid, let exact = viable.first(where: { $0.uid == uid }) {
            return exact
        }
        return viable.first(where: \.isDJIMic)
    }

    func preferredFallback(
        explicitUID: String?,
        rememberedUID: String?,
        excludingUID: String?,
        among devices: [AudioInputDevice]
    ) -> AudioInputDevice? {
        let viable = devices.filter {
            $0.uid != excludingUID && $0.isAlive && $0.canBeDefault && !$0.isHidden
        }
        if let explicitUID, let exact = viable.first(where: { $0.uid == explicitUID }) {
            return exact
        }
        if explicitUID == nil, let rememberedUID, let remembered = viable.first(where: { $0.uid == rememberedUID }) {
            return remembered
        }
        return viable.first(where: \.isBuiltIn) ?? viable.first
    }

    func diagnosticReport() throws -> String {
        let devices = try inputDevices()
        return devices.map { device in
            "\(device.name) | uid=\(device.uid) | alive=\(device.isAlive) settable=\(device.isAliveSettable) | canDefault=\(device.canBeDefault) settable=\(device.canBeDefaultSettable) | hidden=\(device.isHidden) settable=\(device.isHiddenSettable)"
        }.joined(separator: "\n")
    }

    private func hasInputStreams(_ id: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Inspect input streams")
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read audio string property")
        // Core Audio's contract makes the caller responsible for releasing
        // returned CF object properties.
        return value?.takeRetainedValue() as String? ?? ""
    }

    private func uint32Property(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read audio integer property")
        return value
    }

    private func isPropertySettable(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(id, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioDeviceError.coreAudio(operation: operation, status: status)
        }
    }
}
