import Foundation

// ┌───────────────────────────────────────────────────────────────┐
// │  WEB APP URLS — the only place to change which site loads.    │
// └───────────────────────────────────────────────────────────────┘
//
// Debug   (Xcode Run)                 -> testURL
// Release (Product > Archive / TestFlight / App Store) -> prodURL
//
// Rules:
//  - HTTPS only. Location and camera are refused on http:// pages.
//  - Host only, no trailing path. Camera, location and the permission bridge
//    are granted only to this host; any other host opens outside the app.
//  - Testing an OnsiteApt PR preview: change testURL to that PR's Amplify URL.
//  - Keep in sync with Android: app/src/main/java/com/ekincare/onsitehealthcamp/AppConfig.kt
enum AppConfig {
    private static let prodURL = "https://onsite-providers.ekincare.com"
    private static let testURL = "https://pr-13.d1fle6jimql6gu.amplifyapp.com"

    #if DEBUG
    static let webURL = URL(string: testURL)!
    #else
    static let webURL = URL(string: prodURL)!
    #endif
}
