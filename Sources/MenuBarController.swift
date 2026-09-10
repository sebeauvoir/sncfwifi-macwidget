import Cocoa
import CoreLocation
import CoreWLAN
import UserNotifications
import SwiftUI

final class MenuBarController: NSObject {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var clockTimer: Timer?
    private var lastRawData: [String: Any]?

    private let store = TrainStore()
    private let popover = NSPopover()
    private lazy var panelHost = NSHostingController(rootView: AnyView(TrainPanelView().environmentObject(store)))

    /// Pastille courante : le `clockTimer` la redessine toutes les 10 s sans rappeler l'API.
    /// `nil` = pas de train : sans ça, le redraw périodique réafficherait le train précédent
    /// par-dessus l'icône « réseau inconnu ».
    private var badge: StatusBadge?

    /// Incrémenté à chaque `refresh()`. Une réponse d'API ou de sonde portant un jeton périmé
    /// est ignorée, sinon une requête lente pourrait ressusciter le train précédent.
    private var refreshToken = 0

    /// Fournisseur retenu au dernier cycle réussi. Sert quand le SSID est illisible
    /// (autorisation Localisation refusée) : évite de re-sonder tous les réseaux à chaque fois.
    private var detectedProvider: TrainDataSource?
    private var providerBySSID: [String: TrainDataSource] = [:]
    /// SSID sondés sans succès, horodatés. Un délai plutôt qu'une liste noire définitive, car
    /// le portail d'un train peut n'être joignable qu'au bout de quelques minutes à bord.
    private var nonTrainSSIDs: [String: Date] = [:]
    private let nonTrainProbeCooldown: TimeInterval = 300

    private let locationManager = CLLocationManager()
    private let notificationCenter = UNUserNotificationCenter.current()

    private let notifyBeforeArrivalEnabledKey = "notifyBeforeArrivalEnabled"
    private let notifyBeforeArrivalMinutesKey = "notifyBeforeArrivalMinutes"
    private let notifyBeforeArrivalTargetKey = "notifyBeforeArrivalTarget"
    private let lastArrivalNotificationStopIdKey = "lastArrivalNotificationStopId"
    private let allowedNotificationLeadTimes = [5, 10, 15]

    private enum ArrivalNotificationTarget: String {
        case selectedArrival
        case nextStop
    }

    // MARK: - Init

    override init() {
        super.init()

        // Autorisation de localisation : nécessaire pour lire le SSID (macOS 14.4+).
        locationManager.delegate = self
        requestSSIDAuthorizationIfNeeded()

        registerNotificationDefaults()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Train")
        statusItem.button?.imagePosition = .imageLeft

        // Le clic ouvre le panneau flottant : ne jamais réassigner statusItem.menu.
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        configurePopover()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSNotification.Name("DemoDataDidUpdate"), object: nil)

        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.redrawTitle()
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panelHost

        store.onRefresh = { [weak self] in
            // Une actualisation manuelle court-circuite le délai de re-sonde : c'est le geste
            // de l'utilisateur qui vient de monter dans le train.
            self?.nonTrainSSIDs.removeAll()
            self?.refresh()
        }
        store.onQuit = { NSApp.terminate(nil) }
        store.onSelectArrival = { [weak self] stopId in
            UserDefaults.standard.set(stopId, forKey: "arrivalStationId")
            self?.refresh()
        }
        store.onToggleDemo = { [weak self] in self?.toggleDemoMode() }
        store.onSetDemoOperator = { [weak self] providerId in
            MockTrainData.shared.demoProviderId = providerId
            self?.forgetDetectedProvider()
            self?.refresh()
        }
        store.onOpenDemoPanel = { [weak self] in self?.openDemoControlPanel() }
        store.onCopyJSON = { [weak self] in self?.copyDebugData() }
        store.onOpenAbout = { [weak self] in self?.openAbout() }
        store.onSettingsChanged = { [weak self] in
            self?.lastArrivalNotifiedStopId = nil
            self?.refresh()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sizePopoverToContent()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// `NSPopover` ne suit pas la taille intrinsèque de sa vue SwiftUI : sans ça, il garde la
    /// hauteur de son premier affichage et rogne le bas du contenu.
    private func sizePopoverToContent() {
        panelHost.view.layoutSubtreeIfNeeded()
        let fitting = panelHost.view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        popover.contentSize = fitting
    }

    private func publish(_ state: PanelState) {
        store.lastRefreshDate = Date()
        store.state = state
        guard popover.isShown else { return }
        DispatchQueue.main.async { [weak self] in self?.sizePopoverToContent() }
    }

    // MARK: - Pastille

    @objc private func redrawTitle() {
        guard let badge else { return }
        if let delayTitle = badge.delayTitle {
            // Le retard s'affiche 5 s, puis on repasse au texte normal.
            applyTitleImage(text: delayTitle, progress: badge.progress)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.redrawNormalTitle()
            }
        } else {
            redrawNormalTitle()
        }
    }

    private func redrawNormalTitle() {
        guard let badge else { return }
        applyTitleImage(text: badge.title(), progress: badge.progress)
    }

    private func applyTitleImage(text: String, progress: Double?) {
        guard !text.isEmpty,
              let image = StatusBarImageGenerator.draw(text: text, progress: progress)
        else { return }
        statusItem.button?.title = ""
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }

    // MARK: - Détection du réseau

    @objc func refresh() {
        refreshToken += 1
        let token = refreshToken

        // Le mode démo rejoue l'API SNCF, quel que soit le réseau courant.
        if MockTrainData.shared.isEnabled {
            if let demo = TrainProviders.demoSource { fetchAndPublish(from: demo, token: token) }
            return
        }

        let ssid = CWWiFiClient.shared().interface()?.ssid() ?? ""
        if !ssid.isEmpty {
            if let source = TrainProviders.source(forSSID: ssid) ?? providerBySSID[ssid] {
                detectedProvider = source
                fetchAndPublish(from: source, token: token)
                return
            }
            // SSID sondé sans succès récemment : aucun appel réseau, on épargne la batterie.
            if let probedAt = nonTrainSSIDs[ssid],
               Date().timeIntervalSince(probedAt) < nonTrainProbeCooldown {
                detectedProvider = nil
                showNotConnected()
                return
            }
            probeProviders { [weak self] source in
                guard let self, self.isCurrent(token) else { return }
                guard let source else {
                    self.nonTrainSSIDs[ssid] = Date()
                    self.detectedProvider = nil
                    self.showNotConnected()
                    return
                }
                self.providerBySSID[ssid] = source
                self.detectedProvider = source
                self.fetchAndPublish(from: source, token: token)
            }
            return
        }

        // SSID illisible (Localisation refusée, vieux macOS, réseau masqué).
        if let source = detectedProvider {
            fetchAndPublish(from: source, token: token)
            return
        }
        probeProviders { [weak self] source in
            guard let self, self.isCurrent(token) else { return }
            guard let source else {
                self.showNotConnected()
                return
            }
            self.detectedProvider = source
            self.fetchAndPublish(from: source, token: token)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == refreshToken
    }

    /// Sonde tous les réseaux en parallèle. Aucun n'est privilégié : l'ordre de
    /// `TrainProviders.all` ne sert qu'à départager si plusieurs répondent.
    private func probeProviders(completion: @escaping (TrainDataSource?) -> Void) {
        let sources = TrainProviders.all
        let group = DispatchGroup()
        let syncQueue = DispatchQueue(label: "fr.sncf.wifi-widget.probe")
        var onboardIds: Set<String> = []

        for source in sources {
            group.enter()
            source.probeOnboard { onboard in
                if onboard {
                    syncQueue.sync { _ = onboardIds.insert(source.descriptor.id) }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(sources.first { onboardIds.contains($0.descriptor.id) })
        }
    }

    /// Oublie le fournisseur détecté après un échec d'API, pour re-sonder au prochain cycle.
    private func forgetDetectedProvider() {
        detectedProvider = nil
        providerBySSID.removeAll()
    }

    private func showNotConnected() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.badge = nil
            self.statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
            self.statusItem.button?.imagePosition = .imageLeft
            self.statusItem.button?.title = ""
            self.publish(.notConnected(demoMode: MockTrainData.shared.isEnabled))
        }
    }

    // MARK: - Refresh

    private func fetchAndPublish(from source: TrainDataSource, token: Int) {
        source.fetch { [weak self] snapshot in
            guard let self, self.isCurrent(token) else { return }

            guard let snapshot else {
                self.lastRawData = self.debugSnapshot(provider: source.descriptor, payloads: [:])
                self.forgetDetectedProvider()
                self.showNotConnected()
                return
            }

            self.lastRawData = self.debugSnapshot(provider: source.descriptor, payloads: snapshot.rawPayloads)
            if let notification = self.notifyBeforeArrivalIfNeeded(snapshot: snapshot) {
                self.lastRawData?["notification"] = notification
            }

            self.badge = snapshot.badge
            self.redrawTitle()
            self.publish(.connected(snapshot.viewState))
        }
    }

    private func debugSnapshot(provider: TrainProviderDescriptor, payloads: [String: Any]) -> [String: Any] {
        let ssidInfo = currentSSIDInfo()
        var data: [String: Any] = [
            "provider": provider.id,
            "apiHost": provider.apiHost,
            "ssid": ssidInfo.ssid,
            "ssidStatus": ssidInfo.status,
            "demoMode": MockTrainData.shared.isEnabled,
            "demoServerURL": MockTrainData.shared.baseURLString
        ]
        if !TrainProviders.hostChecks.isEmpty {
            data["apiHostOnboard"] = TrainProviders.hostChecks
        }
        for (key, value) in payloads { data[key] = value }
        return data
    }

    // MARK: - Notifications avant arrivée

    /// Réservée aux réseaux qui exposent une desserte. Rend de quoi alimenter le dump debug.
    @discardableResult
    private func notifyBeforeArrivalIfNeeded(snapshot: TrainSnapshot) -> [String: Any]? {
        guard snapshot.viewState.provider.features.contains(.journey),
              let journey = snapshot.journey,
              let target = notificationTargetStop(stops: snapshot.viewState.stops, journey: journey),
              let arrivalDate = target.arrivalDate
        else { return nil }

        let minutesRemaining = Int(arrivalDate.timeIntervalSinceNow / 60)
        maybeNotifyBeforeArrival(stopId: target.id,
                                 stopLabel: target.label,
                                 minutesRemaining: minutesRemaining,
                                 isStoppedAtStation: journey.isStoppedAtStation)

        return [
            "enabled": isBeforeArrivalNotificationEnabled,
            "target": arrivalNotificationTarget.rawValue,
            "targetStopId": target.id,
            "targetStopLabel": target.label,
            "minutesRemaining": minutesRemaining,
            "leadTime": beforeArrivalNotificationLeadTime,
            "isStoppedAtStation": journey.isStoppedAtStation
        ]
    }

    private func notificationTargetStop(stops: [StopRow], journey: JourneyContext) -> StopRow? {
        guard !stops.isEmpty else { return nil }

        switch arrivalNotificationTarget {
        case .selectedArrival:
            let index = journey.selectedArrivalIndex
            return stops.indices.contains(index) ? stops[index] : nil
        case .nextStop:
            let index = journey.isStoppedAtStation
                ? min(journey.nextStopIndex + 1, stops.count - 1)
                : journey.nextStopIndex
            return stops.indices.contains(index) ? stops[index] : nil
        }
    }

    private func maybeNotifyBeforeArrival(stopId: String,
                                          stopLabel: String,
                                          minutesRemaining: Int,
                                          isStoppedAtStation: Bool) {
        guard isBeforeArrivalNotificationEnabled else { return }
        guard !isStoppedAtStation else { return }

        // Heure cible dépassée : on réarme pour les prochains arrêts.
        if minutesRemaining <= 0 {
            if lastArrivalNotifiedStopId == stopId {
                lastArrivalNotifiedStopId = nil
            }
            return
        }

        guard minutesRemaining <= beforeArrivalNotificationLeadTime else { return }
        guard lastArrivalNotifiedStopId != stopId else { return }

        let content = UNMutableNotificationContent()
        content.title = "Arrivée imminente"
        content.body = "Vous arrivez à \(stopLabel) dans environ \(minutesRemaining) min."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "arrival-\(stopId)", content: content, trigger: trigger)
        notificationCenter.add(request) { _ in }

        lastArrivalNotifiedStopId = stopId
    }

    // MARK: - Réglages

    private var isBeforeArrivalNotificationEnabled: Bool {
        UserDefaults.standard.bool(forKey: notifyBeforeArrivalEnabledKey)
    }

    private var beforeArrivalNotificationLeadTime: Int {
        let value = UserDefaults.standard.integer(forKey: notifyBeforeArrivalMinutesKey)
        return allowedNotificationLeadTimes.contains(value) ? value : 10
    }

    private var lastArrivalNotifiedStopId: String? {
        get { UserDefaults.standard.string(forKey: lastArrivalNotificationStopIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastArrivalNotificationStopIdKey) }
    }

    private var arrivalNotificationTarget: ArrivalNotificationTarget {
        guard let raw = UserDefaults.standard.string(forKey: notifyBeforeArrivalTargetKey),
              let target = ArrivalNotificationTarget(rawValue: raw)
        else { return .selectedArrival }
        return target
    }

    private func registerNotificationDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyBeforeArrivalEnabledKey: true,
            notifyBeforeArrivalMinutesKey: 10,
            notifyBeforeArrivalTargetKey: ArrivalNotificationTarget.selectedArrival.rawValue
        ])
    }

    // MARK: - SSID / autorisations

    private func currentSSIDInfo() -> (ssid: String, status: String) {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return (ssid, "ok")
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            return ("Inconnu", "location_not_determined")
        case .denied:
            return ("Inconnu", "location_denied")
        case .restricted:
            return ("Inconnu", "location_restricted")
        case .authorized, .authorizedAlways:
            if CWWiFiClient.shared().interface() == nil {
                return ("Inconnu", "wifi_interface_unavailable")
            }
            return ("Inconnu", "ssid_unavailable")
        @unknown default:
            return ("Inconnu", "unknown")
        }
    }

    private func requestSSIDAuthorizationIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        // La politique d'activation (.regular vs .accessory) est gérée dans main.swift.
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Handlers

    @objc private func toggleDemoMode() {
        MockTrainData.shared.isEnabled.toggle()
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        } else {
            MockTrainData.shared.stop()
        }
        refresh()
    }

    @objc private func openDemoControlPanel() {
        guard let url = URL(string: MockTrainData.shared.baseURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAbout() {
        NSWorkspace.shared.open(URL(string: "https://github.com/antvgr/sncfwifi-macwidget")!)
    }

    @objc private func copyDebugData() {
        guard let data = lastRawData,
              let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]),
              let text = String(data: json, encoding: .utf8)
        else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension MenuBarController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Repasser en accessory (barre de menus, sans icône Dock) que l'utilisateur ait
        // accepté ou refusé.
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        if status == .authorized || status == .authorizedAlways {
            refresh()
        }
    }
}
