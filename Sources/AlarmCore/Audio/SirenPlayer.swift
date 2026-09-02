import Foundation
import AVFoundation

public protocol SirenPlaying: AnyObject {
    var isPlaying: Bool { get }
    func start()
    func stop()
}

/// Generates a two-tone siren in real time. No bundled audio asset, so there
/// is no sample licence to worry about in a paid product.
public final class AVSirenPlayer: SirenPlaying {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var phase: Double = 0
    private var elapsed: Double = 0
    public private(set) var isPlaying = false

    private let lowHz = 700.0
    private let highHz = 1100.0
    private let sweepSeconds = 0.5

    public init() {}

    public func start() {
        guard !isPlaying else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // Triangle sweep between the two tones.
                let cyclePosition = self.elapsed
                    .truncatingRemainder(dividingBy: self.sweepSeconds * 2) / self.sweepSeconds
                let ramp = cyclePosition < 1 ? cyclePosition : 2 - cyclePosition
                let frequency = self.lowHz + (self.highHz - self.lowHz) * ramp

                let sample = Float(sin(self.phase) * 0.9)
                self.phase += 2 * .pi * frequency / sampleRate
                if self.phase > 2 * .pi { self.phase -= 2 * .pi }
                self.elapsed += 1 / sampleRate

                for buffer in buffers {
                    let pointer = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < pointer.count { pointer[frame] = sample }
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            isPlaying = true
        } catch {
            engine.detach(node)
            sourceNode = nil
        }
    }

    public func stop() {
        guard isPlaying else { return }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        phase = 0
        elapsed = 0
        isPlaying = false
    }
}

public final class FakeSirenPlayer: SirenPlaying {
    public private(set) var isPlaying = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public init() {}
    public func start() { startCount += 1; isPlaying = true }
    public func stop() { stopCount += 1; isPlaying = false }
}
