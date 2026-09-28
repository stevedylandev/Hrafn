import CryptoKit
import Foundation

/// XEP-0392 Consistent Color Generation: the same colour for the same name in
/// every client, for avatar placeholders and nicknames.
public enum ConsistentColor {

    /// §5.1: SHA-1 of the UTF-8 identifier; the first two bytes as a
    /// little-endian 16-bit number, mapped onto 0..<360 degrees.
    public static func hue(for identifier: String) -> Double {
        let digest = Array(Insecure.SHA1.hash(data: Data(identifier.utf8)))
        let value = UInt16(digest[0]) | UInt16(digest[1]) << 8
        return Double(value) / 65536 * 360
    }

    /// §5.2: the hue at saturation 100 and lightness 50 in HSLuv, as sRGB
    /// components in 0...1.
    public static func rgb(for identifier: String) -> (red: Double, green: Double, blue: Double) {
        HSLuv.rgb(hue: hue(for: identifier), saturation: 100, lightness: 50)
    }
}

/// HSLuv: CIE LCh(uv) with the chroma scaled to the largest the sRGB gamut
/// allows at that hue and lightness, so every hue looks equally bright.
enum HSLuv {

    /// XYZ (D65) to linear sRGB.
    private static let m: [(Double, Double, Double)] = [
        (3.240969941904521, -1.537383177570093, -0.498610760293),
        (-0.96924363628087, 1.87596750150772, 0.041555057407175),
        (0.055630079696993, -0.20397695888897, 1.056971514242878),
    ]
    /// D65 white point in CIE u'v'.
    private static let refU = 0.19783000664283
    private static let refV = 0.46831999493879
    /// CIE L* constants: (29/3)^3 and (6/29)^3.
    private static let kappa = 903.2962962
    private static let epsilon = 0.0088564516

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let chroma: Double
        if lightness > 99.9999999 || lightness < 0.00000001 {
            chroma = 0
        } else {
            chroma = maxChroma(lightness: lightness, hue: hue) / 100 * saturation
        }
        let radians = hue / 180 * .pi
        let (x, y, z) = xyz(l: lightness, u: cos(radians) * chroma, v: sin(radians) * chroma)
        func channel(_ row: (Double, Double, Double)) -> Double {
            let linear = row.0 * x + row.1 * y + row.2 * z
            let companded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return min(1, max(0, companded))
        }
        return (channel(m[0]), channel(m[1]), channel(m[2]))
    }

    /// CIE L*u*v* to XYZ.
    private static func xyz(l: Double, u: Double, v: Double) -> (Double, Double, Double) {
        guard l > 0 else { return (0, 0, 0) }
        let varU = u / (13 * l) + refU
        let varV = v / (13 * l) + refV
        let y = l <= 8 ? l / kappa : pow((l + 16) / 116, 3)
        let x = -(9 * y * varU) / ((varU - 4) * varV - varU * varV)
        let z = (9 * y - 15 * varV * y - varV * x) / (3 * varV)
        return (x, y, z)
    }

    /// The distance from the grey axis to the nearest edge of the sRGB gamut
    /// along `hue`, at `lightness`: each channel reaching 0 or 1 is a line in
    /// the u*v* plane.
    private static func maxChroma(lightness l: Double, hue: Double) -> Double {
        let radians = hue / 180 * .pi
        let sub1 = pow(l + 16, 3) / 1560896
        let sub2 = sub1 > epsilon ? sub1 : l / kappa
        var shortest = Double.greatestFiniteMagnitude
        for (m1, m2, m3) in m {
            for t in [0.0, 1.0] {
                let top1 = (284517 * m1 - 94839 * m3) * sub2
                let top2 = (838422 * m3 + 769860 * m2 + 731718 * m1) * l * sub2 - 769860 * t * l
                let bottom = (632260 * m3 - 126452 * m2) * sub2 + 126452 * t
                let slope = top1 / bottom
                let intercept = top2 / bottom
                let length = intercept / (sin(radians) - slope * cos(radians))
                if length >= 0 { shortest = min(shortest, length) }
            }
        }
        return shortest
    }
}
