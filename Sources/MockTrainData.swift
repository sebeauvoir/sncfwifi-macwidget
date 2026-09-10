import Foundation

/// Mode démo piloté par un serveur local (API mock configurable).
class MockTrainData {
    static let shared = MockTrainData()
    private let timeout: TimeInterval = 2
    private let baseURLKey = "demoServerBaseURL"
    private let operatorKey = "demoOperator"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isDemoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "isDemoMode") }
    }

    /// Réseau simulé, désigné par l'identifiant de son descripteur. Le serveur démo sert les
    /// deux jeux d'endpoints en parallèle ; ce réglage décide lequel l'app interroge.
    var demoProviderId: String {
        get { UserDefaults.standard.string(forKey: operatorKey) ?? "sncf" }
        set { UserDefaults.standard.set(newValue, forKey: operatorKey) }
    }

    var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "http://127.0.0.1:8787" }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    private var baseURL: URL? {
        URL(string: baseURLString)
    }

    private init() {}

    func start() {
        NotificationCenter.default.post(name: NSNotification.Name("DemoDataDidUpdate"), object: nil)
    }

    func stop() {
        // Pas d'état à arrêter: la source est externe (serveur local).
    }

    func fetchAll(completion: @escaping (_ gps: [String: Any]?, _ details: [String: Any]?, _ bar: [String: Any]?, _ stats: [String: Any]?, _ status: [String: Any]?) -> Void) {
        guard let baseURL else {
            DispatchQueue.main.async { completion(nil, nil, nil, nil, nil) }
            return
        }

        let group = DispatchGroup()
        var gpsData: [String: Any]?
        var detailsData: [String: Any]?
        var barData: [String: Any]?
        var statsData: [String: Any]?
        var statusData: [String: Any]?

        let endpoints: [(String, ([String: Any]?) -> Void)] = [
            ("/router/api/train/gps", { gpsData = $0 }),
            ("/router/api/train/progress", { detailsData = $0 }),
            ("/router/api/bar/attendance", { barData = $0 }),
            ("/router/api/connection/statistics", { statsData = $0 }),
            ("/router/api/connection/status", { statusData = $0 })
        ]

        for (path, setter) in endpoints {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }
            group.enter()
            fetch(url: url) {
                setter($0)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(gpsData, detailsData, barData, statsData, statusData)
        }
    }

    /// Chemins de la plateforme Icomera, servis en JSONP par le serveur démo — ce qui exerce
    /// aussi le déballage de `APIBody`.
    func fetchAllEurostar(completion: @escaping (_ system: [String: Any]?, _ connectivity: [String: Any]?, _ users: [String: Any]?, _ user: [String: Any]?, _ position: [String: Any]?) -> Void) {
        guard let baseURL else {
            DispatchQueue.main.async { completion(nil, nil, nil, nil, nil) }
            return
        }

        let group = DispatchGroup()
        var systemData: [String: Any]?
        var connectivityData: [String: Any]?
        var usersData: [String: Any]?
        var userData: [String: Any]?
        var positionData: [String: Any]?

        let endpoints: [(String, ([String: Any]?) -> Void)] = [
            ("/api/jsonp/system/", { systemData = $0 }),
            ("/api/jsonp/connectivity/", { connectivityData = $0 }),
            ("/api/jsonp/users/", { usersData = $0 }),
            ("/api/jsonp/user/", { userData = $0 }),
            ("/api/jsonp/position/", { positionData = $0 })
        ]

        for (path, setter) in endpoints {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }
            group.enter()
            fetch(url: url) {
                setter($0)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(systemData, connectivityData, usersData, userData, positionData)
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        APIBody.fetch(url: url, timeout: timeout, completion: completion)
    }
}
