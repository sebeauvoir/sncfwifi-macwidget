import Foundation

/// Conversions tolérantes : les APIs embarquées renvoient leurs nombres tantôt en JSON,
/// tantôt en chaînes (`"speed":"81.22"` chez Icomera).
/// Décode un corps de réponse en objet JSON, y compris quand il est enveloppé en JSONP
/// (`({ … });`) : la plateforme Icomera répond ainsi même sans paramètre `callback`.
enum APIBody {
    static func object(from data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }
        let body = Data(text[start...end].utf8)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// Variante tableau : `/bap/api/products` du portail ICE renvoie un tableau racine.
    static func array(from data: Data) -> [[String: Any]]? {
        try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    static func fetchArray(url: URL,
                           timeout: TimeInterval,
                           completion: @escaping ([[String: Any]]?) -> Void) {
        request(url: url, timeout: timeout) { completion($0.flatMap(array(from:))) }
    }

    /// Requête GET + décodage, sur la file par défaut d'URLSession.
    static func fetch(url: URL,
                      timeout: TimeInterval,
                      completion: @escaping ([String: Any]?) -> Void) {
        request(url: url, timeout: timeout) { completion($0.flatMap(object(from:))) }
    }

    private static func request(url: URL,
                                timeout: TimeInterval,
                                completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("sncfwifi-macapp/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in completion(data) }.resume()
    }
}

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
