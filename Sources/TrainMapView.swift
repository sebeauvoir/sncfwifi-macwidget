import AppKit
import MapKit
import SwiftUI

/// Carte du trajet, à la manière de `wifi.sncf/fr/journey` : portion parcourue en trait
/// plein, reste du trajet en trait clair, gares et train en pastilles à pictogramme. Le cadrage
/// suit le train : il tient à un bout le train, à l'autre la gare d'arrivée choisie.
///
/// `MKMapView` plutôt que la `Map` de SwiftUI : sur macOS 11, cette dernière ne sait pas
/// dessiner de tracé.
struct TrainMapView: NSViewRepresentable {
    let stops: [StopRow]
    let train: CLLocationCoordinate2D?
    let arrivalId: String?
    let routePath: [CLLocationCoordinate2D]
    let trail: [CLLocationCoordinate2D]
    let tint: NSColor

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
        context.coordinator.update(map, input: self)
    }

    // MARK: - Coordinateur

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let travelledTitle = "parcouru"

        private var tint: NSColor = .controlAccentColor
        /// Gares, leur état et la gare d'arrivée : tant qu'ils ne changent pas, les pastilles
        /// ne sont pas redessinées.
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

        func update(_ map: MKMapView, input: TrainMapView) {
            tint = input.tint
            let located = input.stops.filter { $0.coordinate != nil }
            let arrivalIndex = located.firstIndex { $0.id == input.arrivalId }

            updateStops(map, located: located, arrivalId: input.arrivalId)

            let lines = Self.lines(located: located,
                                   train: input.train,
                                   routePath: input.routePath,
                                   trail: input.trail,
                                   arrivalIndex: arrivalIndex)
            // Dans cet ordre : le parcouru, ajouté en dernier, passe au-dessus du restant.
            remainingLine = replace(remainingLine, with: lines.remaining, travelled: false, on: map)
            travelledLine = replace(travelledLine, with: lines.travelled, travelled: true, on: map)

            updateTrain(map, train: input.train)
            follow(map, points: lines.frame)
        }

        // MARK: Tracés

        /// Parcouru, restant, et points à cadrer (du train à la gare d'arrivée).
        private static func lines(located: [StopRow],
                                  train: CLLocationCoordinate2D?,
                                  routePath: [CLLocationCoordinate2D],
                                  trail: [CLLocationCoordinate2D],
                                  arrivalIndex: Int?)
            -> (travelled: [CLLocationCoordinate2D], remaining: [CLLocationCoordinate2D], frame: [CLLocationCoordinate2D]) {

            let arrival = arrivalIndex.flatMap { located[$0].coordinate }

            // Tracé publié : on le coupe au point le plus proche du train.
            if routePath.count > 1 {
                let here = train ?? located.first { $0.status == .current }?.coordinate
                let cut = here.map { nearestIndex(in: routePath, to: $0) } ?? 0
                var travelled = Array(routePath[...cut])
                var remaining = Array(routePath[cut...])
                if let train {
                    travelled.append(train)
                    remaining.insert(train, at: 0)
                }
                var frame = [train].compactMap { $0 }
                if let arrival {
                    let end = max(cut, nearestIndex(in: routePath, to: arrival))
                    frame += routePath[cut...end]
                    frame.append(arrival)
                }
                return (travelled, remaining, frame)
            }

            // Sans tracé publié : gares reliées en ligne droite, et positions relevées pour
            // la portion parcourue depuis le lancement de l'app.
            let passed = located.filter { $0.status == .passed }.compactMap(\.coordinate)
            var travelled: [CLLocationCoordinate2D]
            if trail.count > 1, let start = trail.first {
                // Gares passées jusqu'à la plus proche du début du relevé, puis le relevé.
                let joint = passed.isEmpty ? -1 : nearestIndex(in: passed, to: start)
                travelled = Array(passed.prefix(joint + 1)) + trail
            } else {
                travelled = passed
            }
            if let train { travelled.append(train) }

            let aheadIndices = located.indices.filter { located[$0].status != .passed }
            var remaining = aheadIndices.compactMap { located[$0].coordinate }
            if let train { remaining.insert(train, at: 0) }

            var frame = [train].compactMap { $0 }
            if let arrivalIndex, let arrival {
                frame += aheadIndices.filter { $0 <= arrivalIndex }.compactMap { located[$0].coordinate }
                frame.append(arrival)
            }
            return (travelled, remaining, frame)
        }

        private static func nearestIndex(in path: [CLLocationCoordinate2D], to point: CLLocationCoordinate2D) -> Int {
            // Distance au carré en plan local : suffisant pour départager des points voisins.
            let scale = cos(point.latitude * .pi / 180)
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, candidate) in path.enumerated() {
                let dx = (candidate.longitude - point.longitude) * scale
                let dy = candidate.latitude - point.latitude
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            return best
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

        // MARK: Pastilles

        private func updateStops(_ map: MKMapView, located: [StopRow], arrivalId: String?) {
            let key = located.map { "\($0.id):\($0.status)" }.joined(separator: "|") + "→\(arrivalId ?? "")"
            guard key != stopsKey else { return }
            stopsKey = key
            map.removeAnnotations(stopAnnotations)
            stopAnnotations = located.map { StopAnnotation($0, isArrival: $0.id == arrivalId) }
            map.addAnnotations(stopAnnotations)
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

        // MARK: Cadrage

        /// Cadre les points (train → gare d'arrivée). Sans gare d'arrivée, une cinquantaine de
        /// kilomètres autour du train. Ne recadre que si le cadre a sensiblement changé.
        private func follow(_ map: MKMapView, points: [CLLocationCoordinate2D]) {
            if let userMovedAt, Date().timeIntervalSince(userMovedAt) < userPause { return }
            guard !points.isEmpty else { return }
            // Au premier affichage, la carte n'a pas encore de taille : cadrer maintenant
            // donnerait une vue du monde entier. On réessaie une fois la mise en page faite.
            guard !map.bounds.isEmpty else {
                DispatchQueue.main.async { [weak self, weak map] in
                    guard let self, let map, !map.bounds.isEmpty else { return }
                    self.follow(map, points: points)
                }
                return
            }

            let mapPoints = points.map { MKMapPoint($0) }
            var rect = mapPoints.dropFirst().reduce(MKMapRect(origin: mapPoints[0], size: MKMapSize())) {
                $0.union(MKMapRect(origin: $1, size: MKMapSize()))
            }
            // Jamais plus serré que ~4 km (à l'approche de la gare), ~50 km sans gare d'arrivée.
            let meters: Double = points.count == 1 ? 50_000 : 4_000
            let minimum = MKMapPointsPerMeterAtLatitude(points[0].latitude) * meters
            if rect.size.width < minimum || rect.size.height < minimum {
                let width = max(rect.size.width, minimum)
                let height = max(rect.size.height, minimum)
                rect = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
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
            isFraming = false
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

/// Gare placée sur la carte.
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
