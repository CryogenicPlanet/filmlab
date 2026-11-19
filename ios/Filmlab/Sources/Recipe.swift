import Foundation

enum Grain: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case off, weakSmall, strongSmall, weakLarge, strongLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .weakSmall: "Fine"
        case .strongSmall: "Fine, strong"
        case .weakLarge: "Coarse"
        case .strongLarge: "Coarse, strong"
        }
    }

    /// (amount, size) for the grain stage; amount is a fraction of midtone level.
    var parameters: (amount: Double, size: Double) {
        switch self {
        case .off: (0, 1)
        case .weakSmall: (0.035, 1)
        case .strongSmall: (0.07, 1)
        case .weakLarge: (0.035, 2.2)
        case .strongLarge: (0.07, 2.2)
        }
    }
}

/// A look plus the same knobs a Fuji recipe has. Units follow the camera menus.
struct Recipe: Codable, Hashable, Sendable {
    /// The plain iPhone photo: Apple's own processing, no look applied.
    static let nativeID = "iphone"

    var lookID: String
    var isNative: Bool { lookID == Self.nativeID }
    var exposure: Double = 0 // stops
    var highlights: Double = 0 // -2 ... +4
    var shadows: Double = 0 // -2 ... +4
    var color: Double = 0 // -4 ... +4
    var wbRed: Double = 0 // -9 ... +9
    var wbBlue: Double = 0 // -9 ... +9
    var chrome: Double = 0 // 0 off, 1 weak, 2 strong
    var grain: Grain = .off
}

struct Preset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let recipe: Recipe

    /// Mirrors the custom banks saved on the X-S20 on 2026-11-16.
    static let builtIn: [Preset] = [
        Preset(id: "c1", name: "Warm Neg", recipe: Recipe(lookID: "street-neg", highlights: -1, wbRed: 2, wbBlue: -3, chrome: 1)),
        Preset(id: "c2", name: "Vivid", recipe: Recipe(lookID: "vivid-slide", highlights: -1, color: -1, wbBlue: -1, chrome: 1)),
    ]
}

/// The recipe controls, in the order they appear on the camera screen.
enum RecipeParam: String, CaseIterable, Identifiable, Sendable {
    case exposure, highlights, shadows, color, chrome, warmth, tint, grain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .color: "Colour"
        case .chrome: "Chrome"
        case .warmth: "Warmth"
        case .tint: "Tint"
        case .grain: "Grain"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -2...2
        case .highlights, .shadows: -2...4
        case .color: -4...4
        case .chrome: 0...2
        case .warmth, .tint: -9...9
        case .grain: 0...Double(Grain.allCases.count - 1)
        }
    }

    var step: Double {
        switch self {
        case .exposure: 1.0 / 3
        case .highlights, .shadows: 0.5
        default: 1
        }
    }

    /// Ticks drawn long every `major` steps.
    var major: Int {
        switch self {
        case .exposure: 3
        case .highlights, .shadows: 2
        case .warmth, .tint: 3
        default: 1
        }
    }
}

extension Recipe {
    /// Warmth and tint are the camera's WB shift seen as two axes: warm = +red −blue, tint = magenta/green.
    subscript(param: RecipeParam) -> Double {
        get {
            switch param {
            case .exposure: exposure
            case .highlights: highlights
            case .shadows: shadows
            case .color: color
            case .chrome: chrome
            case .warmth: ((wbRed - wbBlue) / 2).rounded()
            case .tint: ((wbRed + wbBlue) / 2).rounded()
            case .grain: Double(Grain.allCases.firstIndex(of: grain) ?? 0)
            }
        }
        set {
            switch param {
            case .exposure: exposure = newValue
            case .highlights: highlights = newValue
            case .shadows: shadows = newValue
            case .color: color = newValue
            case .chrome: chrome = newValue
            case .warmth:
                let tint = self[.tint]
                wbRed = min(max(tint + newValue, -9), 9)
                wbBlue = min(max(tint - newValue, -9), 9)
            case .tint:
                let warmth = self[.warmth]
                wbRed = min(max(newValue + warmth, -9), 9)
                wbBlue = min(max(newValue - warmth, -9), 9)
            case .grain: grain = Grain.allCases[min(max(Int(newValue), 0), Grain.allCases.count - 1)]
            }
        }
    }

    func label(for param: RecipeParam) -> String {
        let v = self[param]
        switch param {
        case .grain: return grain.label
        case .chrome: return ["Off", "Weak", "Strong"][min(max(Int(v), 0), 2)]
        case .exposure: return v == 0 ? "0" : String(format: "%+.1f", v)
        case .highlights, .shadows: return v == 0 ? "0" : String(format: v.truncatingRemainder(dividingBy: 1) == 0 ? "%+.0f" : "%+.1f", v)
        default: return v == 0 ? "0" : String(format: "%+.0f", v)
        }
    }
}
