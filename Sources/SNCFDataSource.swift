import CoreLocation
import Foundation

/// WiFi SNCF (`wifi.sncf`) : TGV INOUI et Intercités. Les TGV Lyria ont leur propre portail
/// (voir `LyriaDataSource`) et ne passent pas par cette API.
final class SNCFDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "sncf",
        displayName: "TGV INOUI",
        // `_wifi_lyria` a été retiré : relevé à bord d'un Lyria, ce SSID est celui du portail
        // `wifi.tgv-lyria.com` et routait donc droit sur `wifi.sncf`, absente de ces rames.
        ssids: ["_sncf_wifi_inoui", "ouifi", "sncf_wifi_intercites", "wifi_sncf"],
        accentHex: 0x7D206F,
        features: [.journey, .speed, .wifiQuality, .dataQuota],
        apiHost: "wifi.sncf",
        // Relevé dans la page wifi.sncf/fr/journey : style MapLibre et tuiles PMTiles
        // (`maps/europe.pmtiles`, `maps/osm_railways.pmtiles`) servis par le train.
        mapTilesOrigin: URL(string: "https://wifi.sncf/")
    )

    private let client = TrainAPIClient()

    func probe(completion: @escaping (Bool) -> Void) {
        client.probe(completion: completion)
    }

    func fetchLive(completion: @escaping (LiveFix?) -> Void) {
        client.fetchLive(completion: completion)
    }

    func fetchRoutePath(completion: @escaping ([CLLocationCoordinate2D]?) -> Void) {
        client.fetchRoutePath(completion: completion)
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        client.fetchAll { [weak self] gps, details, bar, stats, status in
            guard let self, gps != nil || details != nil else {
                completion(nil)
                return
            }
            completion(self.makeSnapshot(gps: gps, details: details, bar: bar, stats: stats, status: status))
        }
    }

    /// Identifiant d'un arrêt, le même pour la timeline, le sélecteur d'arrivée et la carte.
    /// L'API ne publie pas d'`id` mais un code gare (`FRVLA`) ; le libellé sert de dernier
    /// recours, suffixé de la position pour rester unique.
    static func stopId(_ stop: [String: Any], index: Int? = nil) -> String {
        if let id = stop["id"] as? String, !id.isEmpty { return id }
        if let code = stop["code"] as? String, !code.isEmpty { return code }
        let label = (stop["label"] as? String) ?? "Gare"
        return index.map { "\(label)-\($0)" } ?? label
    }

    func makeSnapshot(gps: [String: Any]?,
                      details: [String: Any]?,
                      bar: [String: Any]?,
                      stats: [String: Any]?,
                      status: [String: Any]?) -> TrainSnapshot {

        // L'API retourne la vitesse en m/s, on convertit en km/h
        let speedRaw = APIValue.double(gps?["speed"]) ?? 0.0
        let speed = Int(speedRaw * 3.6)

        var trainNumber:       String?
        var destinationLabel:  String?
        var nextStopLabel:     String?
        var nextStopIndex:     Int = 0
        var isStoppedAtStation: Bool = false
        var allStops:          [[String: Any]] = []
        var trainDelayMins:    Int = 0
        var trainDelayCause:   String = ""

        let currentLat = APIValue.double(gps?["latitude"]) ?? APIValue.double(gps?["lat"])
        let currentLon = APIValue.double(gps?["longitude"]) ?? APIValue.double(gps?["lon"]) ?? APIValue.double(gps?["lng"])

        let distanceToStop: ([String: Any]) -> Double = { stop in
            guard let lat = currentLat, let lon = currentLon,
                  let coords = stop["coordinates"] as? [String: Any],
                  let sLat = APIValue.double(coords["latitude"]),
                  let sLon = APIValue.double(coords["longitude"]) else {
                return 999999.0
            }
            return CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: sLat, longitude: sLon))
        }

        if let det = details {
            // "number" = numéro commercial du train (ex: 6201), "trainId" = numéro de rame matériel
            if let s = det["number"] as? String, !s.isEmpty {
                trainNumber = s
            } else if let n = det["number"] as? Int {
                trainNumber = String(n)
            } else if let n = det["number"] as? Double {
                trainNumber = String(Int(n))
            }

            allStops = (det["stops"] as? [[String: Any]]) ?? []
            destinationLabel = allStops.last?["label"]  as? String

            // Retard global du train — la valeur est sur chaque arrêt, pas à la racine
            trainDelayMins = APIValue.int(det["delay"])
            if trainDelayMins == 0 { trainDelayMins = APIValue.int(allStops.last?["delay"]) }

            // Raison du retard : d'abord dans events[], puis sur les arrêts
            if let events = det["events"] as? [[String: Any]] {
                trainDelayCause = events.first(where: { ($0["type"] as? String) == "RETARD" })
                    .flatMap { $0["text"] as? String } ?? ""
            }
            if trainDelayCause.isEmpty {
                trainDelayCause = (det["delayReason"] as? String)
                    ?? allStops.first(where: { ($0["delayReason"] as? String)?.isEmpty == false })
                        .flatMap { $0["delayReason"] as? String }
                    ?? ""
            }

            // Trouver le segment en cours (le premier qui n'est pas à 100%)
            var currentSegmentIndex = 0
            for (i, stop) in allStops.enumerated() {
                let progressDict = stop["progress"] as? [String: Any]
                let pct = (progressDict?["progressPercentage"] as? Double) ?? 0.0
                if pct < 100.0 {
                    currentSegmentIndex = i
                    break
                }
                currentSegmentIndex = i
            }
            
            let depIndex = currentSegmentIndex
            let arrIndex = min(depIndex + 1, max(0, allStops.count - 1))
            
            let distToDep = allStops.indices.contains(depIndex) ? distanceToStop(allStops[depIndex]) : 999999.0
            let distToArr = allStops.indices.contains(arrIndex) ? distanceToStop(allStops[arrIndex]) : 999999.0
            
            // Logique de positionnement
            var isStopped = false
            var stoppedAt = arrIndex
            
            if speed < 36 {
                if distToDep < 1500 {
                    isStopped = true
                    stoppedAt = depIndex
                } else if distToArr < 1500 {
                    isStopped = true
                    stoppedAt = arrIndex
                } else if currentLat == nil {
                    // Fallback si pas de GPS coord : utilisation de l'API
                    let depStop = allStops[depIndex]
                    let pDict = depStop["progress"] as? [String: Any]
                    let pct = (pDict?["progressPercentage"] as? Double) ?? 0.0
                    let remDistAPI = (pDict?["remainingDistance"] as? Double) ?? 999999.0
                    let travDistAPI = (pDict?["traveledDistance"] as? Double) ?? 999999.0
                    
                    if pct < 2.0 || travDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = depIndex
                    } else if pct > 98.0 || remDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = arrIndex
                    }
                }
            }
            
            isStoppedAtStation = isStopped
            // En mouvement, la "prochaine gare" est la gare d'arrivée du segment (arrIndex)
            nextStopIndex = isStopped ? stoppedAt : arrIndex

            if !allStops.isEmpty && allStops.indices.contains(nextStopIndex) {
                nextStopLabel = allStops[nextStopIndex]["label"] as? String
            }
        }

        var badge: StatusBadge
        var journey: JourneyContext?
        var globalProgress: Double = 0.0

        if !allStops.isEmpty {
            // Gare d'arrivée cible : celle choisie dans le panneau, si elle est encore devant.
            var arrivalStationIndex = allStops.count - 1
            if let savedId = UserDefaults.standard.string(forKey: "arrivalStationId"),
               let idx = allStops.firstIndex(where: { SNCFDataSource.stopId($0) == savedId || ($0["label"] as? String) == savedId }),
               idx >= nextStopIndex {
                arrivalStationIndex = idx
            }
            let arrivalStop = allStops[arrivalStationIndex]
            let destLabel = arrivalStop["label"] as? String ?? ""
            let arrivalDate = APIValue.date(arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String)

            // Progression basée sur le temps : départ → maintenant → arrivée cible.
            let firstStop = allStops[0]
            if let departure = APIValue.date(firstStop["realDate"] as? String ?? firstStop["theoricDate"] as? String),
               let arrival = arrivalDate, arrival > departure {
                let elapsed = Date().timeIntervalSince(departure)
                globalProgress = max(0.0, min(1.0, elapsed / arrival.timeIntervalSince(departure)))
            }

            let shortDest = shortStationName(destLabel)
            badge = StatusBadge(
                text: shortDest,
                destination: shortDest,
                arrivalDate: arrivalDate,
                stoppedStation: isStoppedAtStation ? nextStopLabel.map(shortStationName) : nil,
                progress: globalProgress,
                delayMin: trainDelayMins,
                delayCause: trainDelayCause
            )
            journey = JourneyContext(nextStopIndex: nextStopIndex,
                                     selectedArrivalIndex: arrivalStationIndex,
                                     isStoppedAtStation: isStoppedAtStation)
        } else {
            // Desserte absente de la réponse : on se rabat sur la vitesse et la prochaine gare.
            let fallback: String
            if let next = nextStopLabel {
                if isStoppedAtStation {
                    fallback = "En gare de \(shortStationName(next))"
                } else if speed > 0 {
                    fallback = "\(speed) km/h › \(shortStationName(next))"
                } else {
                    fallback = "› \(shortStationName(next))"
                }
            } else if speed > 0 {
                fallback = "\(speed) km/h"
            } else {
                fallback = descriptor.displayName
            }
            badge = StatusBadge(text: fallback,
                                progress: nil,
                                delayMin: trainDelayMins,
                                delayCause: trainDelayCause)
        }

        var viewState = TrainViewState(
            provider: descriptor,
            trainNumber: trainNumber,
            headerSubtitle: destinationLabel.flatMap { $0.isEmpty ? nil : "→ \($0)" },
            delayMin: trainDelayMins,
            delayCause: trainDelayCause,
            globalProgress: globalProgress,
            speedKmh: speed
        )

        // Desserte (timeline)
        viewState.stops = allStops.enumerated().map { (i, stop) -> StopRow in
            let lbl = (stop["label"] as? String) ?? "?"
            let delay = (stop["delay"] as? Int) ?? 0
            let status: StopStatus = i < nextStopIndex ? .passed : (i == nextStopIndex ? .current : .upcoming)
            return StopRow(
                id: SNCFDataSource.stopId(stop, index: i),
                label: lbl,
                theoricTime: APIValue.time(stop["theoricDate"] as? String) ?? "",
                realTime: APIValue.time(stop["realDate"] as? String) ?? "",
                arrivalDate: APIValue.date(stop["realDate"] as? String ?? stop["theoricDate"] as? String),
                delayMin: delay,
                status: status,
                coordinate: (stop["coordinates"] as? [String: Any]).flatMap {
                    LiveFix.coordinate(latitude: APIValue.double($0["latitude"]),
                                       longitude: APIValue.double($0["longitude"]))
                }
            )
        }
        viewState.trainCoordinate = LiveFix.coordinate(latitude: currentLat, longitude: currentLon)

        // Qualité WiFi
        if let stats = stats {
            viewState.wifiQuality = stats["quality"] as? Int
            viewState.wifiDevices = stats["devices"] as? Int
        }

        // Consommation data
        if let status = status {
            let remaining = APIValue.int(status["remaining_data"])
            let consumed = APIValue.int(status["consumed_data"])
            let total = remaining + consumed
            if total > 0 {
                viewState.dataConsumedMB = Double(consumed) / 1000.0
                viewState.dataTotalMB = Double(total) / 1000.0
                viewState.dataRemainingMB = Double(remaining) / 1000.0
                viewState.dataRatio = max(0.0, min(1.0, Double(consumed) / Double(total)))
            }
            if let nextResetMs = APIValue.double(status["next_reset"]) {
                let resetDate = Date(timeIntervalSince1970: nextResetMs / 1000.0)
                viewState.dataResetTime = APIValue.time(resetDate)
            }
        }

        // Sélecteur de gare d'arrivée
        viewState.arrivalOptions = allStops.enumerated().map { (i, stop) -> ArrivalOption in
            let lbl = (stop["label"] as? String) ?? "Gare \(i)"
            return ArrivalOption(id: SNCFDataSource.stopId(stop, index: i), label: lbl)
        }
        // Un réglage enregistré avant le passage au code gare porte le libellé : il reste reconnu.
        let savedId = UserDefaults.standard.string(forKey: "arrivalStationId")
        viewState.selectedArrivalId = savedId
            .flatMap { saved in viewState.arrivalOptions.first { $0.id == saved || $0.label == saved }?.id }
            ?? viewState.arrivalOptions.last?.id

        // Kilomètres restants jusqu'à la gare d'arrivée, tels que l'API les donne : chaque
        // arrêt porte la progression du tronçon qui le relie au suivant
        // (`progress.remainingDistance`, en mètres), on somme les tronçons jusqu'à l'arrivée.
        // Pour la prochaine gare, c'est le chiffre de « Suivi du trajet » sur le portail.
        if let arrivalIndex = journey?.selectedArrivalIndex, arrivalIndex > 0 {
            let segments = allStops[..<arrivalIndex].compactMap { stop in
                (stop["progress"] as? [String: Any]).flatMap { APIValue.double($0["remainingDistance"]) }
            }
            if segments.count == arrivalIndex {
                viewState.remainingKm = segments.reduce(0, +) / 1000
            }
        }

        viewState.extraMetrics = extraMetrics(gps: gps,
                                              stops: allStops,
                                              arrivalIndex: journey?.selectedArrivalIndex,
                                              speedKmh: speed,
                                              bar: bar,
                                              status: status)


        var payloads: [String: Any] = [:]
        if let gps { payloads["gps"] = gps }
        if let details { payloads["details"] = details }
        if let bar { payloads["bar"] = bar }
        if let stats { payloads["stats"] = stats }
        if let status { payloads["status"] = status }

        return TrainSnapshot(viewState: viewState, badge: badge, rawPayloads: payloads, journey: journey)
    }

    /// Noms de gares raccourcis pour tenir dans la pastille de la barre de menus.
    // MARK: - Données en vrac

    /// Tout ce que l'API donne en plus, en vrac en bas du panneau.
    private func extraMetrics(gps: [String: Any]?,
                              stops: [[String: Any]],
                              arrivalIndex: Int?,
                              speedKmh: Int,
                              bar: [String: Any]?,
                              status: [String: Any]?) -> [MetricRow] {
        var rows: [MetricRow] = []

        if let altitude = APIValue.double(gps?["altitude"]) {
            rows.append(MetricRow(id: "altitude", symbol: "mountain.2",
                                  text: "\(Int(altitude.rounded())) m d'altitude", span: .half))
        }
        // Le cap n'a pas de sens à l'arrêt : le GPS dérive.
        if let heading = APIValue.double(gps?["heading"]), speedKmh > 0 {
            rows.append(MetricRow(id: "heading", symbol: "location.north.fill",
                                  text: "Cap \(Compass.cardinal(heading)) (\(Int(heading.rounded()))°)", span: .half))
        }

        // Chaque arrêt porte la progression du tronçon qui le relie au suivant.
        let travelled = stops.dropLast().compactMap { stop in
            (stop["progress"] as? [String: Any]).flatMap { APIValue.double($0["traveledDistance"]) }
        }.reduce(0, +)
        if travelled > 0 {
            rows.append(MetricRow(id: "travelled", symbol: "point.topleft.down.curvedto.point.bottomright.up",
                                  text: "\(DistanceFormat.km(travelled / 1000)) km parcourus", span: .half))
        }
        if let first = stops.first,
           let departure = APIValue.date(first["realDate"] as? String ?? first["theoricDate"] as? String) {
            let elapsed = Date().timeIntervalSince(departure)
            // Trop tôt après le départ, la moyenne ne veut rien dire.
            if elapsed > 180, travelled > 1000 {
                rows.append(MetricRow(id: "average", symbol: "speedometer",
                                      text: "Moyenne \(Int((travelled / elapsed * 3.6).rounded())) km/h", span: .half))
            }
        }

        if let arrivalIndex, stops.indices.contains(arrivalIndex) {
            let arrival = stops[arrivalIndex]
            if let date = APIValue.date(arrival["realDate"] as? String ?? arrival["theoricDate"] as? String),
               date > Date() {
                let label = shortStationName((arrival["label"] as? String) ?? "")
                rows.append(MetricRow(id: "time-left", symbol: "clock",
                                      text: "\(label) dans \(Self.duration(date.timeIntervalSinceNow))", span: .half))
            }
        }

        // Unité non documentée : 100 000 relevé à bord, lu comme des kbit/s.
        if let bandwidth = APIValue.double(status?["granted_bandwidth"]), bandwidth > 0 {
            rows.append(MetricRow(id: "bandwidth", symbol: "arrow.down.circle",
                                  text: "Débit accordé \(Int((bandwidth / 1000).rounded())) Mbit/s", span: .half))
        }
        if let empty = bar?["isBarQueueEmpty"] as? Bool {
            rows.append(MetricRow(id: "bar", symbol: "cup.and.saucer.fill",
                                  text: empty ? "Bar : pas d'attente" : "Bar : file d'attente", span: .half))
        }

        if let co2 = co2Text() {
            rows.append(MetricRow(id: "co2", symbol: "leaf.fill", text: co2))
        }

        // Durées d'arrêt annoncées, gares intermédiaires seulement.
        let dwells = stops.dropFirst().dropLast().compactMap { stop -> String? in
            let minutes = APIValue.int(stop["duration"])
            guard minutes > 0, let label = stop["label"] as? String else { return nil }
            return "\(shortStationName(label)) \(minutes) min"
        }
        if !dwells.isEmpty {
            rows.append(MetricRow(id: "dwell", symbol: "stopwatch", text: "Arrêts : " + dwells.joined(separator: " · ")))
        }

        if let rame = client.lastDetails?["trainId"].map({ "\($0)" }), !rame.isEmpty {
            rows.append(.footnote("Rame \(rame)"))
        }
        return rows
    }

    /// « 97 % de CO₂ en moins qu'en voiture », d'après la table du portail et les codes UIC du
    /// trajet. Le portail cherche le couple dans les deux sens.
    private func co2Text() -> String? {
        guard let codes = client.lastDetails?["stationUicCodes"] as? [String: Any],
              let departure = codes["departure"] as? String,
              let arrival = codes["arrival"] as? String,
              let table = client.co2Table
        else { return nil }
        let entry = table.first { row in
            let origin = row["origine_uic"] as? String
            let destination = row["destination_uic"] as? String
            return (origin == departure && destination == arrival) || (origin == arrival && destination == departure)
        }
        guard let value = (entry?["co2"] as? String)?.replacingOccurrences(of: "%", with: ""),
              !value.isEmpty
        else { return nil }
        return "\(value) % de CO₂ en moins qu'en voiture"
    }

    /// « 1h02 », « 45 min ».
    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(max(1, minutes)) min" }
        let rest = minutes % 60
        return rest > 0 ? "\(minutes / 60)h\(String(format: "%02d", rest))" : "\(minutes / 60)h"
    }

    private func shortStationName(_ name: String) -> String {
        if let short = SNCFDataSource.shortNames[name] { return short }
        if name.count <= 15 { return name }
        // Nom long non répertorié : le premier mot est le plus souvent la ville
        // (« Milano Porta Garibaldi » → « Milano »).
        if let firstWord = name.split(separator: " ").first, firstWord.count >= 3 {
            return String(firstWord)
        }
        return String(name.prefix(14)) + "…"
    }

    private static let shortNames: [String: String] = [
        "Paris - Gare de Lyon - Hall 1 & 2":    "Paris Lyon",
        "Paris Montparnasse 1 Et 2":            "Montparnasse",
        "Paris Montparnasse":                   "Montparnasse",
        "Paris Gare du Nord":                   "Paris Nord",
        "Paris Saint-Lazare":                   "St-Lazare",
        "Paris Est":                            "Paris Est",
        "Marseille-Saint-Charles":              "Marseille",
        "Marseille Saint-Charles":              "Marseille",
        "Lyon Part-Dieu":                       "Lyon",
        "Lyon Perrache":                        "Lyon",
        "Bordeaux Saint-Jean":                  "Bordeaux",
        "Toulouse Matabiau":                    "Toulouse",
        "Lille Flandres":                       "Lille",
        "Montpellier Saint-Roch":               "Montpellier",
        "Nice Ville":                           "Nice",
        "Aix-en-Provence TGV":                  "Aix TGV",
        "Valence TGV Rhône-Alpes Sud":          "Valence TGV",
        "Aéroport Charles De Gaulle 2 Tgv":     "CDG TGV",
        "Charles De Gaulle 2 Tgv":              "CDG TGV",
        "Strasbourg Ville":                     "Strasbourg",
        "Marne-La-Vallée Chessy":               "Marne La Vallée"
    ]
}
