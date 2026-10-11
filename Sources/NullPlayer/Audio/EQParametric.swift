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

    /// A band's place on the strip: its name, its frequency dial's travel, the shelf it can switch
    /// to, and its flat setting.
    struct BandSpec {
        enum Shelf { case none, low, high }

        let name: String
        let range: ClosedRange<Float>
        let shelf: Shelf
        let flat: Band
    }

    /// Ranges overlap, as on an SSL-style strip, so each dial's travel stays fine enough to set by
    /// hand. The mid bands are always bells.
    static let layout = [
        BandSpec(name: "LF", range: 20...600, shelf: .low, flat: Band(frequency: 100, gain: 0, q: 0.7, shelf: true)),
        BandSpec(name: "LMF", range: 60...2500, shelf: .none, flat: Band(frequency: 400, gain: 0, q: 1, shelf: false)),
        BandSpec(name: "HMF", range: 500...8000, shelf: .none, flat: Band(frequency: 2500, gain: 0, q: 1, shelf: false)),
        BandSpec(name: "HF", range: 1500...20000, shelf: .high, flat: Band(frequency: 8000, gain: 0, q: 0.7, shelf: true))]
    /// The high-pass and the bands: the slots `sections` fills.
    static let sectionCount = 1 + layout.count

    static let flat = EQParametric(highPassOn: false, highPass: 80, bands: layout.map(\.flat))

    /// A dial. Frequency and Q turn logarithmically, gain linearly.
    enum Knob: Equatable {
        case highPass
        case frequency(Int)
        case gain(Int)
        case q(Int)

        static func knobs(of band: Int) -> [Knob] { [.frequency(band), .gain(band), .q(band)] }

        var range: ClosedRange<Float> {
            switch self {
            case .highPass: return 20...500
            case .frequency(let band): return EQParametric.layout[band].range
            case .gain: return EQCurve.range
            case .q: return 0.4...8
            }
        }

        private var isLogarithmic: Bool {
            if case .gain = self { return false }
            return true
        }

        /// 0…1 along the dial's travel.
        func position(of value: Float) -> Float {
            let r = range
            return isLogarithmic ? log(value / r.lowerBound) / log(r.upperBound / r.lowerBound)
                : (value - r.lowerBound) / (r.upperBound - r.lowerBound)
        }

        func value(at position: Float) -> Float {
            let r = range, t = min(1, max(0, position))
            return isLogarithmic ? r.lowerBound * pow(r.upperBound / r.lowerBound, t)
                : r.lowerBound + t * (r.upperBound - r.lowerBound)
        }

        func clamp(_ value: Float) -> Float {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
        }
    }

    /// A switch: the high-pass in or out, or a band between bell and shelf.
    enum Switch: Equatable {
        case highPass
        case shelf(Int)

        /// The high-pass's, then each shelving band's.
        static let all = [Switch.highPass]
            + EQParametric.layout.indices.filter { EQParametric.layout[$0].shelf != .none }.map(Switch.shelf)
    }

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

    /// Setting a shelf on a band that has none leaves it a bell.
    subscript(toggle: Switch) -> Bool {
        get {
            switch toggle {
            case .highPass: return highPassOn
            case .shelf(let band): return bands[band].shelf
            }
        }
        set {
            switch toggle {
            case .highPass: highPassOn = newValue
            case .shelf(let band): bands[band].shelf = newValue && Self.layout[band].shelf != .none
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
            for knob in Knob.knobs(of: band) { out[knob] = self[knob] }
            out[.shelf(band)] = bands[band].shelf
        }
        return out
    }

    /// One section per slot — the high-pass, then the four bands — identity where off or at 0 dB, so
    /// a section keeps its slot (and its filter state across a change) whatever else is switched.
    /// Frequencies are held below 0.45 fs.
    func sections(sampleRate: Double) -> [EQProfileDesign.Biquad] {
        let ceiling = 0.45 * sampleRate
        var out = [highPassOn ? Self.highPass(min(Double(highPass), ceiling), sampleRate) : .identity]
        for (band, spec) in zip(bands, Self.layout) {
            let frequency = min(Double(band.frequency), ceiling), gain = Double(band.gain)
            guard gain != 0 else { out.append(.identity); continue }
            switch band.shelf ? spec.shelf : .none {
            case .none:
                out.append(EQProfileDesign.peaking(frequency: frequency, gainDB: gain, sampleRate: sampleRate, q: Double(band.q)))
            case .low: out.append(Self.shelf(high: false, frequency, gain, sampleRate))
            case .high: out.append(Self.shelf(high: true, frequency, gain, sampleRate))
            }
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
