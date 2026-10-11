import Foundation

/// A channel's parametric EQ, laid out like a console channel strip: a 12 dB/octave high-pass and
/// four bands — LF, LMF, HMF, HF — each with frequency, gain and Q. LF and HF switch between a bell
/// and a shelf. It runs after the channel's 31 bands: the curve heard is both.
struct EQParametric: Codable, Equatable {
    struct Band: Codable, Equatable {
        var frequency: Float
        var gain: Float
        var q: Float
        var shelf: Bool
    }

    /// A dial. Frequency and Q turn logarithmically, gain linearly.
    enum Knob: Equatable {
        case highPass
        case frequency(Int)
        case gain(Int)
        case q(Int)

        var range: ClosedRange<Float> {
            switch self {
            case .highPass: return 20...500
            case .frequency(let band): return EQParametric.frequencyRanges[band]
            case .gain: return EQCurve.range
            case .q: return 0.4...8
            }
        }

        /// 0…1 along the dial's travel.
        func position(of value: Float) -> Float {
            let r = range
            if case .gain = self { return (value - r.lowerBound) / (r.upperBound - r.lowerBound) }
            return log(value / r.lowerBound) / log(r.upperBound / r.lowerBound)
        }

        func value(at position: Float) -> Float {
            let r = range, t = min(1, max(0, position))
            if case .gain = self { return r.lowerBound + t * (r.upperBound - r.lowerBound) }
            return r.lowerBound * pow(r.upperBound / r.lowerBound, t)
        }

        func clamp(_ value: Float) -> Float {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
        }
    }

    static let bandNames = ["LF", "LMF", "HMF", "HF"]
    /// The high-pass and the four bands: the slots `sections` fills.
    static let sectionCount = 5
    /// Overlapping, as on an SSL-style strip, so each dial's travel stays fine enough to set by hand.
    static let frequencyRanges: [ClosedRange<Float>] = [20...600, 60...2500, 500...8000, 1500...20000]
    /// LF and HF; the mid bands are always bells.
    static let shelvingBands = [0, 3]

    static let flat = EQParametric(highPassOn: false, highPass: 80, bands: [
        Band(frequency: 100, gain: 0, q: 0.7, shelf: true),
        Band(frequency: 400, gain: 0, q: 1, shelf: false),
        Band(frequency: 2500, gain: 0, q: 1, shelf: false),
        Band(frequency: 8000, gain: 0, q: 0.7, shelf: true)])

    var highPassOn: Bool
    var highPass: Float
    var bands: [Band]

    /// Setting clamps to the knob's range.
    subscript(knob: Knob) -> Float {
        get {
            switch knob {
            case .highPass: return highPass
            case .frequency(let band): return bands[band].frequency
            case .gain(let band): return bands[band].gain
            case .q(let band): return bands[band].q
            }
        }
        set {
            let value = knob.clamp(newValue)
            switch knob {
            case .highPass: highPass = value
            case .frequency(let band): bands[band].frequency = value
            case .gain(let band): bands[band].gain = value
            case .q(let band): bands[band].q = value
            }
        }
    }

    /// Whether the dial does anything now: the high-pass's when it is on, Q only on a bell.
    func isActive(_ knob: Knob) -> Bool {
        switch knob {
        case .highPass: return highPassOn
        case .q(let band): return !bands[band].shelf
        case .frequency, .gain: return true
        }
    }

    /// Every value inside its range and four bands, whatever a file held.
    func clamped() -> EQParametric {
        var out = Self.flat
        out.highPassOn = highPassOn
        out[.highPass] = highPass
        for band in out.bands.indices where bands.indices.contains(band) {
            for knob in [Knob.frequency(band), .gain(band), .q(band)] { out[knob] = self[knob] }
            out.bands[band].shelf = bands[band].shelf && Self.shelvingBands.contains(band)
        }
        return out
    }

    /// One section per slot — the high-pass, then the four bands — identity where off or at 0 dB, so
    /// a section keeps its slot (and its filter state across a change) whatever else is switched.
    /// Frequencies are held below 0.45 fs.
    func sections(sampleRate: Double) -> [EQProfileDesign.Biquad] {
        let ceiling = 0.45 * sampleRate
        var out = [highPassOn ? Self.highPass(min(Double(highPass), ceiling), sampleRate) : .identity]
        for (index, band) in bands.enumerated() {
            let frequency = min(Double(band.frequency), ceiling), gain = Double(band.gain)
            out.append(gain == 0 ? .identity
                : band.shelf ? Self.shelf(high: index != 0, frequency, gain, sampleRate)
                : EQProfileDesign.peaking(frequency: frequency, gainDB: gain, sampleRate: sampleRate, q: Double(band.q)))
        }
        return out
    }

    /// Shelves and the high-pass are RBJ designs at Butterworth Q: no overshoot, so no Q dial.
    private static let butterworthQ = 1 / 2.0.squareRoot()

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double,
                                   _ a0: Double, _ a1: Double, _ a2: Double) -> EQProfileDesign.Biquad {
        EQProfileDesign.Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func highPass(_ frequency: Double, _ sampleRate: Double) -> EQProfileDesign.Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate, c = cos(w0), alpha = sin(w0) / (2 * butterworthQ)
        return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    /// RBJ shelf; `frequency` is where the shelf reaches half its gain in dB.
    private static func shelf(high: Bool, _ frequency: Double, _ gainDB: Double,
                              _ sampleRate: Double) -> EQProfileDesign.Biquad {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0), k = 2 * A.squareRoot() * sin(w0) / (2 * butterworthQ)
        let s: Double = high ? -1 : 1
        return normalized(A * ((A + 1) - s * (A - 1) * c + k),
                          s * 2 * A * ((A - 1) - s * (A + 1) * c),
                          A * ((A + 1) - s * (A - 1) * c - k),
                          (A + 1) + s * (A - 1) * c + k,
                          -s * 2 * ((A - 1) + s * (A + 1) * c),
                          (A + 1) + s * (A - 1) * c - k)
    }
}
