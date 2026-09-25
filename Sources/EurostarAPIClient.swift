import Foundation

/// Instantané consolidé de l'API Icomera « Internet Ombord » (flotte Eurostar).
struct EurostarSnapshot {
    var speedKmh: Int = 0
    var latitude: Double?
    var longitude: Double?
    var altitudeM: Double?
    /// « Course made good » : cap réel en degrés (0 = nord, 90 = est).
    var headingDeg: Double?
    var satellites: Int?

    var dataUsedMB: Double?
    var dataLimitMB: Double?
    /// Débit descendant maximal de la session, en Mbit/s.
    var bandwidthDownMbps: Double?
    /// Temps de session restant, en secondes. Absent quand l'accès est illimité.
    var sessionSecondsLeft: Int?

    var devicesOnline: Int?
    var devicesTotal: Int?

    var isOnline: Bool?
    /// Le routeur Icomera agrège plusieurs SIM : un opérateur peut porter plusieurs liens.
    var operators: [UplinkOperator] = []
    var uplinkTechnology: String?
    /// Meilleur RSSI (dBm) parmi les liens disponibles.
    var uplinkRSSI: Int?
    var uplinkLinksUp: Int = 0
    var uplinkLinksTotal: Int = 0

    var systemName: String?
    /// Extrait de `system_name` : « eurostar-4342-2i » → « 4342 ».
    var rameNumber: String?

    var raw: [String: Any] = [:]

    var hasPosition: Bool { latitude != nil && longitude != nil }

    /// RSSI du meilleur lien montant ramené sur 0…5. Repères LTE : −60 dBm excellent,
    /// −100 dBm quasi inutilisable.
    var quality0to5: Int? {
        guard let rssi = uplinkRSSI else { return nil }
        switch rssi {
        case (-60)...:      return 5
        case (-70)...(-61): return 4
        case (-80)...(-71): return 3
        case (-90)...(-81): return 2
        case (-100)...(-91): return 1
        default:            return 0
        }
    }

    /// Libellé lisible de la technologie du lien montant (« lte » → « 4G »).
    var technologyLabel: String? {
        guard let tech = uplinkTechnology?.lowercased(), !tech.isEmpty else { return nil }
        switch tech {
        case "nr", "5g", "5gnr":              return "5G"
        // ENDC = LTE + NR en double connectivité, soit de la 5G non-standalone.
        case "endc", "lte-nr", "nsa":         return "5G"
        case "lte", "lte-a", "4g":            return "4G"
        case "hsdpa", "hsupa", "hspa", "hspa+": return "3G+"
        case "umts", "3g", "wcdma":           return "3G"
        case "edge", "gprs", "gsm", "2g":     return "2G"
        case "satellite", "sat":              return "Satellite"
        default:                              return tech.uppercased()
        }
    }
}

/// Un opérateur mobile porteur d'un ou plusieurs liens montants.
struct UplinkOperator {
    let name: String
    let links: Int
}

/// Interroge le portail Icomera embarqué en parallèle. Les réponses sont du JSONP **même
/// sans paramètre `callback`** (`({ … });`), d'où le décapsulage avant `JSONSerialization`.
final class EurostarAPIClient {
    private static let base = "https://www.ombord.info/api/jsonp"

    private let positionURL     = URL(string: "\(base)/position/")!
    private let userURL         = URL(string: "\(base)/user/")!
    private let usersURL        = URL(string: "\(base)/users/")!
    private let connectivityURL = URL(string: "\(base)/connectivity/")!
    private let systemURL       = URL(string: "\(base)/system/")!

    private let timeout: TimeInterval = 5
    /// Relue chaque seconde : une réponse plus lente ne sert plus à rien.
    private let speedTimeout: TimeInterval = 2

    /// Sonde légère : un seul appel, pour savoir si on est à bord d'un Eurostar.
    func probe(completion: @escaping (Bool) -> Void) {
        if MockTrainData.shared.isEnabled {
            completion(true)
            return
        }
        fetch(url: positionURL) { json in
            completion(json?["latitude"] != nil)
        }
    }

    /// Vitesse seule, depuis `position` (en m/s).
    func fetchSpeed(completion: @escaping (Int?) -> Void) {
        let url = MockTrainData.shared.isEnabled
            ? MockTrainData.shared.url(path: "/api/jsonp/position/")
            : positionURL
        guard let url else {
            completion(nil)
            return
        }
        APIBody.fetch(url: url, timeout: speedTimeout, ignoreCache: true) { position in
            completion(EurostarAPIClient.num(position?["speed"]).map { Int(($0 * 3.6).rounded()) })
        }
    }

    /// `nil` si aucune position n'a pu être lue : API absente ou hors du train.
    func fetchAll(completion: @escaping (EurostarSnapshot?) -> Void) {
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.fetchAllEurostar { system, connectivity, users, user, position in
                completion(EurostarAPIClient.makeSnapshot(position: position,
                                                          user: user,
                                                          users: users,
                                                          connectivity: connectivity,
                                                          system: system))
            }
            return
        }

        let group = DispatchGroup()

        var position: [String: Any]?
        var user: [String: Any]?
        var users: [String: Any]?
        var connectivity: [String: Any]?
        var system: [String: Any]?

        let endpoints: [(URL, ([String: Any]?) -> Void)] = [
            (positionURL,     { position = $0 }),
            (userURL,         { user = $0 }),
            (usersURL,        { users = $0 }),
            (connectivityURL, { connectivity = $0 }),
            (systemURL,       { system = $0 })
        ]

        for (url, setter) in endpoints {
            group.enter()
            fetch(url: url) { setter($0); group.leave() }
        }

        group.notify(queue: .main) {
            completion(EurostarAPIClient.makeSnapshot(position: position,
                                                      user: user,
                                                      users: users,
                                                      connectivity: connectivity,
                                                      system: system))
        }
    }

    /// Transformation pure des 5 payloads, testable sans réseau.
    static func makeSnapshot(position: [String: Any]?,
                             user: [String: Any]?,
                             users: [String: Any]?,
                             connectivity: [String: Any]?,
                             system: [String: Any]?) -> EurostarSnapshot? {
        var snap = EurostarSnapshot()

        if let p = position {
            snap.raw["position"] = p
            snap.latitude   = num(p["latitude"])
            snap.longitude  = num(p["longitude"])
            snap.altitudeM  = num(p["altitude"])
            snap.headingDeg = num(p["cmg"])
            snap.satellites = num(p["satellites"]).map { Int($0) }
            // `speed` est en m/s (comme l'API SNCF), pas en km/h.
            if let speed = num(p["speed"]) { snap.speedKmh = Int((speed * 3.6).rounded()) }
        }

        guard snap.hasPosition else { return nil }

        if let u = user {
            snap.raw["user"] = u
            // Les compteurs sont en octets, et les limites sont des chaînes vides si illimité.
            if let used = num(u["data_total_used"]) { snap.dataUsedMB = used / 1_000_000.0 }
            if let limit = num(u["data_total_limit"]), limit > 0 { snap.dataLimitMB = limit / 1_000_000.0 }
            // `bandwidth_download_limit` est en octets/s : 12 500 000 → 100 Mbit/s.
            if let bytesPerSecond = num(u["bandwidth_download_limit"]), bytesPerSecond > 0 {
                snap.bandwidthDownMbps = bytesPerSecond * 8 / 1_000_000.0
            }
            if let seconds = num(u["timeleft"]), seconds > 0 {
                snap.sessionSecondsLeft = Int(seconds)
            }
        }

        if let us = users {
            snap.raw["users"] = us
            snap.devicesOnline = num(us["online"]).map { Int($0) }
            snap.devicesTotal  = num(us["total"]).map { Int($0) }
        }

        if let c = connectivity {
            snap.raw["connectivity"] = c
            snap.isOnline = num(c["online"]).map { $0 != 0 }
            let links = (c["links"] as? [[String: Any]]) ?? []
            snap.uplinkLinksTotal = links.count
            let available = links.filter { ($0["link_state"] as? String) == "available" }
            snap.uplinkLinksUp = available.count
            // On prend le meilleur lien disponible : c'est lui qui porte le trafic.
            let candidates = available.isEmpty ? links : available
            let best = candidates
                .compactMap { link -> (Int, String?)? in
                    guard let rssi = num(link["rssi"]) else { return nil }
                    return (Int(rssi), link["technology"] as? String)
                }
                .max(by: { $0.0 < $1.0 })
            snap.uplinkRSSI = best?.0
            snap.uplinkTechnology = best?.1
                ?? candidates.compactMap { $0["technology"] as? String }.first

            // `operator_id` est un PLMN (MCC+MNC) : « 20801 » → Orange France.
            var linksPerOperator: [String: Int] = [:]
            for link in candidates {
                guard let plmn = (link["operator_id"] as? String)
                        ?? (link["operator_id"] as? NSNumber).map({ $0.stringValue }),
                      !plmn.isEmpty, plmn != "-1"
                else { continue }
                let name = operatorName(plmn: plmn)
                linksPerOperator[name, default: 0] += 1
            }
            snap.operators = linksPerOperator
                .map { UplinkOperator(name: $0.key, links: $0.value) }
                // Le plus de liens d'abord, puis alphabétique pour un affichage stable.
                .sorted { $0.links == $1.links ? $0.name < $1.name : $0.links > $1.links }
        }

        if let s = system {
            snap.raw["system"] = s
            let name = (s["system_name"] as? String) ?? (s["system"] as? String)
            snap.systemName = name
            snap.rameNumber = name?
                .split(separator: "-")
                .first { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                .map(String.init)
        }

        return snap
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        APIBody.fetch(url: url, timeout: timeout, completion: completion)
    }

    /// Réseaux traversés (FR, BE, NL, DE, UK). Un PLMN absent est affiché « MCC-MNC ».
    private static let operatorNames: [String: String] = [
        // France (208)
        "20801": "Orange", "20802": "Orange",
        "20810": "SFR", "20811": "SFR", "20813": "SFR",
        "20815": "Free", "20816": "Free",
        "20820": "Bouygues", "20821": "Bouygues",
        // Belgique (206)
        "20601": "Proximus", "20605": "Telenet", "20610": "Orange BE", "20620": "BASE",
        // Pays-Bas (204)
        "20404": "Vodafone NL", "20408": "KPN", "20412": "KPN",
        "20416": "Odido", "20420": "Odido",
        // Allemagne (262)
        "26201": "Telekom", "26202": "Vodafone DE", "26209": "Vodafone DE",
        "26203": "O2 DE", "26207": "O2 DE",
        // Royaume-Uni (234/235)
        "23410": "O2 UK", "23502": "O2 UK", "23415": "Vodafone UK",
        "23420": "Three", "23430": "EE", "23433": "EE"
    ]

    /// PLMN → nom commercial.
    static func operatorName(plmn: String) -> String {
        if let name = operatorNames[plmn] { return name }
        guard plmn.count > 3 else { return plmn }
        return "\(plmn.prefix(3))-\(plmn.dropFirst(3))"
    }

    private static func num(_ value: Any?) -> Double? {
        APIValue.double(value)
    }
}
