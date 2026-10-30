import Foundation

extension Int {
    /// `Int(x)` that never traps: NaN gives 0, values past Int's range saturate, fractions truncate toward zero.
    public init(saturating x: Double) {
        if x.isNaN { self = 0 }
        else if x >= 9.2e18 { self = .max }
        else if x <= -9.2e18 { self = .min }
        else { self = Int(x) }
    }
}

extension Double {
    /// The value, or `fallback` when it is NaN or infinite.
    public func finite(or fallback: Double) -> Double { isFinite ? self : fallback }
}
