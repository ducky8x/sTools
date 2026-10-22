// Generates sTools' sounds as 16-bit mono 44.1 kHz WAV files: the UI sound set, and Timer Overlay's sTools
// alarms in an `Alarms` subfolder.
//
// Usage: swift scripts/generate-sounds.swift <outputDirectory>
// (the app's own: swift scripts/generate-sounds.swift Sources/STDesign/Resources/Sounds)
//
// The synthesis is fully deterministic (no system randomness, a fixed-seed noise source), so running it
// twice produces byte-identical files. Every sound is soft and warm: sine fundamentals with a gentle
// extra partial, exponential decays, a raised-cosine attack and a release fade so nothing clicks or pops.
// The UI sounds are short; the alarms are alarm-length (1–2 s) strikes of bars and bells, each partial
// decaying at its own rate so the upper ones die away first.

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
    // The sidebar's glide, one per move of the selection marker, in three lengths for how far (and so how fast) the
    // marker travels: a neighbor, a few rows, most of the sidebar. A longer one starts lower, climbs higher at its
    // top speed and is a little louder. Peaks are set by loudness: the loudest 100 ms, A-weighted, of the long glide
    // matches `page` (about −24 dBFS), the sound it took over from; the medium and short sit 1 and 2 dB under it.
    SoundSpec(name: "glideShort", duration: 0.150, peak: 0.28, releaseSeconds: 0.040) { duration in
        glide(duration: duration, rise: 0.030, settleTau: 0.040, lowHz: 420, highHz: 680, seed: 0x611DE_5)
    },
    SoundSpec(name: "glideMedium", duration: 0.220, peak: 0.29, releaseSeconds: 0.060) { duration in
        glide(duration: duration, rise: 0.045, settleTau: 0.055, lowHz: 370, highHz: 860, seed: 0x611DE_3)
    },
    SoundSpec(name: "glideLong", duration: 0.300, peak: 0.28, releaseSeconds: 0.080) { duration in
        glide(duration: duration, rise: 0.065, settleTau: 0.070, lowHz: 330, highHz: 1_080, seed: 0x611DE_1)
    },
    // The sidebar's detent, one for each row the marker passes over: a tiny tap like a trackpad click or a watch
    // crown's detent. A bright edge, a short click and a low felt thump, all gone within a few milliseconds. It
    // sits about 3 dB under `tick` by the same measure (about −36 dBFS), since several can come in a row.
    SoundSpec(name: "detent", duration: 0.016, peak: 0.20, releaseSeconds: 0.004) { duration in
        render([
            Voice(frequency: 2_900, attack: 0.0004, decayTau: 0.0012, gain: 0.5),
            Voice(frequency: 1_250, attack: 0.0006, decayTau: 0.0025, gain: 1),
            Voice(frequency: 240, glideFrom: 310, glideTau: 0.003, partials: [(1, 1), (2, 0.2)],
                  attack: 0.0012, decayTau: 0.0045, gain: 0.6),
        ], duration: duration)
    },
]

/// A soft "vwoop" for the sidebar's glide. Its level follows the marker's speed through a move: a raised-cosine rise
/// to the top speed, then an exponential settle, the shape of the marker's spring. Breathy noise runs through a
/// resonant band-pass whose center follows the same curve, up from `lowHz` to `highHz` as the marker speeds up and
/// back down as it settles, over a quieter layer of open air that brightens with it.
func glide(duration: Double, rise: Double, settleTau: Double, lowHz: Double, highHz: Double,
           seed: UInt64) -> [Double] {
    var noise = Noise(seed: seed)
    let count = Int((duration * sampleRate).rounded())
    var samples = [Double](repeating: 0, count: count)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    var airSlow = 0.0, airFirst = 0.0, airSecond = 0.0
    let quality = 2.4
    let airHighpass = exp(-2 * Double.pi * 1_000 / sampleRate)
    for index in 0..<count {
        let t = Double(index) / sampleRate
        let speed = t < rise ? 0.5 - 0.5 * cos(Double.pi * t / rise) : exp(-(t - rise) / settleTau)
        let white = noise.next()
        // The resonant body (a constant-peak band-pass), retuned every sample.
        let center = lowHz + (highHz - lowHz) * speed
        let w0 = 2 * Double.pi * center / sampleRate
        let alpha = sin(w0) / (2 * quality)
        let body = (alpha * white - alpha * x2 + 2 * cos(w0) * y1 - (1 - alpha) * y2) / (1 + alpha)
        x2 = x1; x1 = white
        y2 = y1; y1 = body
        // The air: noise above 1 kHz under a two-pole lowpass that opens with the speed.
        airSlow = airHighpass * airSlow + (1 - airHighpass) * white
        let airCoefficient = exp(-2 * Double.pi * (1_400 + 2_200 * speed) / sampleRate)
        airFirst = airCoefficient * airFirst + (1 - airCoefficient) * (white - airSlow)
        airSecond = airCoefficient * airSecond + (1 - airCoefficient) * airFirst
        samples[index] = speed * (body + 0.5 * airSecond)
    }
    return samples
}

// MARK: - Timer Overlay's sTools alarms

/// One partial of a struck bar or bell: its frequency as a multiple of the note's, its level and its decay.
typealias Partial = (ratio: Double, amplitude: Double, decayTau: Double)

/// One strike: a voice per partial, each decaying at its own rate, so the strike mellows as it rings.
func strike(at start: Double, _ frequency: Double, _ partials: [Partial], attack: Double = 0.004,
            gain: Double = 1) -> [Voice] {
    partials.map { partial in
        Voice(start: start, frequency: frequency * partial.ratio, attack: attack, decayTau: partial.decayTau,
              gain: gain * partial.amplitude)
    }
}

/// A soft mallet on a metal bar: the fundamental, a quiet octave and the bar's bright fourth harmonic.
let malletBar: [Partial] = [(1, 1, 0.60), (2, 0.07, 0.25), (4, 0.10, 0.07)]
/// A small glass bell, the family of the UI chime.
let glassBell: [Partial] = [(1, 1, 0.42), (2, 0.20, 0.24), (2.76, 0.11, 0.14), (5.4, 0.035, 0.05)]
/// A tower bell: hum, prime, minor-third tierce, quint and nominal, plus a slightly sharp prime that beats
/// against the true one for the bell's slow shimmer.
let towerBell: [Partial] = [
    (0.5, 0.55, 1.00), (1, 1, 0.75), (1.003, 0.25, 0.75), (1.19, 0.40, 0.50), (1.5, 0.25, 0.36),
    (2, 0.45, 0.32), (2.5, 0.12, 0.18), (3, 0.10, 0.12), (4.2, 0.04, 0.07),
]
/// A wooden bar: a short fundamental and the bar's two inharmonic overtones.
let woodBar: [Partial] = [(1, 1, 0.11), (3.93, 0.22, 0.025), (9.2, 0.05, 0.008)]

/// Alarm-length sounds, 1–2 s, each with its own character. Each peak is set so the sound's loudest 100 ms,
/// A-weighted, sits at about −22.5 dBFS: the four sound equally loud, about as loud as the louder macOS alert
/// sounds (Hero, Blow, Tink) and about 3 dB above Ping, so switching sounds keeps the alarm's volume about the
/// same. The low sounds get higher peaks because the ear hears less of their energy.
let alarmSpecs: [SoundSpec] = [
    // Ember: a mellow arpeggio rising to the octave, C5 E5 G5 C6.
    SoundSpec(name: "ember", duration: 1.600, peak: 0.19, releaseSeconds: 0.400) { duration in
        let notes: [(start: Double, frequency: Double, gain: Double)] = [
            (0.00, 523.25, 0.70), (0.15, 659.25, 0.78), (0.30, 783.99, 0.86), (0.45, 1_046.50, 1.00),
        ]
        return render(notes.flatMap { strike(at: $0.start, $0.frequency, malletBar, gain: $0.gain) },
                      duration: duration)
    },
    // Lantern: a bright bell, an open fifth G5 and D6, struck twice.
    SoundSpec(name: "lantern", duration: 1.400, peak: 0.18, releaseSeconds: 0.350) { duration in
        let strikes: [(start: Double, gain: Double)] = [(0.00, 1.00), (0.32, 0.80)]
        return render(strikes.flatMap {
            strike(at: $0.start, 783.99, glassBell, attack: 0.003, gain: $0.gain)
                + strike(at: $0.start, 1_174.66, glassBell, attack: 0.003, gain: 0.5 * $0.gain)
        }, duration: duration)
    },
    // Toll: one deep tower bell on D4, left to ring.
    SoundSpec(name: "toll", duration: 1.900, peak: 0.38, releaseSeconds: 0.500) { duration in
        render(strike(at: 0, 293.66, towerBell, attack: 0.005), duration: duration)
    },
    // Knock: a wooden knock-knock, twice.
    SoundSpec(name: "knock", duration: 1.200, peak: 0.30, releaseSeconds: 0.300) { duration in
        let knocks: [(start: Double, gain: Double)] = [(0.00, 1.00), (0.13, 0.85), (0.50, 1.00), (0.63, 0.85)]
        return render(knocks.flatMap { strike(at: $0.start, 392.00, woodBar, attack: 0.0015, gain: $0.gain) },
                      duration: duration)
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

func write(_ specs: [SoundSpec], into directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for spec in specs {
        let samples = finish(spec.synthesize(spec.duration), peak: spec.peak, releaseSeconds: spec.releaseSeconds)
        try wavData(samples).write(to: directory.appendingPathComponent("\(spec.name).wav"), options: .atomic)
    }
}

func generate(into directory: URL) throws {
    try write(specs, into: directory)
    try write(alarmSpecs, into: directory.appendingPathComponent("Alarms", isDirectory: true))
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
