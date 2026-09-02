import Testing
import Foundation
import AVFoundation
@testable import AlarmCore

// The bug this pins: the siren generated its waveform at the sample rate read
// from the OUTPUT device (48000 on this machine) while being connected to the
// mixer with `format: nil`, which adopted the mixer's rate (44100). The tone
// came out ~9% off pitch. The rate the oscillator uses and the rate the
// connection declares must be the same number, by construction.
@Test func theOscillatorRateMatchesTheDeclaredFormatRate() {
    for hardware in [44_100.0, 48_000.0, 96_000.0] {
        let rate = AVSirenPlayer.renderSampleRate(hardware: hardware)
        let format = AVSirenPlayer.renderFormat(hardware: hardware)
        #expect(format?.sampleRate == rate,
                "oscillator would run at \(rate) while the connection declares \(String(describing: format?.sampleRate))")
    }
}

@Test func aUsableHardwareRateIsAdopted() {
    #expect(AVSirenPlayer.renderSampleRate(hardware: 48_000) == 48_000)
    #expect(AVSirenPlayer.renderSampleRate(hardware: 44_100) == 44_100)
}

// An engine that has never been started can report 0 for its output format.
@Test func anUnusableHardwareRateFallsBackTo44100() {
    #expect(AVSirenPlayer.renderSampleRate(hardware: 0) == 44_100)
    #expect(AVSirenPlayer.renderSampleRate(hardware: -1) == 44_100)
}

@Test func theRenderFormatIsStereoFloat() {
    let format = AVSirenPlayer.renderFormat(hardware: 48_000)
    #expect(format?.channelCount == 2)
    #expect(format?.isInterleaved == false)
}
