import Foundation

/// Conversions tolérantes : les APIs embarquées renvoient leurs nombres tantôt en JSON,
/// tantôt en chaînes (`"speed":"81.22"` chez Icomera).
enum APIValue {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String:   return Double(s.trimmingCharacters(in: .whitespaces))
        default:                return nil
        }
    }

    static func int(_ value: Any?) -> Int {
        Int(double(value) ?? 0)
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:     return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "oui":  return true
            case "false", "0", "no", "non":  return false
            default: return nil
            }
        default: return nil
        }
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// Date ISO 8601 → "HH:mm" en heure locale.
    static func time(_ iso: String?) -> String? {
        date(iso).map(time)
    }

    static func time(_ date: Date) -> String {
        hourMinute.string(from: date)
    }

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
}
