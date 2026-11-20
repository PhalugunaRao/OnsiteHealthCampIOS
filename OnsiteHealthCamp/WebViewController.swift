import AVFoundation
import CoreLocation
import UIKit
import WebKit

#if DEBUG
// Launch timing trace (debug builds only): milliseconds since the process started.
private func trace(_ event: String) {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let start = info.kp_proc.p_starttime
    let startSec = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    print(String(format: "[launch] %5.0f ms  %@", (Date().timeIntervalSince1970 - startSec) * 1000, event))
}
#else
private func trace(_ event: String) {}
#endif

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
    private var splashCover: UIView?

    // After this the splash adds a "Connecting…" spinner; it still waits for the page, because
    // removing it would only show a blank WebView while a slow network answers.
    private static let splashSlowSeconds: TimeInterval = 3
    // Page request timeout: on a dead network the offline page (with Retry) appears after this
    // instead of iOS's 60s default.
    private static let pageTimeoutSeconds: TimeInterval = 20

    override func viewDidLoad() {
        super.viewDidLoad()
        trace("viewDidLoad")
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
        content.add(self, name: "pageReady")
        #if DEBUG
        content.add(self, name: "apiTiming")
        #endif
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
        showSplashCover()

        // Back from Settings, or a system camera/location alert closed.
        NotificationCenter.default.addObserver(self, selector: #selector(notifyPermissions),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        // User changed Settings > Display & Brightness > Text Size while the app was open.
        NotificationCenter.default.addObserver(self, selector: #selector(applyTextScale),
                                               name: UIContentSizeCategory.didChangeNotification, object: nil)

        trace("webView.load")
        webView.load(URLRequest(url: webURL, timeoutInterval: Self.pageTimeoutSeconds))
    }

    // MARK: - Splash

    /// The launch screen (Info.plist UILaunchScreen) disappears as soon as this controller
    /// appears, long before the web page has loaded, so a kill-and-reopen showed a white
    /// WebView. Cover it with the same logo, laid out exactly like the launch screen (centred
    /// on the full screen, natural size), until the first screen has rendered
    /// (DOMContentLoaded via `pageReady`). On a slow network it adds "Connecting…" after 3s
    /// rather than revealing a blank WebView; a dead network ends in the offline page after
    /// the 20s request timeout, which also lifts the cover.
    private func showSplashCover() {
        let cover = UIView()
        cover.backgroundColor = UIColor(named: "LaunchBackground")
        let logo = UIImageView(image: UIImage(named: "LaunchLogo"))
        [cover, logo].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        cover.addSubview(logo)
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logo.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        splashCover = cover
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashSlowSeconds) { [weak self, weak cover, weak logo] in
            guard let self, let cover, let logo, self.splashCover === cover else { return }
            self.showConnecting(on: cover, below: logo)
        }
    }

    /// Slow network: say so under the logo instead of showing a blank screen.
    private func showConnecting(on cover: UIView, below logo: UIView) {
        trace("splash: slow network, showing Connecting…")
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = UILabel()
        label.text = "Connecting…"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = 8
        row.alpha = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            row.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 32),
        ])
        UIView.animate(withDuration: 0.25) { row.alpha = 1 }
    }

    private func hideSplashCover() {
        guard let cover = splashCover else { return }
        trace("splash hidden")
        splashCover = nil
        UIView.animate(withDuration: 0.25, animations: { cover.alpha = 0 }) { _ in cover.removeFromSuperview() }
    }

    private func installUserScripts(_ content: WKUserContentController) {
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: Self.geolocationShim,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.textScaleJS(),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.noFocusZoom,
                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.pageReadySignal,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if DEBUG
        content.addUserScript(WKUserScript(source: Self.apiTimingTrace,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
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
    // DOMContentLoaded = the app's scripts have run and React has rendered the first screen.
    // The splash drops here instead of at didFinish, which also waits for font files,
    // the favicon and images — seconds on a slow mobile network.
    private static let pageReadySignal = """
    document.addEventListener('DOMContentLoaded', function () {
      // Two frames later the rendered screen has been painted, so the fade reveals the page,
      // not a blank WebView.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          var t = performance.timing, s = t.navigationStart;
          window.webkit.messageHandlers.pageReady.postMessage({
            dns: t.domainLookupEnd - t.domainLookupStart, connect: t.connectEnd - t.connectStart,
            firstByte: t.responseStart - s, html: t.responseEnd - s,
            domContentLoaded: t.domContentLoadedEventEnd - s, painted: Math.round(performance.now()) });
        });
      });
    }, { once: true });
    """

    #if DEBUG
    // Debug only: 10s after launch, report every API call (fetch / XHR) the page made, with
    // start and duration, so a slow start can be split into app vs network vs backend.
    private static let apiTimingTrace = """
    setTimeout(function () {
      var calls = performance.getEntriesByType('resource')
        .filter(function (e) { return e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'fetch'; })
        .map(function (e) { return Math.round(e.startTime) + 'ms +' + Math.round(e.duration) + 'ms ' + e.name.split('?')[0]; });
      window.webkit.messageHandlers.apiTiming.postMessage(calls);
    }, 10000);
    """
    #endif

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
        case "apiTiming":
            (message.body as? [String] ?? []).forEach { trace("api " + $0) }
        case "pageReady":
            trace("pageReady (rendered + painted) \(message.body)")
            hideSplashCover()
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        trace("didStartProvisionalNavigation")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        trace("didCommit (first byte of HTML)")
    }

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

    // Fallback for pages without the DOMContentLoaded signal (offline page, other hosts).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        trace("didFinish (all resources loaded)")
        hideSplashCover()
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
