import Foundation

/// XEP-0082 date-time profile: `CCYY-MM-DDThh:mm:ss[.sss]TZD`.
public enum XMPPDateTime {

    /// Accepts fractional seconds of any precision and any UTC offset; returns
    /// `nil` for anything else rather than guessing.
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        // ISO8601DateFormatter only takes up to three fractional digits.
        // Servers send six (ejabberd) — trim the rest and retry.
        guard let dot = string.firstIndex(of: "."),
              let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return nil }
        let digits = string[string.index(after: dot)..<zone]
        guard digits.count > 3, digits.allSatisfy(\.isNumber) else { return nil }
        let trimmed = String(string[..<dot]) + "." + digits.prefix(3) + string[zone...]
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }

    /// UTC with millisecond precision.
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
