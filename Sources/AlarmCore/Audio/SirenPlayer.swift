import Foundation
import AVFoundation

public protocol SirenPlaying: AnyObject {
    var isPlaying: Bool { get }
    @discardableResult func start() -> Bool
    func stop()
}

/// Oscillator state captured in an unsafe pointer, owned exclusively by the render block
/// between start() and stop(). This avoids ARC, allocation, and isolation checks on the
/// audio thread.
private struct OscillatorState {
    var phase: Double
    var elapsed: Double
    let sampleRate: Double
    let lowHz: Double
    let highHz: Double
    let sweepSeconds: Double
}

/// Generates a two-tone siren in real time. No bundled audio asset, so there
/// is no sample licence to worry about in a paid product.
public final class AVSirenPlayer: SirenPlaying {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// Owned and mutated only by the render block; allocated in start(), deallocated in stop()
    private var oscillatorState: UnsafeMutablePointer<OscillatorState>?
    public private(set) var isPlaying = false

    public init() {}

    @discardableResult
    public func start() -> Bool {
        guard !isPlaying else { return true }

        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100

        // Allocate oscillator state. The render block will own this and mutate it
        // without touching any main-actor-isolated state.
        let state = UnsafeMutablePointer<OscillatorState>.allocate(capacity: 1)
        state.initialize(to: OscillatorState(
            phase: 0,
            elapsed: 0,
            sampleRate: sampleRate,
            lowHz: 700.0,
            highHz: 1100.0,
            sweepSeconds: 0.5
        ))

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            var osc = state.pointee  // Load state once before loop
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // Triangle sweep between the two tones.
                let cyclePosition = osc.elapsed
                    .truncatingRemainder(dividingBy: osc.sweepSeconds * 2) / osc.sweepSeconds
                let ramp = cyclePosition < 1 ? cyclePosition : 2 - cyclePosition
                let frequency = osc.lowHz + (osc.highHz - osc.lowHz) * ramp

                let sample = Float(sin(osc.phase) * 0.9)
                osc.phase += 2 * .pi * frequency / osc.sampleRate
                if osc.phase > 2 * .pi { osc.phase -= 2 * .pi }
                osc.elapsed += 1 / osc.sampleRate

                for buffer in buffers {
                    let pointer = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < pointer.count { pointer[frame] = sample }
                }
            }
            state.pointee = osc  // Write back once after loop
            return noErr
        }

        sourceNode = node
        oscillatorState = state
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            isPlaying = true
            return true
        } catch {
            // Failure: stop engine, detach node, clean up state.
            engine.stop()
            engine.detach(node)
            sourceNode = nil
            state.deinitialize(count: 1)
            state.deallocate()
            oscillatorState = nil
            return false
        }
    }

    public func stop() {
        guard isPlaying else { return }
        // Stop engine and detach node first, so the render block cannot run again.
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil

        // Now deallocate the oscillator state.
        if let state = oscillatorState {
            state.deinitialize(count: 1)
            state.deallocate()
            oscillatorState = nil
        }
        isPlaying = false
    }

    // Isolated deinit runs on MainActor, allowing safe cleanup of audio resources
    // if the player is released while still playing. Prevents memory leak of the
    // manually-allocated oscillatorState pointer.
    isolated deinit {
        if let state = oscillatorState {
            state.deinitialize(count: 1)
            state.deallocate()
        }
    }
}

public final class FakeSirenPlayer: SirenPlaying {
    public private(set) var isPlaying = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public var shouldFailStart = false

    public init() {}

    @discardableResult
    public func start() -> Bool {
        startCount += 1
        if shouldFailStart {
            return false
        }
        isPlaying = true
        return true
    }

    public func stop() {
        stopCount += 1
        isPlaying = false
    }
}
