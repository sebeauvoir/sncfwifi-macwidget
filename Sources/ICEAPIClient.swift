import Foundation

/// Instantané consolidé du portail ICE (`iceportal.de`, Deutsche Bahn).
struct ICESnapshot {

    struct Stop {
        let evaNr: String
        let name: String
        /// Heure d'arrivée réelle, ou prévue à défaut.
        let arrival: Date?
        let scheduledArrival: Date?
        let departure: Date?
        let arrivalDelayMin: Int
        let scheduledPlatform: String?
        let platform: String?
        let distanceFromStart: Int
        /// `passed`, `departed` ou `future`.
        let positionStatus: String

        var isBehind: Bool { positionStatus == "passed" || positionStatus == "departed" }
    }

    // status
    var speedKmh: Int = 0
    var latitude: Double?
    var longitude: Double?
    /// Numéro commercial (`vzn`), ex. « 557 ».
    var trainNumber: String?
    /// Immatriculation de la rame (`tzn`), ex. « ICE0167 ».
    var vehicleId: String?
    /// Série du matériel (`series`), ex. « 401 ».
    var series: String?
    var wagonClass: String?
    /// `HIGH`, `UNSTABLE`, `WEAK`…
    var internetState: String?
    /// État annoncé pour la suite du parcours — une prévision, pas l'état courant.
    var nextInternetState: String?
    var internetChangeSeconds: Int?

    // tripInfo/trip
    var stops: [Stop] = []
    var finalStationName: String?
    var nextStopEvaNr: String?
    var totalDistanceM: Int = 0
    /// Distance parcourue = dernier arrêt passé + distance depuis cet arrêt.
    var travelledM: Int = 0
    /// Départ réel du premier arrêt, pour la vitesse moyenne.
    var departureDate: Date?

    var raw: [String: Any] = [:]

    var hasTrip: Bool { !stops.isEmpty }

    var progress: Double {
        guard totalDistanceM > 0 else { return 0 }
        return max(0, min(1, Double(travelledM) / Double(totalDistanceM)))
    }

    var remainingM: Int { max(0, totalDistanceM - travelledM) }

    /// Vitesse moyenne depuis le départ. `nil` tant que le trajet est trop jeune pour que la
    /// valeur ait un sens.
    var averageSpeedKmh: Int? {
        guard let departureDate, travelledM > 1000 else { return nil }
        let hours = Date().timeIntervalSince(departureDate) / 3600
        guard hours > 0.05 else { return nil }
        return Int((Double(travelledM) / 1000 / hours).rounded())
    }

    /// Modèle commercial déduit de la série.
    var modelName: String? {
        guard let series else { return nil }
        return ICEAPIClient.modelNames[series]
    }

    /// Index du prochain arrêt dans `stops`.
    var nextStopIndex: Int {
        if let nextStopEvaNr, let index = stops.firstIndex(where: { $0.evaNr == nextStopEvaNr }) {
            return index
        }
        return stops.firstIndex { !$0.isBehind } ?? max(0, stops.count - 1)
    }

    /// Vrai quand le train est à l'arrêt dans la gare qu'il vient d'atteindre.
    var isStoppedAtStation: Bool {
        guard speedKmh < 3, stops.indices.contains(nextStopIndex) else { return false }
        return stops[nextStopIndex].positionStatus == "passed"
    }
}

/// Interroge le portail embarqué des ICE. Deux endpoints pour l'état du trajet, deux autres
/// pour la carte du bar-restaurant (chargée séparément, à la demande).
final class ICEAPIClient {

    private static let base = "https://iceportal.de"

    private let statusURL    = URL(string: "\(base)/api1/rs/status")!
    private let tripURL      = URL(string: "\(base)/api1/rs/tripInfo/trip")!
    private let productsURL  = URL(string: "\(base)/bap/api/products")!
    private let bapStatusURL = URL(string: "\(base)/bap/api/bap-service-status")!

    private let timeout: TimeInterval = 5
    /// Relue chaque seconde : une réponse plus lente ne sert plus à rien.
    private let speedTimeout: TimeInterval = 2
    /// La carte pèse ~90 Ko : elle mérite plus de marge que les appels d'état.
    private let menuTimeout: TimeInterval = 12

    func probe(completion: @escaping (Bool) -> Void) {
        APIBody.fetch(url: statusURL, timeout: timeout) { json in
            completion(json?["trainType"] != nil || json?["speed"] != nil)
        }
    }

    /// Vitesse seule, depuis `status` (déjà en km/h).
    func fetchSpeed(completion: @escaping (Int?) -> Void) {
        APIBody.fetch(url: statusURL, timeout: speedTimeout, ignoreCache: true) { status in
            completion(APIValue.double(status?["speed"]).map { Int($0.rounded()) })
        }
    }

    /// `nil` si le portail est injoignable.
    func fetchAll(completion: @escaping (ICESnapshot?) -> Void) {
        let group = DispatchGroup()
        var status: [String: Any]?
        var trip: [String: Any]?

        group.enter()
        APIBody.fetch(url: statusURL, timeout: timeout) { status = $0; group.leave() }

        group.enter()
        APIBody.fetch(url: tripURL, timeout: timeout) { trip = $0; group.leave() }

        group.notify(queue: .main) {
            completion(ICEAPIClient.makeSnapshot(status: status, trip: trip))
        }
    }

    /// Les produits ne sont servis que si le service de commande est actif.
    func fetchProducts(completion: @escaping ([[String: Any]]?) -> Void) {
        APIBody.fetch(url: bapStatusURL, timeout: timeout) { [weak self] status in
            guard let self else {
                completion(nil)
                return
            }
            guard (status?["bapServiceStatus"] as? String) == "ACTIVE" else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            APIBody.fetchArray(url: self.productsURL, timeout: self.menuTimeout) { products in
                DispatchQueue.main.async { completion(products) }
            }
        }
    }

    // MARK: - Agrégation

    /// Transformation pure des deux payloads, testable sans réseau.
    static func makeSnapshot(status: [String: Any]?, trip: [String: Any]?) -> ICESnapshot? {
        var snap = ICESnapshot()

        if let status {
            snap.raw["status"] = status
            // Contrairement aux API SNCF et Icomera, `speed` est déjà en km/h.
            snap.speedKmh = Int((APIValue.double(status["speed"]) ?? 0).rounded())
            snap.latitude = APIValue.double(status["latitude"])
            snap.longitude = APIValue.double(status["longitude"])
            snap.vehicleId = (status["tzn"] as? String)?.nonEmpty
            snap.series = (status["series"] as? String)?.nonEmpty
            snap.wagonClass = (status["wagonClass"] as? String)?.nonEmpty
            if let vzn = status["vzn"] {
                snap.trainNumber = (vzn as? String)?.nonEmpty ?? APIValue.double(vzn).map { String(Int($0)) }
            }
            snap.internetState = (status["internet"] as? String)?.nonEmpty
            if let connectivity = status["connectivity"] as? [String: Any] {
                snap.internetState = (connectivity["currentState"] as? String)?.nonEmpty ?? snap.internetState
                snap.nextInternetState = (connectivity["nextState"] as? String)?.nonEmpty
                snap.internetChangeSeconds = APIValue.double(connectivity["remainingTimeSeconds"]).map { Int($0) }
            }
        }

        if let tripRoot = trip?["trip"] as? [String: Any] {
            snap.raw["trip"] = tripRoot
            snap.totalDistanceM = APIValue.int(tripRoot["totalDistance"])
            // `actualPosition` est la distance du dernier arrêt passé, pas la position réelle.
            snap.travelledM = APIValue.int(tripRoot["actualPosition"]) + APIValue.int(tripRoot["distanceFromLastStop"])

            if let stopInfo = tripRoot["stopInfo"] as? [String: Any] {
                snap.finalStationName = (stopInfo["finalStationName"] as? String)?.nonEmpty
                snap.nextStopEvaNr = ((stopInfo["actualNext"] as? String) ?? (stopInfo["scheduledNext"] as? String))?.nonEmpty
            }

            snap.stops = ((tripRoot["stops"] as? [[String: Any]]) ?? []).compactMap(makeStop)
            snap.departureDate = snap.stops.first?.departure
        }

        guard snap.hasTrip || snap.speedKmh > 0 || snap.latitude != nil else { return nil }
        return snap
    }

    private static func makeStop(_ raw: [String: Any]) -> ICESnapshot.Stop? {
        guard let station = raw["station"] as? [String: Any],
              let name = (station["name"] as? String)?.nonEmpty
        else { return nil }

        let timetable = raw["timetable"] as? [String: Any] ?? [:]
        let track = raw["track"] as? [String: Any] ?? [:]
        let info = raw["info"] as? [String: Any] ?? [:]

        let scheduledDeparture = epochDate(timetable["scheduledDepartureTime"])
        let actualDeparture = epochDate(timetable["actualDepartureTime"])
        // La gare d'origine n'a pas d'heure d'arrivée : on retombe sur le départ, sinon la
        // première ligne de la timeline s'affiche sans horaire.
        let scheduledArrival = epochDate(timetable["scheduledArrivalTime"]) ?? scheduledDeparture
        let actualArrival = epochDate(timetable["actualArrivalTime"]) ?? actualDeparture

        return ICESnapshot.Stop(
            evaNr: (station["evaNr"] as? String) ?? name,
            name: name,
            arrival: actualArrival ?? scheduledArrival,
            scheduledArrival: scheduledArrival,
            departure: actualDeparture ?? scheduledDeparture,
            arrivalDelayMin: delayMinutes(timetable["arrivalDelay"]) ?? delayMinutes(timetable["departureDelay"]) ?? 0,
            scheduledPlatform: (track["scheduled"] as? String)?.nonEmpty,
            platform: ((track["actual"] as? String) ?? (track["scheduled"] as? String))?.nonEmpty,
            distanceFromStart: APIValue.int(info["distanceFromStart"]),
            positionStatus: (info["positionStatus"] as? String) ?? "future"
        )
    }

    /// Les retards sont des chaînes : « +8 », « » quand il n'y en a pas.
    static func delayMinutes(_ value: Any?) -> Int? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return APIValue.double(value).map { Int($0) }
        }
        return Int(text.replacingOccurrences(of: "+", with: ""))
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let milliseconds = APIValue.double(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Série du matériel → modèle commercial.
    static let modelNames: [String: String] = [
        "401": "ICE 1",
        "402": "ICE 2",
        "403": "ICE 3",
        "406": "ICE 3M",
        "407": "ICE 3 Velaro",
        "408": "ICE 3neo",
        "411": "ICE T",
        "412": "ICE 4",
        "415": "ICE T",
        "605": "ICE TD"
    ]
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
