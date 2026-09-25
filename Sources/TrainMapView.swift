import AppKit
import MapKit
import SwiftUI

/// Carte du trajet, à la manière de `wifi.sncf/fr/journey` : tracé entre les gares, gares
/// passées et à venir, position du train relue chaque seconde.
///
/// `MKMapView` plutôt que la `Map` de SwiftUI : sur macOS 11, cette dernière ne sait pas
/// dessiner de tracé.
struct TrainMapView: NSViewRepresentable {
    let stops: [StopRow]
    let train: CLLocationCoordinate2D?
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
        context.coordinator.update(map, stops: stops, train: train, tint: tint)
    }

    // MARK: - Coordinateur

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var tint: NSColor = .controlAccentColor
        /// Gares et leur état : tant qu'ils ne changent pas, rien n'est redessiné.
        private var stopsKey = ""
        /// Gares seules : un nouveau trajet recadre la carte, un simple changement d'état non.
        private var routeKey = ""
        private var routeLine: MKPolyline?
        private var travelledLine: MKPolyline?
        private var stopAnnotations: [StopAnnotation] = []
        private let trainAnnotation = MKPointAnnotation()
        private var hasTrain = false
        private var hasFramed = false

        func update(_ map: MKMapView,
                    stops: [StopRow],
                    train: CLLocationCoordinate2D?,
                    tint: NSColor) {
            self.tint = tint
            let located = stops.filter { $0.coordinate != nil }

            let newStopsKey = located.map { "\($0.id):\($0.status)" }.joined(separator: "|")
            let newRouteKey = located.map(\.id).joined(separator: "|")
            let routeChanged = newRouteKey != routeKey

            if newStopsKey != stopsKey {
                stopsKey = newStopsKey
                map.removeAnnotations(stopAnnotations)
                stopAnnotations = located.map(StopAnnotation.init)
                map.addAnnotations(stopAnnotations)
            }

            if routeChanged {
                routeKey = newRouteKey
                if let routeLine { map.removeOverlay(routeLine) }
                routeLine = nil
                if located.count > 1 {
                    var coordinates = located.compactMap(\.coordinate)
                    let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                    map.addOverlay(line, level: .aboveRoads)
                    routeLine = line
                }
            }

            updateTravelled(map, located: located, train: train)
            updateTrain(map, train: train)

            if routeChanged || !hasFramed {
                frame(map, located: located, train: train)
            } else if let train, !map.visibleMapRect.contains(MKMapPoint(train)) {
                // Le train sort du cadre (carte déplacée, ou trajet sans gares) : on le suit.
                map.setCenter(train, animated: true)
            }
        }

        /// Portion parcourue : gares passées puis position du train, par-dessus le tracé gris.
        private func updateTravelled(_ map: MKMapView,
                                     located: [StopRow],
                                     train: CLLocationCoordinate2D?) {
            var coordinates = located
                .filter { $0.status == .passed }
                .compactMap(\.coordinate)
            if let train {
                coordinates.append(train)
            } else if let current = located.first(where: { $0.status == .current })?.coordinate {
                coordinates.append(current)
            }

            let old = travelledLine
            travelledLine = nil
            if coordinates.count > 1 {
                let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                // Assigné avant l'ajout : le rendu choisit sa couleur d'après cette référence.
                travelledLine = line
                map.addOverlay(line, level: .aboveRoads)
            }
            // Retiré après l'ajout du nouveau : pas de clignotement entre les deux.
            if let old { map.removeOverlay(old) }
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

        /// Cadre tout le trajet et le train ; sans gares, une cinquantaine de kilomètres autour
        /// du train.
        private func frame(_ map: MKMapView, located: [StopRow], train: CLLocationCoordinate2D?) {
            var points = located.compactMap(\.coordinate).map { MKMapPoint($0) }
            if let train { points.append(MKMapPoint(train)) }
            guard !points.isEmpty else { return }
            // Au premier affichage, la carte n'a pas encore de taille : cadrer maintenant
            // donnerait une vue du monde entier. On réessaie une fois la mise en page faite.
            guard !map.bounds.isEmpty else {
                DispatchQueue.main.async { [weak self, weak map] in
                    guard let self, let map, !map.bounds.isEmpty else { return }
                    self.frame(map, located: located, train: train)
                }
                return
            }
            hasFramed = true

            if points.count == 1 {
                let region = MKCoordinateRegion(center: points[0].coordinate,
                                                latitudinalMeters: 50_000,
                                                longitudinalMeters: 50_000)
                map.setRegion(region, animated: false)
                return
            }
            let rect = points.dropFirst().reduce(MKMapRect(origin: points[0], size: MKMapSize())) {
                $0.union(MKMapRect(origin: $1, size: MKMapSize()))
            }
            map.setVisibleMapRect(rect,
                                  edgePadding: NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18),
                                  animated: false)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineWidth = 3
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.strokeColor = line === travelledLine
                ? tint
                : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let stop = annotation as? StopAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "stop")
                    ?? MKAnnotationView(annotation: stop, reuseIdentifier: "stop")
                view.annotation = stop
                view.image = Self.dot(diameter: stop.status == .current ? 10 : 8,
                                      fill: stop.status == .upcoming ? .white : tint,
                                      stroke: stop.status == .upcoming ? .secondaryLabelColor : .white,
                                      strokeWidth: 1.5)
                view.toolTip = stop.title
                view.canShowCallout = false
                return view
            }
            if annotation === trainAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "train")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "train")
                view.annotation = annotation
                view.image = Self.dot(diameter: 16, fill: tint, stroke: .white, strokeWidth: 3)
                view.displayPriority = .required
                view.layer?.zPosition = 1
                view.canShowCallout = false
                return view
            }
            return nil
        }

        /// Pastille ronde cerclée. Les couleurs dynamiques sont résolues au dessin : elle suit
        /// le thème clair / sombre.
        private static func dot(diameter: CGFloat, fill: NSColor, stroke: NSColor, strokeWidth: CGFloat) -> NSImage {
            let size = diameter + strokeWidth * 2
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
                stroke.setFill()
                path.fill()
                let inner = NSBezierPath(ovalIn: rect.insetBy(dx: strokeWidth, dy: strokeWidth))
                fill.setFill()
                inner.fill()
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

    init(_ stop: StopRow) {
        coordinate = stop.coordinate ?? CLLocationCoordinate2D()
        title = stop.label
        status = stop.status
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
