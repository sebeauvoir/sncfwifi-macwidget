import Foundation

/// WIFIonICE : portail embarqué de la Deutsche Bahn (`iceportal.de`). Seul réseau à donner la
/// voie par arrêt et une prévision de qualité de connexion ; en revanche l'API n'expose ni la
/// cause du retard, ni de quota de données.
final class ICEDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "ice",
        displayName: "ICE",
        // Seul SSID retenu : `WIFI@DB` couvre aussi les gares et les trains régionaux, où cette
        // API n'existe pas. Un ICE au SSID inattendu sera de toute façon trouvé par la sonde.
        ssids: ["wifionice"],
        accentHex: 0xEC0016,
        features: [.journey, .speed, .position, .uplink, .onboardMenu],
        apiHost: "iceportal.de",
        requiresPrivateAPIHost: true
    )

    private let client = ICEAPIClient()

    func probe(completion: @escaping (Bool) -> Void) {
        client.probe(completion: completion)
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

    func fetchMenu(completion: @escaping (OnboardMenu?) -> Void) {
        client.fetchProducts { products in
            completion(products.flatMap(ICEDataSource.makeMenu))
        }
    }

    func makeSnapshot(_ snap: ICESnapshot) -> TrainSnapshot {
        let nextStopIndex = snap.nextStopIndex
        let stops = snap.stops.enumerated().map { index, stop -> StopRow in
            let status: StopStatus = index < nextStopIndex
                ? .passed
                : (index == nextStopIndex ? .current : .upcoming)
            return StopRow(
                id: stop.evaNr,
                label: stop.name,
                theoricTime: stop.scheduledArrival.map(APIValue.time) ?? "",
                realTime: stop.arrival.map(APIValue.time) ?? "",
                arrivalDate: stop.arrival,
                delayMin: stop.arrivalDelayMin,
                status: status,
                platform: stop.platform,
                scheduledPlatform: stop.scheduledPlatform
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
        let destination = arrivalStop?.label ?? snap.finalStationName ?? ""

        var state = TrainViewState(
            provider: descriptor,
            trainNumber: snap.trainNumber,
            headerSubtitle: destination.isEmpty ? nil : "→ \(destination)",
            delayMin: max(0, arrivalStop?.delayMin ?? 0),
            // L'API ICE ne donne aucun motif de retard.
            delayCause: "",
            stops: stops,
            globalProgress: snap.progress,
            speedKmh: snap.speedKmh,
            arrivalOptions: stops.map { ArrivalOption(id: $0.id, label: $0.label) }
        )
        state.selectedArrivalId = arrivalStop?.id
        state.metrics = metrics(for: snap)

        let badge = StatusBadge(
            text: ICEDataSource.shortStationName(destination),
            destination: ICEDataSource.shortStationName(destination),
            arrivalDate: arrivalStop?.arrivalDate,
            stoppedStation: snap.isStoppedAtStation
                ? stops.indices.contains(nextStopIndex) ? ICEDataSource.shortStationName(stops[nextStopIndex].label) : nil
                : nil,
            progress: snap.hasTrip ? snap.progress : nil,
            delayMin: max(0, arrivalStop?.delayMin ?? 0)
        )

        let journey = snap.hasTrip
            ? JourneyContext(nextStopIndex: nextStopIndex,
                             selectedArrivalIndex: arrivalIndex,
                             isStoppedAtStation: snap.isStoppedAtStation)
            : nil

        return TrainSnapshot(viewState: state, badge: badge, rawPayloads: snap.raw, journey: journey)
    }

    // MARK: - Métriques

    private func metrics(for snap: ICESnapshot) -> [MetricRow] {
        var rows: [MetricRow] = []

        if let connectivity = connectivityText(snap) {
            rows.append(MetricRow(id: "connectivity",
                                  symbol: "antenna.radiowaves.left.and.right",
                                  text: connectivity))
        }
        if snap.totalDistanceM > 0 {
            rows.append(MetricRow(id: "remaining",
                                  symbol: "arrow.right.to.line",
                                  text: "Reste \(snap.remainingM / 1000) km",
                                  span: .half))
        }
        if let average = snap.averageSpeedKmh {
            rows.append(MetricRow(id: "average",
                                  symbol: "speedometer",
                                  text: "Moyenne \(average) km/h",
                                  span: .half))
        }
        if let identity = vehicleText(snap) {
            rows.append(.footnote(identity))
        }
        return rows
    }

    /// « Internet fort · signal faible prévu dans 10 min ». `nextState` est une prévision pour la
    /// suite du parcours : le libellé doit le dire, sinon on croit lire l'état courant.
    private func connectivityText(_ snap: ICESnapshot) -> String? {
        guard let current = snap.internetState else { return nil }
        var text = "Internet \(ICEDataSource.connectivityLabel(current))"

        if let next = snap.nextInternetState,
           next != current,
           let seconds = snap.internetChangeSeconds, seconds > 0 {
            let minutes = max(1, seconds / 60)
            text += " · signal \(ICEDataSource.connectivityLabel(next)) prévu dans \(minutes) min"
        }
        return text
    }

    private func vehicleText(_ snap: ICESnapshot) -> String? {
        var parts: [String] = []
        if let model = snap.modelName { parts.append(model) }
        if let vehicle = snap.vehicleId { parts.append("rame \(vehicle)") }
        switch snap.wagonClass {
        case "FIRST":  parts.append("1re classe")
        case "SECOND": parts.append("2e classe")
        default:       break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func connectivityLabel(_ state: String) -> String {
        switch state.uppercased() {
        case "HIGH":       return "fort"
        case "MIDDLE":     return "moyen"
        case "WEAK":       return "faible"
        case "UNSTABLE":   return "instable"
        case "NO_INFO":    return "inconnu"
        case "NO_INTERNET": return "coupé"
        default:           return state.lowercased()
        }
    }

    /// Raccourcit un nom de gare pour la pastille, dont la largeur est plafonnée à 150 px :
    /// on retire la parenthèse et le suffixe « Hbf », puis on ne garde que la ville.
    /// « Frankfurt(Main)Hbf » → « Frankfurt », « Berlin Südkreuz » → « Berlin ».
    static func shortStationName(_ name: String) -> String {
        var short = name
        if let parenthesis = short.firstIndex(of: "(") {
            short = String(short[short.startIndex..<parenthesis])
        }
        for suffix in [" Hbf", " Hauptbahnhof", "Hbf"] where short.hasSuffix(suffix) {
            short = String(short.dropLast(suffix.count))
            break
        }
        short = short.trimmingCharacters(in: .whitespaces)

        guard short.count > 12, let city = short.split(separator: " ").first, city.count >= 3 else {
            return short.isEmpty ? name : short
        }
        return String(city)
    }

    // MARK: - Carte du bar-restaurant

    /// Le catalogue mêle articles présentables et variantes techniques : on ne garde que les
    /// articles visibles et catégorisés (105 sur 199 à bord). Libellés en allemand, tels que
    /// l'API les fournit — elle n'expose aucune traduction.
    static func makeMenu(_ products: [[String: Any]]) -> OnboardMenu? {
        var byCategory: [String: [OnboardMenu.Item]] = [:]
        var order: [String] = []

        for product in products {
            guard (product["visible"] as? Bool) ?? false,
                  let category = (product["category"] as? String), !category.isEmpty,
                  let title = (product["title"] as? String), !title.isEmpty,
                  (product["productType"] as? String) != "OPTION_ARTICLE"
            else { continue }

            let item = OnboardMenu.Item(
                id: APIValue.double(product["ecmId"]).map { String(Int($0)) } ?? title,
                title: title,
                detail: (product["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                price: priceText(product["prices"]),
                available: (product["available"] as? Bool) ?? true
            )

            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(item)
        }

        guard !order.isEmpty else { return nil }
        return OnboardMenu(categories: order.map {
            OnboardMenu.Category(id: $0, name: $0, items: byCategory[$0] ?? [])
        })
    }

    /// L'API donne un tableau de prix par devise (EUR et CHF à bord) : on retient l'euro.
    private static func priceText(_ value: Any?) -> String? {
        guard let prices = value as? [[String: Any]] else { return nil }
        let euro = prices.first { ($0["currency"] as? String)?.uppercased() == "EUR" } ?? prices.first
        guard let amount = APIValue.double(euro?["price"]) else { return nil }
        return String(format: "%.2f €", locale: .current, amount)
    }
}
