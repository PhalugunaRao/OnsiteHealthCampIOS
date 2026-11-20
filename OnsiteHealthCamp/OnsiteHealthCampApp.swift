import SwiftUI

@main
struct OnsiteHealthCampApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainer()
                .ignoresSafeArea(.keyboard) // WKWebView already resizes for the keyboard itself
        }
    }
}

private struct WebContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
