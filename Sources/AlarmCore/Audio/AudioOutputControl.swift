import Foundation
import CoreAudio

public struct AudioOutputState: Equatable, Sendable {
    public let deviceID: UInt32
    public let volume: Float                       // main element, or channel 1
    public let muted: Bool
    public let channelVolumes: [UInt32: Float]     // empty when main element was used

    public init(deviceID: UInt32, volume: Float, muted: Bool,
                channelVolumes: [UInt32: Float] = [:]) {
        self.deviceID = deviceID
        self.volume = volume
        self.muted = muted
        self.channelVolumes = channelVolumes
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
    // Stereo channel range for devices without main-element volume.
    // Used by both read (allChannelVolumes) and write (setVolume) paths
    // to ensure symmetry. Assumes built-in speakers are stereo.
    private let stereoChannelRange: ClosedRange<UInt32> = 1...2

    public init() {}

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultOutputDevice() -> (device: AudioDeviceID?, status: OSStatus) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &device)
        return (status == noErr ? device : nil, status)
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

    /// Capture all per-channel volumes for devices without main-element volume.
    /// Returns a dictionary mapping channel element numbers to their volumes.
    /// Empty if main element was used or no channels have volume.
    private func allChannelVolumes(of device: AudioDeviceID) -> [UInt32: Float] {
        var channels: [UInt32: Float] = [:]
        for channel in stereoChannelRange {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(AudioObjectID(device), &addr),
                  AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                             &size, &value) == noErr
            else { continue }
            channels[channel] = value
        }
        return channels
    }

    private func setVolume(_ value: Float, on device: AudioDeviceID) -> (success: Bool, status: OSStatus) {
        var v = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        var main = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(AudioObjectID(device), &main) {
            let status = AudioObjectSetPropertyData(AudioObjectID(device), &main, 0, nil,
                                                    size, &v)
            if status == noErr {
                return (true, noErr)
            }
        }
        // Fall back to per-channel (stereo) volume.
        // Success if at least one channel accepted the write.
        var anyChannelSucceeded = false
        var lastStatus: OSStatus = OSStatus(paramErr)
        for channel in stereoChannelRange {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { continue }
            let status = AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil, size, &v)
            if status == noErr {
                anyChannelSucceeded = true
            } else {
                lastStatus = status
            }
        }
        return (anyChannelSucceeded, anyChannelSucceeded ? noErr : lastStatus)
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

    private func setMuted(_ muted: Bool, on device: AudioDeviceID) -> (success: Bool, status: OSStatus) {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { return (false, OSStatus(paramErr)) }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &value)
        return (status == noErr, status)
    }

    private func setDefaultOutputDevice(_ device: AudioDeviceID) -> OSStatus {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var value = device
        // Do not throw on failure. Failing to switch to built-in speakers means the siren
        // plays through whatever device is currently default — degraded, but still loud.
        // Failing to unmute or set volume means silence. A partial alarm is better than
        // no alarm, so we let the critical unmute/volume steps proceed regardless.
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
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
        let (device, _) = defaultOutputDevice()
        guard let device = device else {
            return AudioOutputState(deviceID: 0, volume: 0, muted: false)
        }
        let vol = volume(of: device)

        // If main element has volume, use it. Otherwise capture all per-channel volumes.
        var addr = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        let hasMainVolume = AudioObjectHasProperty(AudioObjectID(device), &addr)
        let channelVols = hasMainVolume ? [:] : allChannelVolumes(of: device)

        return AudioOutputState(deviceID: UInt32(device),
                                volume: vol,
                                muted: isMuted(device),
                                channelVolumes: channelVols)
    }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        let (currentDevice, _) = defaultOutputDevice()
        // `currentDevice` is optional and `builtIn` is not, so `!=` promotes
        // `builtIn` to `AudioDeviceID?`. That means when the current device
        // cannot be determined (currentDevice == nil) the comparison is true
        // and we switch to the built-in speakers anyway. Deliberate, and
        // aligned with failing toward noise: not knowing where audio is
        // currently going is a reason to force it somewhere we know is loud,
        // not a reason to leave it be.
        if let builtIn = builtInOutputDevice(), builtIn != currentDevice {
            _ = setDefaultOutputDevice(builtIn)
        }
        let (device, getDeviceStatus) = defaultOutputDevice()
        guard let device = device else {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioHardwarePropertyDefaultOutputDevice", status: getDeviceStatus)
        }

        let (muteSuccess, muteStatus) = setMuted(false, on: device)
        let (volumeSuccess, volumeStatus) = setVolume(1.0, on: device)

        // If either unmute or volume set failed, the siren would be inaudible.
        if !muteSuccess {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioDevicePropertyMute", status: muteStatus)
        }
        if !volumeSuccess {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioDevicePropertyVolumeScalar", status: volumeStatus)
        }
    }

    @discardableResult
    public func restore(_ state: AudioOutputState) -> Bool {
        let device = AudioDeviceID(state.deviceID)
        _ = setDefaultOutputDevice(device)

        // If per-channel volumes were captured, restore each channel individually.
        var volumeSuccess = true
        if !state.channelVolumes.isEmpty {
            let size = UInt32(MemoryLayout<Float32>.size)
            for (channel, volume) in state.channelVolumes {
                var v = Float32(volume)
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: channel)
                let status = AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil, size, &v)
                if status != noErr {
                    volumeSuccess = false
                }
            }
        } else {
            // Otherwise restore main-element volume.
            let (success, _) = setVolume(state.volume, on: device)
            volumeSuccess = success
        }

        let (muteSuccess, _) = setMuted(state.muted, on: device)

        // Return success only if all steps succeeded.
        return volumeSuccess && muteSuccess
    }
}

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
public final class FakeAudioOutputControl: AudioOutputControlling {
    public private(set) var state: AudioOutputState
    public private(set) var forceCount = 0
    public private(set) var restoredStates: [AudioOutputState] = []
    public var shouldFailRestore = false
    public var shouldFailForce = false

    public init(state: AudioOutputState) { self.state = state }

    public func currentState() -> AudioOutputState { state }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        if shouldFailForce {
            throw AudioOutputError.propertyWriteFailed(selector: "kAudioDevicePropertyVolumeScalar", status: OSStatus(paramErr))
        }
        forceCount += 1
        // Model `CoreAudioOutputControl.setVolume(1.0, on:)`: it writes 1.0 to
        // whichever elements carry volume — the main element, or, on devices
        // without one, every stereo channel. Dropping `channelVolumes` here
        // would leave them at their pre-force values, so
        // `perChannelVolumesRoundTrip` would "pass" against a fake that never
        // forced the channels the real implementation does force.
        state = AudioOutputState(deviceID: state.deviceID,
                                 volume: 1.0,
                                 muted: false,
                                 channelVolumes: state.channelVolumes
                                     .mapValues { _ in Float(1.0) })
    }

    @discardableResult
    public func restore(_ state: AudioOutputState) -> Bool {
        restoredStates.append(state)
        self.state = state
        return !shouldFailRestore
    }
}
#endif  // DEBUG
