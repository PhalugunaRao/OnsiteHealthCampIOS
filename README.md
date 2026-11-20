# OnsiteHealthCamp — iOS

iOS wrapper app for the OnsiteApt web app (onsite camp operations for phlebotomists).
A SwiftUI shell hosts one `WKWebView` that loads the web app; native code only covers
location, the permission bridge and a few WebView gaps.

## Requirements

- Xcode 16 or later (project uses folder-synchronised groups), iOS 15+ deployment target
- Apple Developer team for device builds (set to Aayuv Technologies, `ZQ528WW7JB`)

## Run

1. Open `OnsiteHealthCamp.xcodeproj`.
2. Signing & Capabilities → check **Team**.
3. Pick a simulator or a connected iPhone (Developer Mode on) and press Run.

New Swift files dropped into `OnsiteHealthCamp/` are picked up automatically.

## Which URL loads

**Only edit `OnsiteHealthCamp/AppConfig.swift`:**

| Configuration | URL |
|---|---|
| Debug (Xcode Run) | OnsiteApt PR preview (`https://pr-13.d1fle6jimql6gu.amplifyapp.com`) — change per PR being tested |
| Release (Archive / TestFlight) | Production `https://onsite-providers.ekincare.com` |

## What the native side does (`WebViewController.swift`)

- **Camera / file upload** — handled by WKWebView itself (`capture` opens the camera;
  image/PDF inputs offer Photo Library / Camera / Files). Only the usage strings are needed;
  they live in the target build settings (`INFOPLIST_KEY_NS*UsageDescription`).
- **Location** — `navigator.geolocation` is replaced on the app's host by a small shim
  answered from `CLLocationManager`, so there is one prompt (the app's), asked only when the
  page first needs a fix, and denials come back as the standard `PERMISSION_DENIED`.
  - Granted before but undetermined now ("Allow Once") → a short note to pick
    *Allow While Using App* before the system alert.
- **JS bridge** (only on the app's host):
  - `webkit.messageHandlers.getPermissions.postMessage(null)` → Promise of
    `{ platform, location, locationServices, camera }`
  - `webkit.messageHandlers.openSettings.postMessage(target)` → the app's Settings page
  - The app dispatches an `onsite:permissions` event when it becomes active and when
    location permission changes. Web side: `src/native.js` in OnsiteApt.
- **Text size** — page text follows Dynamic Type (Settings → Display & Brightness → Text
  Size), clamped 100–130%, live on change.
- **No input-focus zoom** — `maximum-scale=1` is appended to the page viewport inside the
  app only.
- Safe-area layout with bar colour matching the web header; swipe-back; `alert()` /
  `confirm()` as native alerts; external links, `tel:` and `mailto:` open outside the app;
  reload if the web process is killed; plain offline page with Retry; user agent gets
  `OnsiteHealthCamp-iOS/<version>`. No pull-to-refresh on purpose (would drop photos not
  yet uploaded).

## Debugging

Debug builds set `isInspectable` (iOS 16.4+): Safari → Develop → your device → the page.

## Distribution

This is an internal staff app; a pure WebView wrapper is likely to be rejected in public
App Store review (guideline 4.2). Use TestFlight or an Apple Business Manager custom app.
