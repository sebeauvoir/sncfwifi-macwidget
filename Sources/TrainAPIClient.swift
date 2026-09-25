import CoreLocation
import Foundation

/// Appelle les endpoints de l'API WiFi SNCF en parallèle.
final class TrainAPIClient {
    private let gpsURL        = URL(string: "https://wifi.sncf/router/api/train/gps")!
    // L'endpoint s'appelle `progress` (ou `details`) selon les rames, on laisse les deux pour être sûr mais on priorisera progress.
    private let progressURL   = URL(string: "https://wifi.sncf/router/api/train/progress")!
    private let detailsURL    = URL(string: "https://wifi.sncf/router/api/train/details")!
    private let barURL        = URL(string: "https://wifi.sncf/router/api/bar/attendance")!
    private let statsURL      = URL(string: "https://wifi.sncf/router/api/connection/statistics")!
    private let statusURL     = URL(string: "https://wifi.sncf/router/api/connection/status")!
    /// Tracé des voies du trajet, en GeoJSON `LineString` (origine → terminus), ~40 Ko.
    private let graphURL      = URL(string: "https://wifi.sncf/router/api/train/graph")!
    /// Part de CO₂ évitée par rapport à la voiture, par couple origine → destination (codes UIC).
    private let co2URL        = URL(string: "https://wifi.sncf/co2/meta.json")!

    /// Table CO₂ du portail, chargée une fois : elle ne dépend pas du moment.
    private(set) var co2Table: [[String: Any]]?
    /// Dernière réponse de `details` : elle seule porte la rame (`trainId`) et les codes UIC
    /// du trajet, que `progress` n'a pas.
    private(set) var lastDetails: [String: Any]?
    
    private let timeout: TimeInterval = 5
    /// Relue chaque seconde : une réponse plus lente ne sert plus à rien.
    private let speedTimeout: TimeInterval = 2

    /// Sonde légère : un seul appel, pour savoir si on est sur le réseau d'un train SNCF.
    /// Utilisée quand le SSID est illisible et qu'il faut choisir entre les fournisseurs.
    func probe(completion: @escaping (Bool) -> Void) {
        if MockTrainData.shared.isEnabled {
            completion(true)
            return
        }
        fetch(url: gpsURL) { completion($0 != nil) }
    }

    /// Vitesse (en m/s) et position, depuis `train/gps`.
    func fetchLive(completion: @escaping (LiveFix?) -> Void) {
        let url = MockTrainData.shared.isEnabled
            ? MockTrainData.shared.url(path: "/router/api/train/gps")
            : gpsURL
        guard let url else {
            completion(nil)
            return
        }
        APIBody.fetch(url: url, timeout: speedTimeout, ignoreCache: true) { gps in
            guard let speed = APIValue.double(gps?["speed"]) else {
                completion(nil)
                return
            }
            let coordinate = LiveFix.coordinate(
                latitude: APIValue.double(gps?["latitude"]) ?? APIValue.double(gps?["lat"]),
                longitude: APIValue.double(gps?["longitude"]) ?? APIValue.double(gps?["lon"]) ?? APIValue.double(gps?["lng"])
            )
            completion(LiveFix(speedKmh: Int(speed * 3.6), coordinate: coordinate))
        }
    }

    /// Tracé des voies, chargé une fois par trajet pour la carte.
    func fetchRoutePath(completion: @escaping ([CLLocationCoordinate2D]?) -> Void) {
        let url = MockTrainData.shared.isEnabled
            ? MockTrainData.shared.url(path: "/router/api/train/graph")
            : graphURL
        guard let url else {
            completion(nil)
            return
        }
        APIBody.fetch(url: url, timeout: 15) { json in
            let path = GeoJSONPath.coordinates(from: json)
            completion(path.count > 1 ? path : nil)
        }
    }

    /// Récupère toutes les infos en parallèle, notifie sur le main thread.
    func fetchAll(completion: @escaping (
        _ gps: [String: Any]?,
        _ details: [String: Any]?, // Retourne `progress` ou `details`
        _ bar: [String: Any]?,
        _ stats: [String: Any]?,
        _ status: [String: Any]?
    ) -> Void) {
        if MockTrainData.shared.isEnabled {
            // En mode démo, lire les données depuis le serveur local configurable.
            MockTrainData.shared.fetchAll(completion: completion)
            return
        }
        
        let group = DispatchGroup()
        
        var gpsData: [String: Any]?
        var progressData: [String: Any]?
        var detailsData: [String: Any]?
        var barData: [String: Any]?
        var statsData: [String: Any]?
        var statusData: [String: Any]?

        group.enter()
        fetch(url: gpsURL) { gpsData = $0; group.leave() }

        group.enter()
        fetch(url: progressURL) { progressData = $0; group.leave() }
        
        group.enter()
        fetch(url: detailsURL) { detailsData = $0; group.leave() }

        group.enter()
        fetch(url: barURL) { barData = $0; group.leave() }

        group.enter()
        fetch(url: statsURL) { statsData = $0; group.leave() }

        group.enter()
        fetch(url: statusURL) { statusData = $0; group.leave() }

        var co2Data: [[String: Any]]?
        if co2Table == nil {
            group.enter()
            APIBody.fetchArray(url: co2URL, timeout: timeout) { co2Data = $0; group.leave() }
        }

        group.notify(queue: .main) {
            if let co2Data { self.co2Table = co2Data }
            if let detailsData { self.lastDetails = detailsData }
            completion(gpsData, progressData ?? detailsData, barData, statsData, statusData)
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        APIBody.fetch(url: url, timeout: timeout, completion: completion)
    }
}
