// Generates sTools' UI sound set as 16-bit mono 44.1 kHz WAV files.
//
// Usage: swift scripts/generate-sounds.swift <outputDirectory>
//
// The synthesis is fully deterministic (no system randomness, a fixed-seed noise source), so running it
// twice produces byte-identical files. Every sound is soft, short and warm: sine fundamentals with a gentle
// extra partial, exponential decays, a raised-cosine attack and a release fade so nothing clicks or pops.

import Foundation

let sampleRate = 44_100.0

/// xorshift64* with a fixed seed; the only source of "randomness" in the script.
struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// One decaying sine voice with optional extra partials and a downward or upward pitch glide at its start.
struct Voice {
    var start: Double = 0
    var frequency: Double
    var glideFrom: Double?
    var glideTau: Double = 0.02
    var partials: [(ratio: Double, amplitude: Double)] = [(1, 1)]
    var attack: Double = 0.003
    var decayTau: Double
    var gain: Double = 1
}

func render(_ voices: [Voice], duration: Double) -> [Double] {
    var samples = [Double](repeating: 0, count: Int((duration * sampleRate).rounded()))
    for voice in voices {
        let first = Int((voice.start * sampleRate).rounded())
        var phase = 0.0
        for index in first..<samples.count {
            let t = Double(index - first) / sampleRate
            let glide = voice.glideFrom.map { $0 - voice.frequency } ?? 0
            let frequency = voice.frequency + glide * exp(-t / voice.glideTau)
            phase += 2 * Double.pi * frequency / sampleRate
            let rise = t < voice.attack ? 0.5 - 0.5 * cos(Double.pi * t / voice.attack) : 1
            let envelope = rise * exp(-t / voice.decayTau)
            var sum = 0.0
            for partial in voice.partials {
                sum += partial.amplitude * sin(phase * partial.ratio)
            }
            samples[index] += voice.gain * envelope * sum
        }
    }
    return samples
}

/// Fades the tail to silence with a half-cosine, then scales so the loudest sample hits `peak`.
func finish(_ samples: [Double], peak: Double, releaseSeconds: Double) -> [Double] {
    var out = samples
    let releaseCount = min(out.count, Int(releaseSeconds * sampleRate))
    for offset in 0..<releaseCount {
        let index = out.count - releaseCount + offset
        out[index] *= 0.5 + 0.5 * cos(Double.pi * Double(offset) / Double(releaseCount))
    }
    out[out.count - 1] = 0
    let loudest = out.map { abs($0) }.max() ?? 1
    let scale = loudest > 0 ? peak / loudest : 0
    return out.map { $0 * scale }
}

struct SoundSpec {
    let name: String
    let duration: Double
    let peak: Double
    let releaseSeconds: Double
    let synthesize: (Double) -> [Double]
}

let specs: [SoundSpec] = [
    SoundSpec(name: "click", duration: 0.040, peak: 0.38, releaseSeconds: 0.012) { duration in
        render([Voice(frequency: 320, glideFrom: 430, glideTau: 0.008, partials: [(1, 1), (2, 0.25)],
                      attack: 0.002, decayTau: 0.011)], duration: duration)
    },
    SoundSpec(name: "tick", duration: 0.025, peak: 0.16, releaseSeconds: 0.008) { duration in
        render([Voice(frequency: 1_400, partials: [(1, 1), (2, 0.15)], attack: 0.0015, decayTau: 0.005)],
               duration: duration)
    },
    SoundSpec(name: "stamp", duration: 0.140, peak: 0.42, releaseSeconds: 0.030) { duration in
        render([
            Voice(frequency: 95, glideFrom: 150, glideTau: 0.02, partials: [(1, 1), (2, 0.3)],
                  attack: 0.002, decayTau: 0.035),
            Voice(frequency: 2_400, partials: [(1, 1)], attack: 0.001, decayTau: 0.004, gain: 0.16),
        ], duration: duration)
    },
    SoundSpec(name: "page", duration: 0.180, peak: 0.22, releaseSeconds: 0.004) { duration in
        var noise = Noise(seed: 0x5EED_0F_5701)
        let count = Int((duration * sampleRate).rounded())
        let highpassCoefficient = exp(-2 * Double.pi * 500 / sampleRate)
        let lowpassCoefficient = exp(-2 * Double.pi * 3_500 / sampleRate)
        var lowSlow = 0.0, lowFirst = 0.0, lowSecond = 0.0
        var samples = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let white = noise.next()
            lowSlow = highpassCoefficient * lowSlow + (1 - highpassCoefficient) * white
            let highpassed = white - lowSlow
            lowFirst = lowpassCoefficient * lowFirst + (1 - lowpassCoefficient) * highpassed
            lowSecond = lowpassCoefficient * lowSecond + (1 - lowpassCoefficient) * lowFirst
            let position = Double(index) / Double(count - 1)
            let swell = pow(sin(Double.pi * pow(position, 0.7)), 2)
            samples[index] = lowSecond * swell
        }
        return samples
    },
    SoundSpec(name: "chime", duration: 0.900, peak: 0.36, releaseSeconds: 0.120) { duration in
        let bell: [(ratio: Double, amplitude: Double)] = [(1, 1), (2.76, 0.22), (5.4, 0.08)]
        return render([
            Voice(frequency: 880, partials: bell, attack: 0.003, decayTau: 0.22),
            Voice(start: 0.09, frequency: 1_318.5, partials: bell, attack: 0.003, decayTau: 0.26, gain: 0.8),
        ], duration: duration)
    },
    SoundSpec(name: "recordStart", duration: 0.160, peak: 0.34, releaseSeconds: 0.040) { duration in
        render([
            Voice(frequency: 523.25, partials: [(1, 1), (2, 0.2)], attack: 0.004, decayTau: 0.04),
            Voice(start: 0.07, frequency: 783.99, partials: [(1, 1), (2, 0.2)], attack: 0.004, decayTau: 0.04),
        ], duration: duration)
    },
    SoundSpec(name: "recordStop", duration: 0.160, peak: 0.34, releaseSeconds: 0.040) { duration in
        render([
            Voice(frequency: 783.99, partials: [(1, 1), (2, 0.2)], attack: 0.004, decayTau: 0.04),
            Voice(start: 0.07, frequency: 523.25, partials: [(1, 1), (2, 0.2)], attack: 0.004, decayTau: 0.04),
        ], duration: duration)
    },
]

func wavData(_ samples: [Double]) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let byteCount = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    append(36 + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate) * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    for sample in samples {
        append(Int16((max(-1, min(1, sample)) * 32_767).rounded()))
    }
    return data
}

func generate(into directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for spec in specs {
        let samples = finish(spec.synthesize(spec.duration), peak: spec.peak, releaseSeconds: spec.releaseSeconds)
        try wavData(samples).write(to: directory.appendingPathComponent("\(spec.name).wav"), options: .atomic)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate-sounds.swift <outputDirectory>\n".utf8))
    exit(2)
}
do {
    try generate(into: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
} catch {
    FileHandle.standardError.write(Data("generate-sounds failed: \(error)\n".utf8))
    exit(1)
}
