# Copilot Premium Usage Menubar (macOS)

## Disclaimer

Not affiliated with or endorsed by GitHub. “GitHub” and “Copilot” are trademarks of their respective owners.

## License

MIT — see `../../LICENSE`.

This repository contains two ways to run the app:

1) **SwiftPM package** (`CopilotPremiumUsageMenubar/`)
   - Contains the core library + AppKit/SwiftUI menubar UI
   - Includes a SwiftPM executable entrypoint (`Sources/App/main.swift`) for development

2) **Xcode wrapper app** (`CopilotPremiumUsageMenubarAppWrapper/`)
   - A conventional Xcode `.app` project (assets, signing, packaging)
   - Calls into the SwiftPM `CopilotPremiumUsageMenubarAppKit` library to run the menubar app

### Which should you run?

For day-to-day usage, prefer the **wrapper `.app`** so you get the most “normal macOS app bundle” behavior (bundle identifier, version/build metadata, and resource handling).

You *can* run the SwiftPM executable for development, but some macOS behaviors work best from a full `.app`.

### Info.plist (SwiftPM resources)

This package includes an `Info.plist` at:

- `Resources/Info.plist`

It provides bundle metadata such as `CFBundleIdentifier` and sets `LSUIElement = true` (menubar-only).

Note: when running via the wrapper `.app`, the wrapper’s app bundle metadata is what macOS primarily uses.

This directory contains a small macOS menubar utility that monitors GitHub Copilot premium requests usage and displays:

- Budget usage percent (with warn/danger thresholds)
- Included premium requests usage (based on a user-selected Copilot plan or custom override)
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

it typically means the running process does not have a valid bundle identity (i.e., you’re not running as a normal `.app` bundle, or the bundle metadata is missing).

This repo includes `Resources/Info.plist` for SwiftPM builds, and the wrapper `.app` also provides bundle metadata. Prefer running the wrapper `.app` if you hit bundle-identifier-related issues.

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

You need a GitHub Personal Access Token (PAT) that can read the billing usage endpoint this app calls.

Create/manage tokens here:
- https://github.com/settings/personal-access-tokens

Recommended (least privilege) configuration (fine-grained PAT):
- **Repository access:** None
- **User permissions:** **Plan: Read**

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

This SwiftPM package includes resources via `Package.swift` (the `CopilotPremiumUsageMenubarAppKit` target processes `Resources/`).

Bundled resources include:
- `Resources/generated/copilot-plans.json`
- `Resources/Info.plist` (bundle metadata, including `LSUIElement`)

If you modify resources, rebuild the app to pick up the changes. If you’re running via the wrapper `.app`, rebuild the wrapper target so it embeds the updated SwiftPM resources.

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
