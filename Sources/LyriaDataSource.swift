import CoreLocation
import Foundation

/// TGV Lyria (`wifi.tgv-lyria.com`) : le portail Moment/21Net des rames franco-suisses, sans
/// rapport avec l'API `wifi.sncf` des TGV INOUI. Il donne la desserte complète — horaires
/// théoriques et réels, coordonnées des gares — mais aucun quota de données.
final class LyriaDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "lyria",
        displayName: "TGV Lyria",
        // Relevé à bord. C'est le SSID que déclarait `SNCFDataSource`, d'où le mauvais routage
        // qu'on y a corrigé : il mène à ce portail-ci, pas à `wifi.sncf`.
        ssids: ["_wifi_lyria"],
        // Échantillonné sur le logo servi par le portail (`/assets/images/tgvlyria-logo.png`).
        accentHex: 0xE01028,
        features: [.journey, .speed, .position, .wifiQuality],
        apiHost: "wifi.tgv-lyria.com",
        // Mesuré à bord : `wifi.tgv-lyria.com` résout vers 10.22.0.2, le routeur de la rame.
        requiresPrivateAPIHost: true
    )

    private let client = LyriaAPIClient()

    func probe(completion: @escaping (Bool) -> Void) {
        client.probe(completion: completion)
    }

    func fetchLive(completion: @escaping (LiveFix?) -> Void) {
        client.fetchLive(completion: completion)
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        client.fetchAll { [weak self] snapshot in
            guard let self, let snapshot else {
                completion(nil)
                return
            }
            completion(self.makeSnapshot(snapshot))
        }
    }

    func makeSnapshot(_ snap: LyriaSnapshot) -> TrainSnapshot {
        let stoppedIndex = stoppedStationIndex(snap)
        let route = routePosition(snap)
        let nextStopIndex = stoppedIndex ?? route?.nextStopIndex ?? snap.nextStopIndex
        let progress = route?.progress ?? snap.progress

        let stops = snap.stops.enumerated().map { index, stop -> StopRow in
            let status: StopStatus = index < nextStopIndex
                ? .passed
                : (index == nextStopIndex ? .current : .upcoming)
            return StopRow(
                id: stop.uic,
                label: stop.name,
                theoricTime: stop.scheduled.map(APIValue.time) ?? "",
                realTime: stop.arrival.map(APIValue.time) ?? "",
                arrivalDate: stop.arrival,
                delayMin: stop.delayMin,
                status: status,
                coordinate: LiveFix.coordinate(latitude: stop.latitude, longitude: stop.longitude)
            )
        }

        // Gare d'arrivée cible : celle choisie dans le panneau si elle est encore devant.
        var arrivalIndex = max(0, stops.count - 1)
        if let savedId = UserDefaults.standard.string(forKey: "arrivalStationId"),
           let index = stops.firstIndex(where: { $0.id == savedId || $0.label == savedId }),
           index >= nextStopIndex {
            arrivalIndex = index
        }

        let arrivalStop = stops.indices.contains(arrivalIndex) ? stops[arrivalIndex] : nil
        let destination = arrivalStop?.label ?? ""
        let delayMin = max(0, arrivalStop?.delayMin ?? 0)

        var state = TrainViewState(
            provider: descriptor,
            trainNumber: snap.trainNumber,
            headerSubtitle: destination.isEmpty ? nil : "→ \(destination)",
            // L'API ne publie aucun motif de retard ; `eventInformations` est resté vide à bord.
            delayCause: "",
            stops: stops,
            globalProgress: progress,
            speedKmh: snap.speedKmh,
            wifiQuality: snap.wifiQuality,
            wifiDevices: snap.connectedDevices,
            arrivalOptions: stops.map { ArrivalOption(id: $0.id, label: $0.label) }
        )
        state.delayMin = delayMin
        state.selectedArrivalId = arrivalStop?.id
        state.metrics = metrics(for: snap)
        state.trainCoordinate = LiveFix.coordinate(latitude: snap.latitude, longitude: snap.longitude)

        let badge = StatusBadge(
            text: LyriaDataSource.shortStationName(destination),
            destination: LyriaDataSource.shortStationName(destination),
            arrivalDate: arrivalStop?.arrivalDate,
            stoppedStation: stoppedIndex
                .flatMap { stops.indices.contains($0) ? stops[$0].label : nil }
                .map(LyriaDataSource.shortStationName),
            progress: snap.hasTrip ? progress : nil,
            delayMin: delayMin
        )

        let journey = snap.hasTrip
            ? JourneyContext(nextStopIndex: nextStopIndex,
                             selectedArrivalIndex: arrivalIndex,
                             isStoppedAtStation: stoppedIndex != nil)
            : nil

        return TrainSnapshot(viewState: state, badge: badge, rawPayloads: snap.raw, journey: journey)
    }

    // MARK: - Position

    /// Segment réellement parcouru, déduit de la position. Indispensable ici : l'API ne
    /// réactualise pas ses horaires, si bien qu'un train en avance resterait annoncé à l'arrêt
    /// qu'il vient de quitter — 39 min durant sur le trajet mesuré. La ligne brisée reliant les
    /// gares suffit à départager les segments, qui font des dizaines de kilomètres.
    private func routePosition(_ snap: LyriaSnapshot) -> (nextStopIndex: Int, progress: Double)? {
        guard let latitude = snap.latitude, let longitude = snap.longitude else { return nil }
        let points = snap.stops.map { stop -> CLLocation? in
            guard let lat = stop.latitude, let lon = stop.longitude else { return nil }
            return CLLocation(latitude: lat, longitude: lon)
        }
        guard points.count > 1, !points.contains(where: { $0 == nil }) else { return nil }
        let gares = points.compactMap { $0 }

        let lengths = (0..<gares.count - 1).map { gares[$0].distance(from: gares[$0 + 1]) }
        guard lengths.reduce(0, +) > 0 else { return nil }

        // La jauge pèse les segments par leur durée théorique, qui épouse le tracé réel des voies,
        // là où la ligne brisée entre gares ignore les détours — la LGV passe par Dijon, ce qui
        // suffit à gonfler la progression de près de dix points à mi-parcours.
        let durations = (0..<gares.count - 1).map { index -> Double? in
            guard let from = snap.stops[index].departure,
                  let to = snap.stops[index + 1].arrival,
                  to > from else { return nil }
            return to.timeIntervalSince(from)
        }
        let weights = durations.allSatisfy { $0 != nil } ? durations.compactMap { $0 } : lengths
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }

        var best: (segment: Int, ratio: Double, offset: Double)?
        for index in 0..<gares.count - 1 where lengths[index] > 0 {
            let ratio = projection(latitude: latitude, longitude: longitude,
                                   from: gares[index], to: gares[index + 1])
            let onSegment = interpolate(from: gares[index], to: gares[index + 1], ratio: ratio)
            let offset = onSegment.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            if best == nil || offset < best!.offset { best = (index, ratio, offset) }
        }
        guard let best else { return nil }

        let travelled = weights[0..<best.segment].reduce(0, +) + weights[best.segment] * best.ratio
        return (min(best.segment + 1, gares.count - 1), max(0, min(1, travelled / total)))
    }

    /// Position relative du point sur le segment, bornée à [0, 1]. Le plan local équirectangulaire
    /// suffit : on ne cherche pas une distance, seulement à situer le train entre deux gares.
    private func projection(latitude: Double, longitude: Double,
                            from start: CLLocation, to end: CLLocation) -> Double {
        let scale = cos(start.coordinate.latitude * .pi / 180)
        let ax = (end.coordinate.longitude - start.coordinate.longitude) * scale
        let ay = end.coordinate.latitude - start.coordinate.latitude
        let bx = (longitude - start.coordinate.longitude) * scale
        let by = latitude - start.coordinate.latitude
        let squared = ax * ax + ay * ay
        guard squared > 0 else { return 0 }
        return max(0, min(1, (ax * bx + ay * by) / squared))
    }

    private func interpolate(from start: CLLocation, to end: CLLocation, ratio: Double) -> CLLocation {
        CLLocation(
            latitude: start.coordinate.latitude
                + (end.coordinate.latitude - start.coordinate.latitude) * ratio,
            longitude: start.coordinate.longitude
                + (end.coordinate.longitude - start.coordinate.longitude) * ratio
        )
    }

    /// Index de la gare où le train est arrêté, `nil` s'il roule. L'API n'annonce pas l'arrêt :
    /// on le déduit comme côté SNCF, en croisant vitesse faible et proximité GPS.
    private func stoppedStationIndex(_ snap: LyriaSnapshot) -> Int? {
        guard snap.speedKmh < 36,
              let latitude = snap.latitude,
              let longitude = snap.longitude
        else { return nil }
        let here = CLLocation(latitude: latitude, longitude: longitude)

        return snap.stops.indices.first { index in
            guard let stopLat = snap.stops[index].latitude,
                  let stopLon = snap.stops[index].longitude
            else { return false }
            return here.distance(from: CLLocation(latitude: stopLat, longitude: stopLon)) < 1500
        }
    }

    // MARK: - Métriques

    private func metrics(for snap: LyriaSnapshot) -> [MetricRow] {
        var rows: [MetricRow] = []

        if let altitude = snap.altitudeM {
            rows.append(MetricRow(id: "altitude",
                                  symbol: "mountain.2",
                                  text: "\(Int(altitude.rounded())) m",
                                  span: .half))
        }
        if let devices = snap.connectedDevices {
            rows.append(MetricRow(id: "devices",
                                  symbol: "person.2",
                                  text: "\(devices) connectés",
                                  span: .half))
        }
        if let vehicle = snap.vehicleId {
            rows.append(.footnote("Rame \(vehicle)"))
        }
        return rows
    }

    /// Raccourcit un nom de gare pour la pastille, dont la largeur est plafonnée à 150 px : on ne
    /// garde que ce qui précède le premier tiret, puis on retire le suffixe de gare principale.
    /// « Paris - Gare de Lyon - Hall 1 & 2 » → « Paris », « Basel SBB » → « Basel ».
    static func shortStationName(_ name: String) -> String {
        var short = name
        if let dash = short.range(of: " - ") {
            short = String(short[short.startIndex..<dash.lowerBound])
        }
        for suffix in [" HB", " SBB", " CFF", " FFS", " Hbf"] where short.hasSuffix(suffix) {
            short = String(short.dropLast(suffix.count))
            break
        }
        short = short.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }
}
