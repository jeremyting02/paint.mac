import Foundation

/// Coverage of a round antialiased tip before opacity and selection clipping.
struct BrushTip {
    private static let hardSigma = 0.39
    private let profile: [Double]
    private let softReach: Double

    init(radius: CGFloat, hardness: Int) {
        let hardness = Double(min(100, max(0, hardness))) / 100
        if hardness == 1 {
            profile = []
            softReach = 0
            return
        }

        // Approximate a feathered dab by blurring a smaller circular core. The
        // normalized profile lets pressure scale the dab without rebuilding it.
        let core = 0.4 + 0.6 * hardness
        let sigma = hypot(Self.hardSigma / max(Double(radius), 0.5), 0.39 * (1 - hardness))
        let reach = core + 3.5 * sigma
        softReach = reach
        let samples = 192
        let strips = 32
        let dx = 2 * core / Double(strips)
        let normalization = dx / (sqrt(2 * .pi) * sigma)
        let slices = (0..<strips).map { strip in
            let x = -core + (Double(strip) + 0.5) * dx
            let y = sqrt(max(0, core * core - x * x))
            return (x, erf(y / (sqrt(2) * sigma)))
        }
        profile = (0...samples).map { index in
            let distance = reach * Double(index) / Double(samples)
            return min(1, normalization * slices.reduce(0) { sum, slice in
                let offset = (distance - slice.0) / sigma
                return sum + slice.1 * exp(-0.5 * offset * offset)
            })
        }
    }

    func reach(radius: CGFloat) -> CGFloat {
        profile.isEmpty ? radius + (radius <= 0.5 ? 0.5 : 1.25) : radius * softReach
    }

    func coverage(distance: CGFloat, radius: CGFloat) -> UInt8 {
        let fraction: Double
        if profile.isEmpty {
            if radius <= 0.5 {
                fraction = max(0, 1 - Double(distance / (radius + 0.5)))
            } else {
                let edge = Double(distance - radius)
                if edge <= -1.25 { return 255 }
                // A circular edge loses more coverage than a straight edge under the
                // same blur. Approximate the inward shift of the half-coverage contour.
                let curvature = Self.hardSigma * Self.hardSigma / (2 * Double(radius))
                let feather = 0.5 * erfc((edge + curvature) / (sqrt(2) * Self.hardSigma))
                if radius < 1 {
                    let linear = min(1, max(0, Double(radius + 0.5 - distance)))
                    fraction = linear + (feather - linear) * Double(2 * radius - 1)
                } else {
                    fraction = feather
                }
            }
        } else {
            let index = Double(distance / radius) / softReach * Double(profile.count - 1)
            let lower = Int(index)
            guard lower < profile.count - 1 else { return 0 }
            fraction = profile[lower] + (profile[lower + 1] - profile[lower]) * (index - Double(lower))
        }
        let strength = min(1, 4 * Double(radius * radius))
        return UInt8(clamping: Int((fraction * strength * 255).rounded()))
    }
}
