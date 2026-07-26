import Foundation
import CoreAudio

/// 一台可用于录音的 Core Audio 输入设备。
///
/// `deviceID` 只在本次系统会话内有效；持久化必须使用稳定的 `uid`。
struct AudioInputDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let isDefault: Bool

    var id: String { uid }

    var connectionLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "内置"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "蓝牙"
        case kAudioDeviceTransportTypeBluetoothLE: return "蓝牙 LE"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate: return "聚合设备"
        case kAudioDeviceTransportTypeVirtual: return "虚拟设备"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "连续互通（有线）"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "连续互通（无线）"
        case kAudioDeviceTransportTypePCI: return "PCI"
        default: return "音频设备"
        }
    }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioInputDevices {
    enum DeviceError: LocalizedError {
        case queryFailed(OSStatus)
        case defaultUnavailable
        case selectedUnavailable

        var errorDescription: String? {
            switch self {
            case .queryFailed(let status):
                return "读取音频输入设备失败（Core Audio \(status)）"
            case .defaultUnavailable:
                return "系统当前没有可用的默认输入设备"
            case .selectedUnavailable:
                return "所选输入设备已断开或不可用"
            }
        }
    }

    static func available() throws -> [AudioInputDevice] {
        let defaultID = try? defaultDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw DeviceError.queryFailed(status) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                bytes.baseAddress!)
        }
        guard status == noErr else { throw DeviceError.queryFailed(status) }

        return ids.compactMap { id in
            guard hasInputStreams(id), isAlive(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                  let name = stringProperty(kAudioObjectPropertyName, of: id)
            else { return nil }

            return AudioInputDevice(
                deviceID: id,
                uid: uid,
                name: name,
                transportType: uint32Property(kAudioDevicePropertyTransportType, of: id) ?? 0,
                isDefault: id == defaultID)
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolve(uid: String) throws -> AudioInputDevice {
        if uid.isEmpty {
            let id = try defaultDeviceID()
            guard let device = try available().first(where: { $0.deviceID == id }) else {
                throw DeviceError.defaultUnavailable
            }
            return device
        }

        guard let device = try available().first(where: { $0.uid == uid }) else {
            throw DeviceError.selectedUnavailable
        }
        return device
    }

    private static func defaultDeviceID() throws -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw DeviceError.defaultUnavailable
        }
        return id
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
            && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        uint32Property(kAudioDevicePropertyDeviceIsAlive, of: id) != 0
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       of id: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // Core Audio 明确要求调用方释放这些 CFString 属性。
        return value.takeRetainedValue() as String
    }
}
