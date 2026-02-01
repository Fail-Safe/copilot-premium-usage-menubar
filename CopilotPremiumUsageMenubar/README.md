# Copilot Premium Usage Menubar (macOS)
# Copilot Premium Usage Menubar (macOS)

## License

MIT — see `../../LICENSE`.

This repository contains two ways to run the app:

1) **SwiftPM package** (`CopilotPremiumUsageMenubar/`)  
   - Contains the core library + AppKit/SwiftUI menubar UI
   - Includes a SwiftPM executable entrypoint (`Sources/App/main.swift`) for development

2) **Xcode wrapper app** (`CopilotPremiumUsageMenubarAppWrapper/`)  
   - A conventional Xcode `.app` project (assets, entitlements, signing)
   - Calls into the SwiftPM `CopilotPremiumUsageMenubarAppKit` library to run the menubar app

This app is intended to run as a **proper macOS `.app` bundle** for the best macOS behavior (notifications, bundle identifier, resources). If you run via `swift run`, you may see limitations.

If you see messages like “Cannot index window tabs due to missing main bundle identifier”, it typically means macOS cannot find a valid **bundle identifier** for the running process.

This project includes an `Info.plist` at:

- `Resources/Info.plist`

That file defines `CFBundleIdentifier` and also sets `LSUIElement` (menubar-only).


This directory contains a small macOS menubar utility that monitors GitHub Copilot Premium Request usage and displays:

- Budget usage percent (with warn/danger thresholds)
- Included premium request usage (based on a user-selected Copilot plan or custom override)
- Diagnostics and token troubleshooting actions
- Secure PAT storage via Keychain

The app is designed to be **menubar-only** (no Dock icon) by setting the activation policy to `.accessory` in `Sources/App/main.swift`.

---

## Requirements

- macOS 13+
- Xcode (recommended for building a proper `.app`)
  - SwiftPM *can* build the executable, but Xcode is the simplest way to produce and run a real app bundle.

---

## Open & Run in Xcode (recommended)

### Option A: Run the SwiftPM package in Xcode (recommended during development)

1. Install Xcode (from the Mac App Store or Apple Developer downloads).
2. Launch Xcode.
3. **File → Open…**
4. Select:
   - `CopilotPremiumUsageMenubar/Package.swift`
5. Wait for SwiftPM dependencies to resolve (this package is intentionally lightweight).
6. Choose scheme:
   - `CopilotPremiumUsageMenubarApp`
7. Run:
   - Press **⌘R**

### Option B: Run the wrapper `.app` in Xcode (recommended for “real app” behavior)

1. Open:
   - `CopilotPremiumUsageMenubarAppWrapper/CopilotPremiumUsageMenubarAppWrapper.xcodeproj`
2. Select scheme:
   - `CopilotPremiumUsageMenubarAppWrapper`
3. Run:
   - Press **⌘R**

This runs the app as a proper `.app` bundle under Xcode (with resources embedded and correct bundle behavior).

### Bundle identifier (important)

If you see:

- “Cannot index window tabs due to missing main bundle identifier”

then macOS is not seeing a valid `CFBundleIdentifier` for the current process.

This repository provides an explicit `Info.plist` at:

- `Resources/Info.plist`

which sets `CFBundleIdentifier` and `LSUIElement` to ensure the app is a menubar-only bundle with a stable identifier.

### Locate the built `.app`

In Xcode:
- **Product → Show Build Folder in Finder**
- Navigate to something like:
  - `Build/Products/Debug/CopilotPremiumUsageMenubarApp.app`

---

## Menubar-only behavior

This app is menubar-only in two ways:

1) `Info.plist` sets:
- `LSUIElement = true` (prevents Dock icon / app switcher presence)

2) `Sources/App/main.swift` sets:
- `NSApp.setActivationPolicy(.accessory)`
- `app.setActivationPolicy(.accessory)`

If you ever want a Dock icon for debugging, temporarily flip `LSUIElement` to `false` (or remove it) and/or change the activation policy to `.regular`.

---

## Token setup (PAT)

You need a GitHub token with access to read Enhanced Billing usage endpoints.

In the app:
- Open the menubar popover.
- **Actions → More → Set / Update Token…**
- Use **Test Token** to confirm authentication works.

The token is stored securely in the macOS Keychain (not in preferences).

---

## Included premium requests (Copilot plan)

GitHub does **not** provide a stable public API to fetch a personal Copilot subscription tier (Free/Pro/Pro+/etc).  
To compute “used / included limit”, the app mirrors the VS Code extension’s strategy:

Priority order:
1. **Included premium requests** (manual override; if > 0)
2. **Copilot plan** (selected built-in plan; bundled plan mapping JSON)
3. Otherwise the limit is treated as **not set** (the app can still show “used”, but not a percent of a monthly limit)

The plan mapping is bundled as a JSON resource under:
- `Resources/generated/copilot-plans.json`

---

## Bundle resources (plan JSON + Info.plist)

This SwiftPM package includes resources for the app target via `Package.swift`.

Bundled resources include:
- `Resources/generated/copilot-plans.json`
- `Resources/Info.plist` (bundle identifier + menubar-only `LSUIElement`)

If you modify either, rebuild the app to pick up the changes.

---

## Running via command line (development only)

You *can* run a SwiftPM-built binary, but it won’t behave like a full app bundle (and some system integrations can be limited).

From repo root:

- Build:
  - `cd CopilotPremiumUsageMenubar && swift build`

- Run:
  - `cd CopilotPremiumUsageMenubar && swift run CopilotPremiumUsageMenubarApp`

For day-to-day use and for a proper `.app`, use Xcode.

---

## Troubleshooting

### “Token OK but 0 usage”
- Confirm the billing endpoint returns Copilot items for your account:
  - `GET /users/{username}/settings/billing/usage?year=YYYY&month=M`
- The app filters for `product == "copilot"` and sums `quantity`.
- If the GitHub API returns data but the UI doesn’t match, open the Diagnostics section in the popover and review recent events.

### Notifications
Notifications require running from a proper app bundle (Xcode-run `.app`).  
If you’re running from SwiftPM output, certain notification calls may be skipped to avoid crashes.

---

## Project layout

- `Sources/Core/`
  - Core types and services: models, usage computations, REST client, preferences, etc.
- `Sources/App/`
  - AppKit menubar host and SwiftUI popover UI
- `Resources/`
  - Bundled resources, including the Copilot plan mapping
