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
    /// The sample rate the oscillator runs at. An engine that has never been
    /// started can report 0 for its output format, hence the fallback.
    public static func renderSampleRate(hardware: Double) -> Double {
        hardware > 0 ? hardware : 44_100
    }

    /// The format the source node is created with AND connected with, so the
    /// declared rate cannot drift from the rate the oscillator assumes.
    public static func renderFormat(hardware: Double) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: renderSampleRate(hardware: hardware),
                      channels: 2)
    }

    public func start() -> Bool {
        guard !isPlaying else { return true }

        // The oscillator's rate and the connection's declared rate MUST be the
        // same number. They were not: the rate was read from the output device
        // (48 kHz here) while `connect(..., format: nil)` adopted the mixer's
        // rate (44.1 kHz), so the tone came out about 9% off pitch. Both now
        // derive from one function; `SirenFormatTests` pins that they agree.
        let hardwareRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let sampleRate = Self.renderSampleRate(hardware: hardwareRate)
        guard let renderFormat = Self.renderFormat(hardware: hardwareRate) else { return false }

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

        let node = AVAudioSourceNode(format: renderFormat,
                                     renderBlock: Self.makeRenderBlock(state: state))

        sourceNode = node
        oscillatorState = state
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
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

    /// ISOLATION INVARIANT (not checked by the compiler): this block runs on
    /// the real-time audio thread, never on the main actor, yet a main-actor
    /// closure converts to `AVAudioSourceNodeRenderBlock` with no diagnostic.
    /// It is safe only because it touches nothing but its own `state` pointer,
    /// which is owned exclusively by the render block between start() and
    /// stop(). Adding any `self.` reference here — reading `isPlaying`, calling
    /// a method, capturing the engine — would be a data race on main-actor
    /// state from the audio thread, with no warning to tell you.
    ///
    /// Declaring it `nonisolated static` is the guard: there is no `self` in
    /// scope, so such a reference becomes a compile error rather than a silent
    /// race. Do not turn this back into an inline closure.
    private nonisolated static func makeRenderBlock(
        state: UnsafeMutablePointer<OscillatorState>
    ) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
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

    // Isolated deinit reuses stop() to ensure correct teardown ordering: the engine
    // and render node must stop before deallocating the oscillatorState pointer.
    // This is the only teardown path, preventing the duplication that led to
    // use-after-free in an earlier version. oscillatorState is non-nil only when
    // isPlaying == true, so stop()'s guard will never skip a live allocation.
    isolated deinit {
        stop()
    }
}

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
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
#endif  // DEBUG
