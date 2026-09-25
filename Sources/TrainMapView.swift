import AppKit
import MapKit
import SwiftUI
import WebKit

/// Carte du trajet, à la manière de `wifi.sncf/fr/journey` : portion parcourue en trait
/// plein, reste du trajet en trait clair, gares et train en pastilles à pictogramme. Le cadrage
/// suit le train : il tient à un bout le train, à l'autre la gare d'arrivée choisie.
///
/// Deux rendus pour une même géométrie :
/// - les tuiles du serveur embarqué, par MapLibre (`LocalTileMapView`), quand le réseau en a
///   un : aucune requête ne part sur Internet ;
/// - MapKit sinon (`AppleMapView`), dont le fond de carte vient d'Internet.
struct TrainMapView: View {
    let input: TrainMapInput
    /// Origine du serveur de tuiles embarqué (`https://wifi.sncf/`), `nil` s'il n'y en a pas.
    let localTiles: URL?

    /// Mode suivi : train au centre, carte fixe, zoom seul. Sinon, cadrage train → gare
    /// d'arrivée. Mémorisé d'une ouverture à l'autre.
    @AppStorage("mapFollowMode") private var follow = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            map
            modeButton
                .padding(6)
        }
    }

    @ViewBuilder
    private var map: some View {
        let input = self.input.with(follow: follow)
        if let localTiles, LocalTileMapView.html != nil {
            LocalTileMapView(input: input, origin: localTiles)
        } else {
            AppleMapView(input: input)
        }
    }

    /// Le pictogramme montre le mode en cours ; l'infobulle dit ce que fait le clic.
    private var modeButton: some View {
        Button {
            follow.toggle()
        } label: {
            Image(systemName: follow ? "location.fill" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(follow ? Color(NSColor(hex: input.tintHex)) : .primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor).opacity(0.92)))
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
        .help(follow ? "Suivi du train — cliquer pour voir le trajet jusqu'à la gare d'arrivée"
                     : "Trajet jusqu'à la gare d'arrivée — cliquer pour suivre le train")
    }
}

/// Ce que la carte affiche, quel que soit le rendu.
struct TrainMapInput {
    let stops: [StopRow]
    let train: CLLocationCoordinate2D?
    let arrivalId: String?
    let routePath: [CLLocationCoordinate2D]
    let trail: [CLLocationCoordinate2D]
    let tintHex: UInt32
    /// Mode suivi, posé par `TrainMapView` d'après le bouton.
    var follow = false

    func with(follow: Bool) -> TrainMapInput {
        var copy = self
        copy.follow = follow
        return copy
    }

    var tint: NSColor { NSColor(hex: tintHex) }
    var tintCSS: String { String(format: "#%06X", tintHex) }
}

// MARK: - Géométrie commune

/// Tracés et cadrage, calculés en Swift pour les deux rendus. Les tracés ne portent pas la
/// position du train : chaque rendu la raccorde lui-même, ce qui évite de renvoyer tout le
/// tracé à chaque seconde.
struct TrainMapGeometry {
    struct Output {
        let located: [StopRow]
        let arrivalId: String?
        let travelled: [CLLocationCoordinate2D]
        let remaining: [CLLocationCoordinate2D]
        /// Change quand les tracés changent ; stable tant que seul le train bouge.
        let linesKey: String
        /// Change quand les pastilles des gares changent.
        let stopsKey: String
        /// Cadre train → gare d'arrivée, ou ~50 km autour du train, ou tout le trajet.
        let frame: MKMapRect?
    }

    /// Dernier point du tracé atteint par le train. Le tracé peut repasser près de lui-même
    /// (rebroussement à Marseille Saint-Charles) : on cherche d'abord devant ce point.
    private var pathCut = 0
    private var pathCount = 0

    mutating func compute(_ input: TrainMapInput) -> Output {
        let located = input.stops.filter { $0.coordinate != nil }
        let arrivalIndex = located.firstIndex { $0.id == input.arrivalId }
        let arrival = arrivalIndex.flatMap { located[$0].coordinate }
        let train = input.train
        let stopsKey = located.map { "\($0.id):\($0.status)" }.joined(separator: "|") + "→\(input.arrivalId ?? "")"

        var travelled: [CLLocationCoordinate2D]
        var remaining: [CLLocationCoordinate2D]
        var framePoints = [train].compactMap { $0 }
        let linesKey: String

        let path = input.routePath
        if path.count > 1 {
            // Tracé publié : coupé au point le plus proche du train.
            if path.count != pathCount {
                pathCount = path.count
                pathCut = 0
            }
            let here = train ?? located.first { $0.status == .current }?.coordinate
            let cut = here.map { Self.forwardIndex(in: path, to: $0, from: pathCut) } ?? 0
            pathCut = cut
            travelled = Array(path[...cut])
            remaining = Array(path[cut...])
            if let arrival {
                // Gare d'arrivée cherchée devant le train, pour la même raison.
                let end = Self.nearest(in: path, to: arrival, range: cut..<path.count).index
                framePoints += path[cut...end]
                framePoints.append(arrival)
            }
            linesKey = "path:\(path.count):\(cut)"
        } else {
            // Sans tracé publié : gares reliées en ligne droite, et positions relevées pour la
            // portion parcourue depuis le lancement de l'app.
            let passed = located.filter { $0.status == .passed }.compactMap(\.coordinate)
            if input.trail.count > 1, let start = input.trail.first {
                // Gares passées jusqu'à la plus proche du début du relevé, puis le relevé.
                let joint = passed.isEmpty ? -1 : Self.nearestIndex(in: passed, to: start)
                travelled = Array(passed.prefix(joint + 1)) + input.trail
            } else {
                travelled = passed
            }
            let aheadIndices = located.indices.filter { located[$0].status != .passed }
            remaining = aheadIndices.compactMap { located[$0].coordinate }
            if let arrivalIndex, let arrival {
                framePoints += aheadIndices.filter { $0 <= arrivalIndex }.compactMap { located[$0].coordinate }
                framePoints.append(arrival)
            }
            linesKey = "stops:\(stopsKey):\(input.trail.count)"
        }

        // Ni train ni gare d'arrivée : tout le trajet.
        if framePoints.isEmpty { framePoints = located.compactMap(\.coordinate) }

        return Output(located: located,
                      arrivalId: input.arrivalId,
                      travelled: travelled,
                      remaining: remaining,
                      linesKey: linesKey,
                      stopsKey: stopsKey,
                      frame: Self.frame(framePoints))
    }

    /// Rectangle englobant, jamais plus serré que ~4 km (à l'approche de la gare), ni que
    /// ~50 km autour d'un point seul.
    private static func frame(_ points: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let first = points.first else { return nil }
        let mapPoints = points.map { MKMapPoint($0) }
        var rect = mapPoints.dropFirst().reduce(MKMapRect(origin: mapPoints[0], size: MKMapSize())) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize()))
        }
        let meters: Double = points.count == 1 ? 50_000 : 4_000
        let minimum = MKMapPointsPerMeterAtLatitude(first.latitude) * meters
        if rect.size.width < minimum || rect.size.height < minimum {
            let width = max(rect.size.width, minimum)
            let height = max(rect.size.height, minimum)
            rect = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        return rect
    }

    static func nearestIndex(in path: [CLLocationCoordinate2D], to point: CLLocationCoordinate2D) -> Int {
        nearest(in: path, to: point, range: path.indices).index
    }

    /// Point du tracé le plus proche, cherché juste devant le dernier atteint (une centaine de
    /// kilomètres) : un passage plus loin sur les mêmes voies ne doit pas faire sauter le train
    /// en avant. Si rien n'est proche (plus de 2 km : app lancée en cours de route, GPS qui
    /// décroche), on cherche sur tout le tracé.
    private static func forwardIndex(in path: [CLLocationCoordinate2D],
                                     to point: CLLocationCoordinate2D,
                                     from start: Int) -> Int {
        let lower = min(max(0, start), path.count - 1)
        let upper = min(path.count, lower + 400)
        let ahead = nearest(in: path, to: point, range: lower..<upper)
        // ~2 km, en degrés au carré.
        let threshold = pow(2_000 / 111_000, 2.0)
        return ahead.distance < threshold ? ahead.index : nearestIndex(in: path, to: point)
    }

    private static func nearest(in path: [CLLocationCoordinate2D],
                                to point: CLLocationCoordinate2D,
                                range: Range<Int>) -> (index: Int, distance: Double) {
        // Distance au carré en plan local : suffisant pour départager des points voisins.
        let scale = cos(point.latitude * .pi / 180)
        var best = range.lowerBound
        var bestDistance = Double.greatestFiniteMagnitude
        for index in range {
            let candidate = path[index]
            let dx = (candidate.longitude - point.longitude) * scale
            let dy = candidate.latitude - point.latitude
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return (best, bestDistance)
    }
}

// MARK: - Rendu hors ligne : tuiles du serveur embarqué

/// Carte MapLibre dans une vue web, avec le style et les tuiles PMTiles du portail. La page
/// est chargée avec l'origine du portail : ses lectures de tuiles restent de même origine, le
/// serveur du train n'envoyant pas d'en-têtes CORS.
struct LocalTileMapView: NSViewRepresentable {
    let input: TrainMapInput
    let origin: URL

    /// `map.html` avec MapLibre et pmtiles insérés, lu une fois. `nil` si les ressources
    /// manquent : la carte retombe alors sur MapKit.
    static let html: String? = {
        func resource(_ name: String, _ ext: String) -> String? {
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Map")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let template = resource("map", "html"),
              let css = resource("maplibre-gl", "css"),
              let maplibre = resource("maplibre-gl", "js"),
              let pmtiles = resource("pmtiles", "js")
        else { return nil }
        return template
            .replacingOccurrences(of: "/*MAPLIBRE_CSS*/", with: css)
            .replacingOccurrences(of: "/*PMTILES_JS*/", with: pmtiles)
            .replacingOccurrences(of: "/*MAPLIBRE_JS*/", with: maplibre)
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "map")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        // Fond transparent le temps que les tuiles arrivent.
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = false
        web.wantsLayer = true
        web.layer?.cornerRadius = 8
        web.layer?.masksToBounds = true
        if let html = Self.html {
            web.loadHTMLString(html, baseURL: origin)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, input: input)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var geometry = TrainMapGeometry()
        private var isLoaded = false
        private var lastInput: TrainMapInput?
        /// Derniers tracés et pastilles envoyés à la page : on ne les renvoie que s'ils changent.
        private var sentLinesKey = ""
        private var sentStopsKey = ""

        func update(_ web: WKWebView, input: TrainMapInput) {
            lastInput = input
            // Page pas encore chargée : `didFinish` rejouera la dernière entrée.
            guard isLoaded else { return }

            let output = geometry.compute(input)
            var payload: [String: Any] = [
                "mode": input.follow ? "follow" : "overview",
                "tint": input.tintCSS,
                "train": input.train.map { [$0.longitude, $0.latitude] as Any } ?? NSNull(),
            ]
            if output.linesKey != sentLinesKey {
                sentLinesKey = output.linesKey
                payload["travelled"] = output.travelled.map { [$0.longitude, $0.latitude] }
                payload["remaining"] = output.remaining.map { [$0.longitude, $0.latitude] }
            }
            if output.stopsKey != sentStopsKey {
                sentStopsKey = output.stopsKey
                payload["stopsKey"] = output.stopsKey
                payload["stops"] = output.located.compactMap { stop -> [String: Any]? in
                    guard let coordinate = stop.coordinate else { return nil }
                    return ["c": [coordinate.longitude, coordinate.latitude],
                            "label": stop.label,
                            "status": Self.status(stop.status),
                            "arrival": stop.id == output.arrivalId]
                }
            }
            if let frame = output.frame {
                let southWest = MKMapPoint(x: frame.minX, y: frame.maxY).coordinate
                let northEast = MKMapPoint(x: frame.maxX, y: frame.minY).coordinate
                payload["bounds"] = [[southWest.longitude, southWest.latitude],
                                     [northEast.longitude, northEast.latitude]]
            }

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            web.evaluateJavaScript("window.update(\(json))", completionHandler: nil)
        }

        private static func status(_ status: StopStatus) -> String {
            switch status {
            case .passed:   return "passed"
            case .current:  return "current"
            case .upcoming: return "upcoming"
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let lastInput { update(webView, input: lastInput) }
        }

        /// La page ne quitte jamais la carte : un clic sur un lien éventuel est ignoré.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  type != "ready"
            else { return }
            NSLog("SNCFWifi carte : %@ %@", type, (body["message"] as? String) ?? "")
        }
    }
}

/// `WKUserContentController` retient ses gestionnaires : sans ce relais, le coordinateur (et
/// donc la vue web) ne serait jamais libéré.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Rendu MapKit (fond de carte Apple, via Internet)

/// `MKMapView` plutôt que la `Map` de SwiftUI : sur macOS 11, cette dernière ne sait pas
/// dessiner de tracé.
struct AppleMapView: NSViewRepresentable {
    let input: TrainMapInput

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsZoomControls = false
        map.showsScale = false
        map.showsBuildings = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        // Coins arrondis portés par le calque : `.cornerRadius` de SwiftUI ne rogne pas
        // toujours une vue AppKit sur macOS 11.
        map.wantsLayer = true
        map.layer?.cornerRadius = 8
        map.layer?.masksToBounds = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map, input: input)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let travelledTitle = "parcouru"

        private var geometry = TrainMapGeometry()
        private var tint: NSColor = .controlAccentColor
        private var stopsKey = ""
        private var travelledLine: MKPolyline?
        private var remainingLine: MKPolyline?
        private var stopAnnotations: [StopAnnotation] = []
        private let trainAnnotation = MKPointAnnotation()
        private var hasTrain = false

        /// Cadre appliqué en dernier, pour ne recadrer que quand le train a assez avancé.
        private var framedRect: MKMapRect?
        /// Un recadrage lancé par le code ne doit pas passer pour un geste de l'utilisateur.
        private var isFraming = false
        /// Après un zoom ou un déplacement à la main, le suivi s'efface une minute.
        private var userMovedAt: Date?
        private let userPause: TimeInterval = 60
        /// Mode suivi, et train à garder au centre après un zoom.
        private var isFollowing = false
        private var followedTrain: CLLocationCoordinate2D?
        /// Étendue du suivi au premier passage : une quinzaine de kilomètres.
        private let followSpan: CLLocationDistance = 15_000

        func update(_ map: MKMapView, input: TrainMapInput) {
            tint = input.tint
            let output = geometry.compute(input)
            applyMode(map, follow: input.follow)

            if output.stopsKey != stopsKey {
                stopsKey = output.stopsKey
                map.removeAnnotations(stopAnnotations)
                stopAnnotations = output.located.map { StopAnnotation($0, isArrival: $0.id == output.arrivalId) }
                map.addAnnotations(stopAnnotations)
            }

            let head = [input.train].compactMap { $0 }
            // Dans cet ordre : le parcouru, ajouté en dernier, passe au-dessus du restant.
            remainingLine = replace(remainingLine, with: head + output.remaining, travelled: false, on: map)
            travelledLine = replace(travelledLine, with: output.travelled + head, travelled: true, on: map)

            updateTrain(map, train: input.train)
            if isFollowing {
                center(map, on: input.train)
            } else if let frame = output.frame {
                follow(map, rect: frame)
            }
        }

        /// Suivi : la carte ne se déplace plus, seul le zoom reste permis.
        private func applyMode(_ map: MKMapView, follow: Bool) {
            guard follow != isFollowing else { return }
            isFollowing = follow
            map.isScrollEnabled = !follow
            if follow {
                followedTrain = nil
            } else {
                // Retour au cadrage train → gare d'arrivée, sans attendre la fin d'une pause.
                framedRect = nil
                userMovedAt = nil
            }
        }

        private func center(_ map: MKMapView, on train: CLLocationCoordinate2D?) {
            guard let train else { return }
            let first = followedTrain == nil
            followedTrain = train
            isFraming = true
            if first {
                map.setRegion(MKCoordinateRegion(center: train,
                                                 latitudinalMeters: followSpan,
                                                 longitudinalMeters: followSpan),
                              animated: false)
                isFraming = false
            } else {
                map.setCenter(train, animated: true)
            }
        }

        /// Ajoute le nouveau tracé puis retire l'ancien : pas de clignotement entre les deux.
        private func replace(_ old: MKPolyline?,
                             with coordinates: [CLLocationCoordinate2D],
                             travelled: Bool,
                             on map: MKMapView) -> MKPolyline? {
            var line: MKPolyline?
            if coordinates.count > 1 {
                var points = coordinates
                let new = MKPolyline(coordinates: &points, count: points.count)
                // Le titre dit au rendu quelle couleur employer.
                new.title = travelled ? Self.travelledTitle : nil
                map.addOverlay(new, level: .aboveRoads)
                line = new
            }
            if let old { map.removeOverlay(old) }
            return line
        }

        private func updateTrain(_ map: MKMapView, train: CLLocationCoordinate2D?) {
            guard let train else {
                if hasTrain { map.removeAnnotation(trainAnnotation) }
                hasTrain = false
                return
            }
            trainAnnotation.coordinate = train
            if !hasTrain {
                map.addAnnotation(trainAnnotation)
                hasTrain = true
            }
        }

        /// Ne recadre que si le cadre a sensiblement changé, et jamais pendant la pause qui
        /// suit un geste.
        private func follow(_ map: MKMapView, rect: MKMapRect) {
            if let userMovedAt, Date().timeIntervalSince(userMovedAt) < userPause { return }
            // Au premier affichage, la carte n'a pas encore de taille : cadrer maintenant
            // donnerait une vue du monde entier. On réessaie une fois la mise en page faite.
            guard !map.bounds.isEmpty else {
                DispatchQueue.main.async { [weak self, weak map] in
                    guard let self, let map, !map.bounds.isEmpty else { return }
                    self.follow(map, rect: rect)
                }
                return
            }
            if let framedRect, Self.isClose(framedRect, rect) { return }
            let animated = framedRect != nil
            framedRect = rect
            isFraming = true
            map.setVisibleMapRect(rect,
                                  edgePadding: NSEdgeInsets(top: 26, left: 26, bottom: 26, right: 26),
                                  animated: animated)
            if !animated { isFraming = false }
        }

        /// Écart inférieur à 5 % de la taille du cadre : pas la peine de bouger la carte.
        private static func isClose(_ a: MKMapRect, _ b: MKMapRect) -> Bool {
            let tolerance = 0.05 * max(a.size.width, a.size.height, 1)
            return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
                && abs(a.size.width - b.size.width) < tolerance && abs(a.size.height - b.size.height) < tolerance
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Tout changement de cadre qui ne vient pas du suivi vient d'un geste.
            if !isFraming, framedRect != nil { userMovedAt = Date() }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let byUser = !isFraming
            isFraming = false
            // Suivi : un zoom au pincement se fait autour du pointeur ; on ramène le train
            // au centre aussitôt.
            if isFollowing, byUser, let followedTrain {
                isFraming = true
                mapView.setCenter(followedTrain, animated: false)
                isFraming = false
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.strokeColor = line.title == Self.travelledTitle ? tint : tint.withAlphaComponent(0.4)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let stop = annotation as? StopAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "stop")
                    ?? MKAnnotationView(annotation: stop, reuseIdentifier: "stop")
                view.annotation = stop
                let diameter: CGFloat = stop.isArrival ? 26 : (stop.status == .passed ? 16 : 20)
                view.image = Self.badge(symbol: "building.columns.fill",
                                        diameter: diameter,
                                        fill: stop.status == .passed ? .secondaryLabelColor : tint)
                view.toolTip = stop.title
                view.canShowCallout = false
                view.displayPriority = stop.isArrival ? .required : .defaultHigh
                return view
            }
            if annotation === trainAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "train")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "train")
                view.annotation = annotation
                view.image = Self.badge(symbol: "tram.fill", diameter: 30, fill: tint)
                view.displayPriority = .required
                view.layer?.zPosition = 1
                view.canShowCallout = false
                return view
            }
            return nil
        }

        /// Pastille ronde cerclée de blanc, pictogramme blanc au centre. Les couleurs
        /// dynamiques sont résolues au dessin : elle suit le thème clair / sombre.
        private static func badge(symbol: String, diameter: CGFloat, fill: NSColor) -> NSImage {
            let ring: CGFloat = 2
            let size = NSSize(width: diameter, height: diameter)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
                fill.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: ring, dy: ring)).fill()

                let configuration = NSImage.SymbolConfiguration(pointSize: diameter * 0.46, weight: .semibold)
                guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(configuration)
                else { return true }
                // Pictogramme passé en blanc : dessiné, puis recouvert en mode « source atop ».
                let white = NSImage(size: glyph.size, flipped: false) { glyphRect in
                    glyph.draw(in: glyphRect)
                    NSColor.white.setFill()
                    glyphRect.fill(using: .sourceAtop)
                    return true
                }
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
                white.draw(in: NSRect(origin: origin, size: glyph.size))
                return true
            }
        }
    }
}

/// Gare placée sur la carte MapKit.
private final class StopAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let status: StopStatus
    let isArrival: Bool

    init(_ stop: StopRow, isArrival: Bool) {
        coordinate = stop.coordinate ?? CLLocationCoordinate2D()
        title = stop.label
        status = stop.status
        self.isArrival = isArrival
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
