import Foundation
import CoreAudio

public struct AudioOutputState: Equatable, Sendable {
    public let deviceID: UInt32
    public let volume: Float
    public let muted: Bool
    public init(deviceID: UInt32, volume: Float, muted: Bool) {
        self.deviceID = deviceID
        self.volume = volume
        self.muted = muted
    }
}

public enum AudioOutputError: Error {
    case propertyWriteFailed(selector: String, status: OSStatus)
}

public protocol AudioOutputControlling: AnyObject {
    func currentState() -> AudioOutputState
    func forceMaxVolumeOnBuiltInSpeakers() throws
    @discardableResult func restore(_ state: AudioOutputState) -> Bool
}

/// Real CoreAudio implementation. Verified 2026-09-02: the built-in output
/// reports transport type `bltn` and exposes a settable main-element volume.
public final class CoreAudioOutputControl: AudioOutputControlling {
    public init() {}

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private var defaultOutputDevice: AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &device)
        return device
    }

    private func volume(of device: AudioDeviceID) -> Float {
        var addr = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return channelVolume(of: device) }
        return value
    }

    /// Some devices expose no main-element volume, only per-channel volume.
    private func channelVolume(of device: AudioDeviceID) -> Float {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return 0 }
        return value
    }

    private func setVolume(_ value: Float, on device: AudioDeviceID) -> Bool {
        var v = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        var main = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(AudioObjectID(device), &main),
           AudioObjectSetPropertyData(AudioObjectID(device), &main, 0, nil,
                                      size, &v) == noErr {
            return true
        }
        // Fall back to per-channel (stereo) volume.
        // Success if at least one channel accepted the write.
        var anyChannelSucceeded = false
        for channel in UInt32(1)...UInt32(2) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { continue }
            if AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil, size, &v) == noErr {
                anyChannelSucceeded = true
            }
        }
        return anyChannelSucceeded
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return false }
        return value == 1
    }

    private func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    private func setDefaultOutputDevice(_ device: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var value = device
        // Check status for diagnostics, but do not abort. Failing to switch to built-in
        // speakers means the siren plays through whatever device is currently default —
        // degraded, but still loud. Failing to unmute or set volume means silence.
        // A partial alarm (wrong device, full volume, unmuted) is strictly better than
        // no alarm, so we do not throw here and let the critical unmute/volume steps
        // proceed. Capture the status for diagnostics only.
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    /// Finds the internal speakers, so headphones cannot silence the alarm.
    private func builtInOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devices) == noErr else { return nil }

        return devices.first { device in
            var transportAddr = address(kAudioDevicePropertyTransportType,
                                        kAudioObjectPropertyScopeGlobal)
            var transport = UInt32(0)
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(device), &transportAddr, 0, nil,
                                             &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }

            // Must actually have output streams — the built-in mic also reports `bltn`.
            var streamAddr = address(kAudioDevicePropertyStreams,
                                     kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(device), &streamAddr, 0, nil,
                                                 &streamSize) == noErr else { return false }
            return streamSize > 0
        }
    }

    public func currentState() -> AudioOutputState {
        let device = defaultOutputDevice
        return AudioOutputState(deviceID: UInt32(device),
                                volume: volume(of: device),
                                muted: isMuted(device))
    }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        if let builtIn = builtInOutputDevice(), builtIn != defaultOutputDevice {
            setDefaultOutputDevice(builtIn)
        }
        let device = defaultOutputDevice
        let muteSuccess = setMuted(false, on: device)
        let volumeSuccess = setVolume(1.0, on: device)

        // If either unmute or volume set failed, the siren would be inaudible.
        if !muteSuccess {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioDevicePropertyMute", status: -1)
        }
        if !volumeSuccess {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioDevicePropertyVolumeScalar", status: -1)
        }
    }

    @discardableResult
    public func restore(_ state: AudioOutputState) -> Bool {
        let device = AudioDeviceID(state.deviceID)
        setDefaultOutputDevice(device)
        let volumeSuccess = setVolume(state.volume, on: device)
        let muteSuccess = setMuted(state.muted, on: device)

        // Return success only if all steps succeeded.
        return volumeSuccess && muteSuccess
    }
}

public final class FakeAudioOutputControl: AudioOutputControlling {
    public private(set) var state: AudioOutputState
    public private(set) var forceCount = 0
    public private(set) var restoredStates: [AudioOutputState] = []
    public var shouldFailRestore = false

    public init(state: AudioOutputState) { self.state = state }

    public func currentState() -> AudioOutputState { state }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        forceCount += 1
        state = AudioOutputState(deviceID: state.deviceID, volume: 1.0, muted: false)
    }

    @discardableResult
    public func restore(_ state: AudioOutputState) -> Bool {
        restoredStates.append(state)
        self.state = state
        return !shouldFailRestore
    }
}
