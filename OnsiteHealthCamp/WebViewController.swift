import AVFoundation
import CoreLocation
import UIKit
import WebKit

// Which site loads: AppConfig.swift.
private let webURL = AppConfig.webURL

/// One WKWebView loading the OnsiteApt web app.
/// - Camera / file upload: WKWebView handles <input type="file"> natively
///   (capture="environment" opens the camera; image+PDF shows Photo Library / Camera / Files).
/// - Location: navigator.geolocation is replaced by a shim answered from CoreLocation, so there
///   is one prompt (the app's), asked only when the page first needs a fix, and denials are exact.
/// - Bridge (see OnsiteApt src/native.js): getPermissions() → status, openSettings(),
///   plus an 'onsite:permissions' event pushed whenever status may have changed.
/// Permissions are only asked when the page needs them, never at launch.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, WKScriptMessageHandlerWithReply, CLLocationManagerDelegate {

    private var webView: WKWebView!
    private let locationManager = CLLocationManager()
    private var pendingFixes: [Int] = [] // shim request ids waiting for CoreLocation

    override func viewDidLoad() {
        super.viewDidLoad()
        // Fills the status-bar / home-indicator strips; matches the web header (--n-50 #F9FAFB).
        view.backgroundColor = UIColor(red: 0xF9 / 255, green: 0xFA / 255, blue: 0xFB / 255, alpha: 1)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent localStorage (X-AGENT-KEY login)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        config.applicationNameForUserAgent = "Mobile/15E148 OnsiteHealthCamp-iOS/\(version)"

        // ponytail: handlers retain self; this controller lives as long as the app.
        let content = config.userContentController
        installUserScripts(content)
        content.add(self, name: "geolocation")
        content.add(self, name: "openSettings")
        content.addScriptMessageHandler(self, contentWorld: .page, name: "getPermissions")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // ponytail: no pull-to-refresh — an accidental reload drops photos not yet uploaded.
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true } // Safari > Develop
        #endif

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safe.topAnchor),
            webView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])

        // Back from Settings, or a system camera/location alert closed.
        NotificationCenter.default.addObserver(self, selector: #selector(notifyPermissions),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        // User changed Settings > Display & Brightness > Text Size while the app was open.
        NotificationCenter.default.addObserver(self, selector: #selector(applyTextScale),
                                               name: UIContentSizeCategory.didChangeNotification, object: nil)

        webView.load(URLRequest(url: webURL))
    }

    private func installUserScripts(_ content: WKUserContentController) {
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: Self.geolocationShim,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.textScaleJS(),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.noFocusZoom,
                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    // MARK: - Text size

    // WKWebView ignores Dynamic Type. Scale page text by the user's Text Size setting,
    // never below the web design, capped so fixed-size tiles don't overflow.
    // ponytail: 130% is where 10-11px labels in fixed tiles start to wrap; raise after a layout pass.
    private static func textScaleJS() -> String {
        let percent = min(max(Int(UIFontMetrics.default.scaledValue(for: 100).rounded()), 100), 130)
        return "document.documentElement.style.webkitTextSizeAdjust = '\(percent)%';"
    }

    @objc private func applyTextScale() {
        installUserScripts(webView.configuration.userContentController) // future reloads
        webView.evaluateJavaScript(Self.textScaleJS()) // current page
    }

    // iOS zooms the page when an input under 16px gets focus and stays zoomed.
    // maximum-scale=1 stops that inside the app only; the website itself is unchanged.
    private static let noFocusZoom = """
    (function () {
      var m = document.querySelector('meta[name=viewport]');
      if (m && m.content.indexOf('maximum-scale') < 0) m.content += ', maximum-scale=1';
    })();
    """

    private func isAppURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == webURL.host
    }

    private func isAppOrigin(_ frame: WKFrameInfo) -> Bool {
        frame.securityOrigin.protocol == "https" && frame.securityOrigin.host == webURL.host
    }

    // MARK: - Permission status bridge

    private func permissions(_ done: @escaping ([String: Any]) -> Void) {
        let location: String
        switch locationManager.authorizationStatus {
        case .notDetermined: location = "prompt"
        case .denied, .restricted: location = "blocked" // iOS never re-asks
        default: location = locationManager.accuracyAuthorization == .reducedAccuracy ? "approximate" : "granted"
        }
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: camera = "prompt"
        case .authorized: camera = "granted"
        default: camera = "blocked"
        }
        // locationServicesEnabled() blocks; Apple warns against calling it on the main thread.
        DispatchQueue.global().async {
            let services = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                done(["platform": "ios", "location": location, "locationServices": services, "camera": camera])
            }
        }
    }

    @objc private func notifyPermissions() {
        guard let url = webView.url, isAppURL(url) else { return }
        permissions { [weak self] status in
            guard let json = Self.json(status) else { return }
            self?.webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('onsite:permissions',{detail:\(json)}))")
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // getPermissions: answered as a Promise in the page.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard isAppOrigin(message.frameInfo) else { return replyHandler(nil, "forbidden") }
        permissions { replyHandler($0, nil) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isAppOrigin(message.frameInfo) else { return }
        switch message.name {
        case "openSettings":
            openSettings() // iOS can only open the app's own Settings page
        case "geolocation":
            guard let body = message.body as? [String: Any], let id = body["id"] as? Int else { return }
            let maximumAge = (body["maximumAge"] as? Double) ?? 0
            requestFix(id: id, maximumAge: maximumAge)
        default:
            break
        }
    }

    // MARK: - Native geolocation for the page

    private func requestFix(id: Int, maximumAge: Double) {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            replyFix(id, error: (1, "User denied Geolocation"))
        case .notDetermined:
            pendingFixes.append(id)
            if pendingFixes.count == 1 { askLocation() } // first real need: ask now, once
        default:
            if let last = locationManager.location, maximumAge > 0,
               -last.timestamp.timeIntervalSinceNow * 1000 <= maximumAge {
                return replyFix(id, location: last)
            }
            pendingFixes.append(id)
            locationManager.requestLocation()
        }
    }

    private func replyFix(_ id: Int, location: CLLocation? = nil, error: (Int, String)? = nil) {
        let payload: [String: Any]
        if let location {
            payload = ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                       "accuracy": location.horizontalAccuracy,
                       "timestamp": location.timestamp.timeIntervalSince1970 * 1000]
        } else {
            payload = ["code": error?.0 ?? 2, "message": error?.1 ?? "Position unavailable"]
        }
        guard let json = Self.json(payload) else { return }
        webView.evaluateJavaScript("window.__onsiteGeo && window.__onsiteGeo(\(id), \(location != nil), \(json))")
    }

    private func flushFixes(location: CLLocation? = nil, error: (Int, String)? = nil) {
        let ids = pendingFixes
        pendingFixes = []
        ids.forEach { replyFix($0, location: location, error: error) }
    }

    // Granted before but undetermined now means the user picked "Allow Once", which iOS
    // drops when the app is killed, so it asks on every launch. Apps cannot remove that
    // button; say which one stops the repeat before the system alert appears.
    private static let grantedBeforeKey = "locationGrantedBefore"

    private func askLocation() {
        guard UserDefaults.standard.bool(forKey: Self.grantedBeforeKey), presentedViewController == nil else {
            return locationManager.requestWhenInUseAuthorization()
        }
        let alert = UIAlertController(
            title: "Location permission",
            message: "To stop being asked every time you open the app, choose \u{201C}Allow While Using App\u{201D} on the next screen.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            self?.locationManager.requestWhenInUseAuthorization()
        })
        present(alert, animated: true)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) {
            UserDefaults.standard.set(true, forKey: Self.grantedBeforeKey)
        }
        notifyPermissions()
        guard !pendingFixes.isEmpty else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: flushFixes(error: (1, "User denied Geolocation"))
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { flushFixes(location: last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        flushFixes(error: denied ? (1, "User denied Geolocation") : (2, error.localizedDescription))
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Replaces navigator.geolocation on our host only. Timeouts are enforced here,
    // late native answers are dropped. ponytail: watchPosition unused by OnsiteApt — no-op.
    private static let geolocationShim = """
    (function () {
      if (location.protocol !== 'https:' || location.host !== '\(webURL.host!)') return;
      var pending = {}, seq = 0;
      var ERR = { PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
      window.__onsiteGeo = function (id, ok, p) {
        var cb = pending[id]; if (!cb) return; delete pending[id];
        if (ok) cb.s && cb.s({ timestamp: p.timestamp, coords: { latitude: p.latitude, longitude: p.longitude,
          accuracy: p.accuracy, altitude: null, altitudeAccuracy: null, heading: null, speed: null } });
        else cb.e && cb.e(Object.assign({ code: p.code, message: p.message }, ERR));
      };
      function getCurrentPosition(success, error, options) {
        var id = ++seq; options = options || {};
        pending[id] = { s: success, e: error };
        if (isFinite(options.timeout)) setTimeout(function () {
          window.__onsiteGeo(id, false, { code: 3, message: 'Timeout expired' });
        }, options.timeout);
        window.webkit.messageHandlers.geolocation.postMessage({ id: id, maximumAge: options.maximumAge || 0 });
      }
      Object.defineProperty(navigator, 'geolocation', { configurable: true, value: {
        getCurrentPosition: getCurrentPosition, watchPosition: function () { return 0; }, clearWatch: function () {} } });
    })();
    """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // Our app, in-page schemes, and subframes stay inside the WebView.
        if isAppURL(url) || ["about", "blob", "data"].contains(url.scheme) || action.targetFrame?.isMainFrame == false {
            return decisionHandler(.allow)
        }
        // tel:, mailto:, other hosts: hand to the system.
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showOffline(error)
    }

    // Web content process killed (memory pressure while the camera was open, etc.) — blank screen otherwise.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showOffline(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        // ponytail: plain offline page; the web app's own ping queue covers flaky network once loaded.
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding:48px 24px;color:#333">
        <h3>No connection</h3><p>Check internet and try again.</p>
        <a href="\(webURL.absoluteString)" style="display:inline-block;padding:12px 24px;background:#0266f9;color:#fff;border-radius:8px;text-decoration:none">Retry</a>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKUIDelegate

    // target="_blank" / window.open: same-site loads here, others go to the system.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isAppURL(url) { webView.load(action.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    // Without these, alert() and confirm() silently do nothing in WKWebView.
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
