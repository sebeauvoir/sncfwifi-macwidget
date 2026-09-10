import Foundation
import Combine

/// Modèle de vue exposé au panneau SwiftUI. Purement des données, aucune logique AppKit.

enum StopStatus {
    case passed
    case current
    case upcoming
}

struct StopRow: Identifiable {
    let id: String
    let label: String
    /// Heure théorique "HH:mm" (affichée barrée si retard).
    let theoricTime: String
    let realTime: String
    /// Heure d'arrivée réelle, pour les notifications avant arrivée.
    let arrivalDate: Date?
    let delayMin: Int
    let status: StopStatus
}

struct ArrivalOption: Identifiable {
    let id: String
    let label: String
}

/// Métrique libre affichée par le panneau. Permet à un réseau d'exposer ses spécificités
/// sans toucher aux vues.
struct MetricRow: Identifiable {
    /// `.half` = deux métriques sur la même ligne (altitude + cap).
    enum Span {
        case full
        case half
    }

    let id: String
    let symbol: String
    let text: String
    var span: Span = .full
    var isFootnote: Bool = false

    /// Petite ligne grise de bas de bloc (limites de l'API, qualité du point GPS…).
    static func footnote(_ text: String) -> MetricRow {
        MetricRow(id: "footnote", symbol: "", text: text, isFootnote: true)
    }
}

/// Instantané de tout ce que le panneau affiche pour un train connecté.
struct TrainViewState {
    let provider: TrainProviderDescriptor

    /// Libellés composés par la source, pour que les vues n'aient rien à savoir du réseau.
    var headerTitle: String
    var headerSubtitle: String?

    var delayMin: Int = 0
    var delayCause: String = ""

    var stops: [StopRow] = []
    var globalProgress: Double = 0

    var speedKmh: Int = 0

    var wifiQuality: Int?      // 0…5
    var wifiDevices: Int?

    // Data en Mo
    var dataConsumedMB: Double?
    var dataTotalMB: Double?
    var dataRemainingMB: Double?
    var dataRatio: Double?     // 0…1
    var dataResetTime: String? // "HH:mm"

    var metrics: [MetricRow] = []

    var arrivalOptions: [ArrivalOption] = []
    var selectedArrivalId: String?
}

enum PanelState {
    case loading
    case notConnected(demoMode: Bool)
    case connected(TrainViewState)
}

/// Source d'observation pour la vue SwiftUI. Le `MenuBarController` pousse l'état
/// et branche les closures d'action.
final class TrainStore: ObservableObject {
    @Published var state: PanelState = .loading

    @Published var lastRefreshDate: Date?
    /// Doit refléter le Timer du contrôleur.
    let refreshInterval: TimeInterval = 30

    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSelectArrival: (String) -> Void = { _ in }
    var onToggleDemo: () -> Void = {}
    var onOpenDemoPanel: () -> Void = {}
    var onCopyJSON: () -> Void = {}
    var onOpenAbout: () -> Void = {}
    /// Appelée quand un réglage de notification change (pour relancer un refresh).
    var onSettingsChanged: () -> Void = {}
}
