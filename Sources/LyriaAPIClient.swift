import CoreLocation
import Foundation

/// Instantané consolidé du portail TGV Lyria (`wifi.tgv-lyria.com`).
struct LyriaSnapshot {

    struct Stop {
        let uic: String
        let name: String
        let latitude: Double?
        let longitude: Double?
        let scheduledArrival: Date?
        let realArrival: Date?
        let scheduledDeparture: Date?
        let realDeparture: Date?

        /// L'origine n'a pas d'arrivée et le terminus pas de départ : on retombe sur l'autre
        /// horaire, sinon ces deux lignes de la timeline s'affichent sans heure.
        var arrival: Date? { realArrival ?? scheduledArrival ?? departure }
        var departure: Date? { realDeparture ?? scheduledDeparture }
        var scheduled: Date? { scheduledArrival ?? scheduledDeparture }

        /// Retard déduit de l'écart entre horaire réel et théorique. Le JSON porte aussi un champ
        /// `delay`, resté à 0 sur tout le trajet observé : son unité n'a pas pu être établie.
        var delayMin: Int {
            guard let real = realArrival ?? realDeparture,
                  let planned = scheduledArrival ?? scheduledDeparture else { return 0 }
            return Int((real.timeIntervalSince(planned) / 60).rounded())
        }
    }

    // travel
    /// Numéro commercial du train, ex. « 9211 ».
    var trainNumber: String?
    var stops: [Stop] = []

    // travel/position + train/gps/position
    var latitude: Double?
    var longitude: Double?
    var altitudeM: Double?
    /// Vitesse en m/s : vérifié à bord par le calcul Δposition/Δtemps (86,4 m/s mesurés pour
    /// 86,05 annoncés), et non supposé d'après l'ordre de grandeur.
    var speedMs: Double?

    // wifi/status
    var wifiQuality: Int?
    var connectedDevices: Int?

    // transport/current
    /// Numéro de rame, ex. « 4729 ».
    var vehicleId: String?

    var raw: [String: Any] = [:]

    var hasTrip: Bool { !stops.isEmpty }

    var speedKmh: Int { Int(((speedMs ?? 0) * 3.6).rounded()) }

    /// Index du prochain arrêt : le premier dont l'heure d'arrivée est encore devant.
    var nextStopIndex: Int {
        let now = Date()
        return stops.firstIndex { ($0.arrival ?? .distantPast) > now } ?? max(0, stops.count - 1)
    }

    /// Repli quand la position manque : progression estimée sur les seuls horaires. Le cas normal
    /// passe par `LyriaDataSource.routePosition`, qui suit le GPS — l'API ne réactualisant pas ses
    /// horaires, ceux-ci décrochent de la marche réelle du train.
    var progress: Double {
        guard let start = stops.first?.departure,
              let end = stops.last?.arrival,
              end > start else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, min(1, elapsed / end.timeIntervalSince(start)))
    }
}

/// Interroge le portail embarqué des TGV Lyria. Quatre endpoints, appelés en parallèle.
///
/// Ce Next.js sert sa page d'accueil en 200 pour **tout** chemin inconnu : un code HTTP ne prouve
/// rien, chaque réponse se valide sur son contenu. Le slash final est obligatoire, sinon 308.
final class LyriaAPIClient {

    private static let base = "https://wifi.tgv-lyria.com"

    private let travelURL   = URL(string: "\(base)/api/travel/")!
    private let positionURL = URL(string: "\(base)/api/travel/position/")!
    private let gpsURL      = URL(string: "\(base)/api/train/gps/position/")!
    private let wifiURL     = URL(string: "\(base)/api/wifi/status/")!
    private let vehicleURL  = URL(string: "\(base)/api/transport/current/")!
    private let pathURL     = URL(string: "\(base)/api/travel/path/")!
    /// Le tracé pèse ~55 Ko : il mérite plus de marge que les appels d'état.
    private let pathTimeout: TimeInterval = 15

    private let timeout: TimeInterval = 5
    /// Relue chaque seconde : une réponse plus lente ne sert plus à rien.
    private let speedTimeout: TimeInterval = 2

    /// La position est le seul endpoint à la fois léger et toujours servi, même hors trajet
    /// référencé.
    func probe(completion: @escaping (Bool) -> Void) {
        APIBody.fetch(url: gpsURL, timeout: timeout) { json in
            completion(LyriaAPIClient.looksLikePosition(json))
        }
    }

    /// Vitesse (en m/s) et position, depuis le GPS brut. Pas de repli sur `travel/position` :
    /// le cycle complet s'en charge toutes les 5 s.
    func fetchLive(completion: @escaping (LiveFix?) -> Void) {
        APIBody.fetch(url: gpsURL, timeout: speedTimeout, ignoreCache: true) { gps in
            guard LyriaAPIClient.looksLikePosition(gps),
                  let speed = APIValue.double(gps?["speed"])
            else {
                completion(nil)
                return
            }
            let coordinate = LiveFix.coordinate(latitude: APIValue.double(gps?["latitude"]),
                                                longitude: APIValue.double(gps?["longitude"]))
            completion(LiveFix(speedKmh: Int((speed * 3.6).rounded()), coordinate: coordinate))
        }
    }

    /// Tracé GeoJSON du parcours, chargé une fois par trajet pour la carte.
    func fetchRoutePath(completion: @escaping ([CLLocationCoordinate2D]?) -> Void) {
        APIBody.fetch(url: pathURL, timeout: pathTimeout) { json in
            let path = GeoJSONPath.coordinates(from: json)
            completion(path.count > 1 ? path : nil)
        }
    }

    /// `nil` si le portail est injoignable.
    func fetchAll(completion: @escaping (LyriaSnapshot?) -> Void) {
        let group = DispatchGroup()
        var travel: [String: Any]?
        var position: [String: Any]?
        var wifi: [String: Any]?
        var vehicle: String?

        group.enter()
        APIBody.fetch(url: travelURL, timeout: timeout) { travel = $0; group.leave() }

        group.enter()
        APIBody.fetch(url: gpsURL, timeout: timeout) { gps in
            // `travel/position` rend les mêmes coordonnées mais peut répondre « gps-fallback »,
            // une position rejouée : le GPS brut reste la référence.
            if LyriaAPIClient.looksLikePosition(gps) {
                position = gps
                group.leave()
            } else {
                APIBody.fetch(url: self.positionURL, timeout: self.timeout) {
                    position = $0
                    group.leave()
                }
            }
        }

        group.enter()
        APIBody.fetch(url: wifiURL, timeout: timeout) { wifi = $0; group.leave() }

        group.enter()
        LyriaAPIClient.fetchString(url: vehicleURL, timeout: timeout) { vehicle = $0; group.leave() }

        group.notify(queue: .main) {
            completion(LyriaAPIClient.makeSnapshot(travel: travel,
                                                   position: position,
                                                   wifi: wifi,
                                                   vehicle: vehicle))
        }
    }

    // MARK: - Agrégation

    /// Transformation pure des payloads, testable sans réseau.
    static func makeSnapshot(travel: [String: Any]?,
                             position: [String: Any]?,
                             wifi: [String: Any]?,
                             vehicle: String?) -> LyriaSnapshot? {
        var snap = LyriaSnapshot()

        if let travel, let stopOvers = travel["stopOvers"] as? [[String: Any]] {
            snap.raw["travel"] = travel
            snap.trainNumber = (travel["identification"] as? String)?.nonEmpty
            snap.stops = stopOvers
                .sorted { APIValue.int($0["order"]) < APIValue.int($1["order"]) }
                .compactMap(makeStop)
        }

        if looksLikePosition(position) {
            snap.raw["position"] = position!
            snap.latitude = APIValue.double(position?["latitude"])
            snap.longitude = APIValue.double(position?["longitude"])
            snap.altitudeM = APIValue.double(position?["altitude"])
            snap.speedMs = APIValue.double(position?["speed"])
        }

        if let wifi, let quality = APIValue.double(wifi["quality"]) {
            snap.raw["wifi"] = wifi
            snap.wifiQuality = max(0, min(5, Int(quality)))
            snap.connectedDevices = APIValue.double(wifi["nbConnectedDevices"]).map { Int($0) }
        }

        snap.vehicleId = vehicle?.nonEmpty

        guard snap.hasTrip || snap.latitude != nil else { return nil }
        return snap
    }

    private static func makeStop(_ raw: [String: Any]) -> LyriaSnapshot.Stop? {
        guard let node = raw["node"] as? [String: Any] else { return nil }

        // Les libellés sont localisés ; le portail sert le français, mais on retombe sur le
        // premier disponible plutôt que d'afficher une gare sans nom.
        let metadatas = (node["metadatas"] as? [[String: Any]]) ?? []
        let french = metadatas.first { ($0["locale"] as? String)?.hasPrefix("fr") == true }
        guard let name = ((french ?? metadatas.first)?["title"] as? String)?.nonEmpty else {
            return nil
        }

        let schedule = raw["schedule"] as? [String: Any] ?? [:]
        let point = node["point"] as? [String: Any] ?? [:]
        let arrivalZone = schedule["arrivalTimezone"] as? String
        let departureZone = schedule["departureTimezone"] as? String

        return LyriaSnapshot.Stop(
            uic: (node["identification"] as? String)?.nonEmpty ?? name,
            name: name,
            latitude: APIValue.double(point["latitude"]),
            longitude: APIValue.double(point["longitude"]),
            scheduledArrival: scheduleDate(schedule["initialArrivalDate"], zone: arrivalZone),
            realArrival: scheduleDate(schedule["realArrivalDate"], zone: arrivalZone),
            scheduledDeparture: scheduleDate(schedule["initialDepartureDate"], zone: departureZone),
            realDeparture: scheduleDate(schedule["realDepartureDate"], zone: departureZone)
        )
    }

    /// Les horaires sont suffixés `Z` mais portent l'heure **locale**, celle du fuseau annoncé à
    /// côté (`departureTimezone` / `arrivalTimezone`) — deux champs superflus si les dates étaient
    /// vraiment en UTC. Mesuré à bord : train à 31 km de Mulhouse à 07:59 UTC pour une arrivée
    /// annoncée « 10:58:00.000Z », soit deux heures de décalage sur toute la timeline.
    static func scheduleDate(_ value: Any?, zone: String?) -> Date? {
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return nil }
        if text.hasSuffix("Z") { text.removeLast() }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "Europe/Paris")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Le portail rendant sa page d'accueil pour tout chemin inconnu, une réponse ne vaut que si
    /// elle porte des coordonnées exploitables.
    private static func looksLikePosition(_ json: [String: Any]?) -> Bool {
        guard let json,
              let latitude = APIValue.double(json["latitude"]),
              let longitude = APIValue.double(json["longitude"])
        else { return false }
        return latitude != 0 || longitude != 0
    }

    /// `/api/transport/current/` répond une chaîne JSON nue (`"4729"`), que `APIBody` ne sait
    /// pas décoder puisqu'il attend un objet.
    private static func fetchString(url: URL,
                                    timeout: TimeInterval,
                                    completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("sncfwifi-macapp/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let value = try? JSONSerialization.jsonObject(with: data,
                                                               options: [.fragmentsAllowed]) as? String
            else {
                completion(nil)
                return
            }
            completion(value)
        }.resume()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
