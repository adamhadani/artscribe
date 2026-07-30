import Accelerate
import Foundation  // log, log2, sin

@testable import TimeStretch

// Measurement shared by every stretcher suite in this target. Lifted out of
// `StretchQualityTests` when the Signalsmith backend arrived and needed the same
// FFT estimator: two copies of a pitch measurement would be two things to keep
// honest, and a bound is only as trustworthy as the ruler behind it.

/// Estimates a pure tone's frequency via FFT peak (spec §9's specified method),
/// refined with quadratic interpolation of the log-magnitude around the peak bin
/// for sub-bin precision. Uses the largest power-of-two window that fits the
/// input, windowed with a Hann function to suppress spectral leakage.
func estimateFrequencyFFT(_ samples: [Float], sampleRate: Double) -> Double {
    var n = 1
    var log2n: vDSP_Length = 0
    while n * 2 <= samples.count {
        n *= 2
        log2n += 1
    }
    guard n >= 1024, let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return 0
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var windowed = [Float](repeating: 0, count: n)
    samples.withUnsafeBufferPointer { sp in
        guard let sBase = sp.baseAddress else { return }
        vDSP_vmul(sBase, 1, window, 1, &windowed, 1, vDSP_Length(n))
    }

    var realp = [Float](repeating: 0, count: n / 2)
    var imagp = [Float](repeating: 0, count: n / 2)
    var magnitudes = [Float](repeating: 0, count: n / 2)

    let peakBin: Int = realp.withUnsafeMutableBufferPointer { realPtr in
        imagp.withUnsafeMutableBufferPointer { imagPtr in
            guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else {
                return 0
            }
            var splitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)
            windowed.withUnsafeBufferPointer { wp in
                guard let wBase = wp.baseAddress else { return }
                wBase.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
            var bin = 1
            var peakVal: Float = -1
            for i in 1..<(n / 2 - 1) where magnitudes[i] > peakVal {
                peakVal = magnitudes[i]
                bin = i
            }
            return bin
        }
    }
    guard peakBin > 0, peakBin < magnitudes.count - 1 else { return 0 }

    // Quadratic (parabolic) interpolation of the log-magnitude spectrum around
    // the peak bin resolves the true peak location to a fraction of a bin.
    let m1 = log(Double(magnitudes[peakBin - 1]) + 1e-12)
    let m0 = log(Double(magnitudes[peakBin]) + 1e-12)
    let m2 = log(Double(magnitudes[peakBin + 1]) + 1e-12)
    let denom = m1 - 2 * m0 + m2
    let delta = denom != 0 ? 0.5 * (m1 - m2) / denom : 0
    let refinedBin = Double(peakBin) + delta
    return refinedBin * sampleRate / Double(n)
}

func sine(freq: Double, seconds: Double, sampleRate: Double) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
}

/// Pushes mono input through a stretcher and collects all output.
func runStretcher(
    _ s: TimeStretcher, input: [Float],
    sampleRate: Double, block: Int = 1024
) -> [Float] {
    // Mono only. A single-element array of channel pointers is built explicitly
    // below (rather than reinterpreting the address of one scalar pointer
    // variable as if it were an array) so this generalises safely if a future
    // caller extends it to more channels; the scalar-address trick only "works"
    // by coincidence for channel count 1 and is a stack-buffer-overflow for any
    // channel index beyond that (confirmed under AddressSanitizer).
    let channels = 1
    s.configure(sampleRate: sampleRate, channels: channels, maxBlock: block)
    var out: [Float] = []
    var scratch = [Float](repeating: 0, count: block * 8)
    var offset = 0

    func drain() {
        while s.available() > 0 {
            let want = Swift.min(s.available(), scratch.count)
            let got = scratch.withUnsafeMutableBufferPointer { buf -> Int in
                var channelPtrs = [UnsafeMutablePointer<Float>?](
                    repeating: buf.baseAddress, count: channels)
                return channelPtrs.withUnsafeMutableBufferPointer { ptrs in
                    guard let base = ptrs.baseAddress else { return 0 }
                    return s.retrieve(base, frames: want)
                }
            }
            guard got > 0 else { break }
            out.append(contentsOf: scratch[0..<got])
        }
    }

    while offset < input.count {
        let n = Swift.min(block, input.count - offset)
        input.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let channelPtrs = [UnsafePointer<Float>?](repeating: base + offset, count: channels)
            channelPtrs.withUnsafeBufferPointer { ptrs in
                guard let base = ptrs.baseAddress else { return }
                s.process(base, frames: n, final: offset + n >= input.count)
            }
        }
        offset += n
        drain()
    }
    drain()
    return out
}
