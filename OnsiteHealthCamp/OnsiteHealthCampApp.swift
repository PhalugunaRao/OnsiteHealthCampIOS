import SwiftUI

@main
struct OnsiteHealthCampApp: App {
    var body: some Scene {
        WindowGroup {
            // Fill the whole screen so the status-bar / home-indicator strips show the
            // controller's header colour, not SwiftUI's default (black in dark mode).
            // The WebView itself stays pinned to the safe area; WKWebView handles the keyboard.
            WebContainer()
                .ignoresSafeArea()
        }
    }
}

private struct WebContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
