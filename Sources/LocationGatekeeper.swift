import AppKit
import CoreLocation
import Network

protocol LocationGatekeeperDelegate: AnyObject {
    func locationGatekeeperDidChangeState(isHome: Bool, reason: String)
}

final class LocationGatekeeper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationGatekeeper()

    private var locationManager: CLLocationManager!
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.boywei.MijiaTempBar.networkMonitor")

    // 偏好設定鍵值
    private let enabledKey = "GeofenceEnabled"
    private let homeLatKey = "HomeLatitude"
    private let homeLonKey = "HomeLongitude"
    private let radiusKey = "GeofenceRadius"
    private let homeGatewayMACKey = "HomeGatewayMAC"
    private let homeGatewayIPKey = "HomeGatewayIP"

    weak var bluetoothManager: BluetoothManager?
    weak var delegate: LocationGatekeeperDelegate?

    // 狀態
    private(set) var isInHomeArea: Bool = true
    private(set) var lastKnownDistance: Double?
    private(set) var lastKnownLocation: CLLocation?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                startMonitoring()
            } else {
                stopMonitoring()
                isInHomeArea = true
                bluetoothManager?.resume()
            }
        }
    }

    var geofenceRadius: Double {
        get {
            let r = UserDefaults.standard.double(forKey: radiusKey)
            return r > 0 ? r : 200.0 // 預設 200 公尺半徑
        }
        set {
            UserDefaults.standard.set(newValue, forKey: radiusKey)
            checkCurrentStatus()
        }
    }

    var homeCoordinate: CLLocationCoordinate2D? {
        guard UserDefaults.standard.object(forKey: homeLatKey) != nil,
              UserDefaults.standard.object(forKey: homeLonKey) != nil else { return nil }
        let lat = UserDefaults.standard.double(forKey: homeLatKey)
        let lon = UserDefaults.standard.double(forKey: homeLonKey)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var homeGatewayMAC: String? {
        get { UserDefaults.standard.string(forKey: homeGatewayMACKey) }
        set { UserDefaults.standard.set(newValue, forKey: homeGatewayMACKey) }
    }

    var hasHomeLocation: Bool {
        return homeCoordinate != nil || homeGatewayMAC != nil
    }

    override init() {
        super.init()
        locationManager = CLLocationManager()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters // 100m 粗定位，極省電
        locationManager.distanceFilter = 50.0 // 移動 50 公尺才觸發更新

        if isEnabled {
            startMonitoring()
        }
    }

    func startMonitoring() {
        requestAuthorizationIfNeeded()
        locationManager.startUpdatingLocation()
        startNetworkMonitoring()
        checkCurrentStatus()
    }

    func stopMonitoring() {
        locationManager.stopUpdatingLocation()
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func requestAuthorizationIfNeeded() {
        if #available(macOS 10.15, *) {
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        }
    }

    /// 設定目前所在位置與目前網路閘道為「居家位置」
    func recordCurrentAsHome(completion: @escaping (Bool, String) -> Void) {
        requestAuthorizationIfNeeded()

        // 1. 抓取目前網路 Gateway MAC
        let gateway = getCurrentGatewayInfo()
        if let mac = gateway.mac {
            self.homeGatewayMAC = mac
            UserDefaults.standard.set(gateway.ip, forKey: homeGatewayIPKey)
            mijiaLog("[Location] 已記錄居家網路閘道: IP=\(gateway.ip ?? "nil"), MAC=\(mac)")
        }

        // 2. 抓取目前 GPS/Wi-Fi 定位座標
        if let loc = locationManager.location ?? lastKnownLocation {
            saveHomeCoordinate(loc.coordinate)
            self.lastKnownDistance = 0.0
            self.isInHomeArea = true
            self.isEnabled = true
            completion(true, String(format: "已鎖定居家經緯度 (%.4f, %.4f)，半徑 %.0fm", loc.coordinate.latitude, loc.coordinate.longitude, geofenceRadius))
        } else {
            // 若此時尚未獲得 GPS 座標，嘗試單次要求定位更新
            locationManager.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if let loc = self.locationManager.location ?? self.lastKnownLocation {
                    self.saveHomeCoordinate(loc.coordinate)
                    self.lastKnownDistance = 0.0
                    self.isInHomeArea = true
                    self.isEnabled = true
                    completion(true, String(format: "已鎖定居家經緯度 (%.4f, %.4f)，半徑 %.0fm", loc.coordinate.latitude, loc.coordinate.longitude, self.geofenceRadius))
                } else if self.homeGatewayMAC != nil {
                    self.isEnabled = true
                    self.isInHomeArea = true
                    completion(true, "已綁定目前居家網路閘道 (未取得經緯度，以網路作為定位錨點)")
                } else {
                    completion(false, "尚未取得定位座標，請確保已開啟 Mac 定位服務並稍後再試。")
                }
            }
        }
    }

    private func saveHomeCoordinate(_ coord: CLLocationCoordinate2D) {
        UserDefaults.standard.set(coord.latitude, forKey: homeLatKey)
        UserDefaults.standard.set(coord.longitude, forKey: homeLonKey)
        mijiaLog("[Location] 居家座標已儲存: \(coord.latitude), \(coord.longitude)")
    }

    func clearHomeLocation() {
        UserDefaults.standard.removeObject(forKey: homeLatKey)
        UserDefaults.standard.removeObject(forKey: homeLonKey)
        UserDefaults.standard.removeObject(forKey: homeGatewayMACKey)
        UserDefaults.standard.removeObject(forKey: homeGatewayIPKey)
        isEnabled = false
        isInHomeArea = true
        lastKnownDistance = nil
        bluetoothManager?.resume()
        mijiaLog("[Location] 已清除居家位置設定")
    }

    // MARK: - 網路狀態監控 (NWPathMonitor)
    private func startNetworkMonitoring() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)
        self.pathMonitor = monitor
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        guard isEnabled else { return }
        checkCurrentStatus()
    }

    // MARK: - 綜合狀態檢查 (GPS 地理圍欄 + 網路閘道)
    func checkCurrentStatus() {
        guard isEnabled, hasHomeLocation else {
            if !isInHomeArea {
                isInHomeArea = true
                bluetoothManager?.resume()
            }
            return
        }

        // 1. 優先檢查是否連在居家網路閘道上
        let gateway = getCurrentGatewayInfo()
        if let homeMAC = homeGatewayMAC, let currentMAC = gateway.mac, homeMAC == currentMAC {
            updateHomeState(isHome: true, reason: "連線至居家網路閘道 (\(currentMAC))")
            return
        }

        // 2. 檢查 CoreLocation 經緯度距離
        checkCurrentLocationDistance()
    }

    private func checkCurrentLocationDistance() {
        guard let homeCoord = homeCoordinate else { return }
        guard let currentLoc = locationManager.location ?? lastKnownLocation else { return }

        let homeLoc = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        let distance = currentLoc.distance(from: homeLoc)
        self.lastKnownDistance = distance

        let isWithin = distance <= geofenceRadius
        let reason = isWithin ? String(format: "已在居家範圍內 (距離約 %.0fm)", distance) : String(format: "已超出居家範圍 (距離約 %.0fm，半徑 %.0fm)", distance, geofenceRadius)
        updateHomeState(isHome: isWithin, reason: reason)
    }

    private func updateHomeState(isHome: Bool, reason: String) {
        if isHome && !isInHomeArea {
            isInHomeArea = true
            mijiaLog("[LocationGatekeeper] 狀態切換 -> 在家: \(reason)")
            bluetoothManager?.resume()
            delegate?.locationGatekeeperDidChangeState(isHome: true, reason: reason)
        } else if !isHome && isInHomeArea {
            isInHomeArea = false
            mijiaLog("[LocationGatekeeper] 狀態切換 -> 離家: \(reason)")
            bluetoothManager?.suspend(reason: reason)
            delegate?.locationGatekeeperDidChangeState(isHome: false, reason: reason)
        }
    }

    // MARK: - 輔助工具：獲取 Gateway IP 與 MAC
    func getCurrentGatewayInfo() -> (ip: String?, mac: String?) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["get", "default"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var gatewayIP: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gatewayIP = trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard let ip = gatewayIP else { return (nil, nil) }

        // 使用 arp 取得 MAC
        let arpPipe = Pipe()
        let arpProcess = Process()
        arpProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        arpProcess.arguments = ["-n", ip]
        arpProcess.standardOutput = arpPipe
        try? arpProcess.run()
        arpProcess.waitUntilExit()

        let arpData = arpPipe.fileHandleForReading.readDataToEndOfFile()
        guard let arpOutput = String(data: arpData, encoding: .utf8) else { return (ip, nil) }

        let parts = arpOutput.components(separatedBy: " ")
        if let atIdx = parts.firstIndex(of: "at"), atIdx + 1 < parts.count {
            let mac = parts[atIdx + 1]
            if mac.contains(":") {
                return (ip, mac.lowercased())
            }
        }

        return (ip, nil)
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        self.lastKnownLocation = loc
        if isEnabled {
            checkCurrentLocationDistance()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        mijiaLog("[Location] 定位讀取失敗: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if #available(macOS 11.0, *) {
            mijiaLog("[Location] 定位授權狀態: \(manager.authorizationStatus.rawValue)")
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized {
                manager.startUpdatingLocation()
            }
        }
    }
}
