# Copilot Premium Usage Menubar (macOS)

A macOS menubar utility inspired by the [**Copilot Premium Usage Monitor**](https://marketplace.visualstudio.com/items?itemName=fail-safe.copilot-premium-usage-monitor) VS Code extension:

- Fetches your **Copilot** spend and premium request counts via GitHub’s billing usage API.
- Displays a **single selected metric** in the macOS menubar (toggle: **Budget %** vs **Included %**).
- Shows a compact popover with both metrics and settings.
- Optionally sends background notifications when thresholds are crossed.

This repository contains the menubar app as a standalone project.

---

## Status

This project is functional and actively evolving. Core usage fetching, Keychain token storage, preferences, and the menubar/popup UI are implemented; remaining work is mostly polish, edge cases, and packaging/distribution.

---

## What’s implemented

### Core
- Minimal GitHub API client (`/user` and `/users/{username}/settings/billing/usage`) for **official endpoints**.
- Copilot usage summary:
  - `spendUsd` (sum of `netAmount` for `product == "copilot"`)
  - `totalQuantity` (sum of `quantity`)
  - `totalIncludedQuantity` (best-effort derived from `discountAmount / unitPrice`)
  - `totalOverageQuantity = max(0, totalQuantity - totalIncludedQuantity)`
- Keychain-backed token storage (PAT) with in-app token prompt and “Test Token” action.
- Preferences stored in `UserDefaults`:
  - refresh interval
  - warn/danger thresholds
  - notifications enabled
  - primary metric toggle
  - manual budget USD + “budget source” placeholder option
- Threshold notification evaluator that only fires on upward threshold crossings.

### UI/menubar plumbing
- Status bar controller and a SwiftUI popover UI.
- Menubar title updates based on settings (Budget % or Included %).
- Diagnostics/events view for troubleshooting refreshes and token issues.

---

## Big design note: “official GitHub budget dollar amount”

The VS Code extension in this repo uses a **user-configured budget** value (manual). It does not fetch “Budgets” from `https://github.com/settings/billing/budgets`.

This menubar app includes a **budget source mode** with:
- **Manual override** (works today)
- **GitHub (if available)** placeholder (not implemented unless we confirm a stable official API endpoint)

Until an official budgets endpoint is confirmed and implemented, the app will effectively use the manual budget value.

---

## Requirements

- macOS 13+ (as configured in the Swift package manifest)
- Xcode (recommended for running UI apps)
- A GitHub **Personal Access Token** (PAT) that can call the billing usage endpoint.
  - The VS Code extension’s README suggests **Plan: read-only** permission.
  - If you use a fine-grained PAT, ensure it can access the relevant billing usage scopes.

---

## Project layout

This repo contains two runnable pieces:

- `CopilotPremiumUsageMenubar/` (SwiftPM package)
  - `Package.swift`
  - `Sources/Core/` – domain logic and services
  - `Sources/AppKit/` – AppKit menubar host + SwiftUI popover + app controller/model
  - `Sources/App/` – SwiftPM executable entrypoint (`main.swift`) for development

- `CopilotPremiumUsageMenubarAppWrapper/` (Xcode wrapper app)
  - Conventional `.xcodeproj` used to run the menubar as a proper `.app` bundle (assets/signing/entitlements)

Key files (SwiftPM package):
- `Sources/Core/GitHubClient.swift` – minimal GitHub HTTP client
- `Sources/Core/UsageService.swift` – billing usage fetch + computation + view-state computation
- `Sources/Core/KeychainStore.swift` – secure token storage
- `Sources/Core/Preferences.swift` – UserDefaults-backed settings
- `Sources/Core/ThresholdNotifications.swift` – notification transition engine
- `Sources/AppKit/StatusBarController.swift` – menubar item + popover hosting
- `Sources/AppKit/PopoverView.swift` – SwiftUI popover UI
- `Sources/AppKit/AppController.swift` – UI-facing controller (actions, bindings, prompts)
- `Sources/AppKit/AppModel.swift` – refresh orchestration + notifications + diagnostics

---

## Building & Running

### Option A: run the SwiftPM package in Xcode (recommended for development)
1. Open Xcode.
2. Use **File → Open…**
3. Select `CopilotPremiumUsageMenubar/Package.swift`
4. Select the executable scheme:
   - `CopilotPremiumUsageMenubarApp`
5. Run.

This is the easiest way to iterate on the menubar UI and core logic.

### Option B: run the wrapper `.app` in Xcode (recommended for “real app” behavior)
The wrapper app runs the menubar utility as a proper `.app` bundle (best for notifications and any bundle-identifier-dependent behavior).

1. Open `CopilotPremiumUsageMenubarAppWrapper/CopilotPremiumUsageMenubarAppWrapper.xcodeproj`
2. Select the scheme:
   - `CopilotPremiumUsageMenubarAppWrapper`
3. Run.

### Option C: build/run from CLI (development)
You can build the Swift package from Terminal. Running the menubar app via `swift run` is supported for development, but some macOS behaviors (notably notifications) work best when launched as a proper `.app` bundle via Xcode.

If you just want to ensure code compiles:
- `swift build`

---

## First-run checklist (dev)

1. Launch the app (you should see a “Copilot …%” item in the menubar).
2. Open the popover and set your token (Actions → More → Set / Update Token…).
3. Set a manual budget in USD.
4. Hit Refresh.
5. Toggle Menubar metric between “Budget %” and “Included %”.
6. Optionally enable notifications (macOS will request permission).

---

## TODO / Known gaps (expected for skeleton state)

- Continue UI/UX polish (copy, layout, disabled states, error presentation).
- Harden edge cases (missing billing data, rate limits, token scope issues).
- Notarization/signing and GitHub Releases packaging (DMG/ZIP) for distribution.
- Decide whether to persist the last successful summary to show immediately on launch.
- Decide whether to support GHES base URL configuration.
- Notarization/signing and GitHub Releases packaging (DMG/ZIP) for distribution.

---

## Security notes

- Tokens are stored in macOS Keychain (not in plaintext preferences).
- No telemetry is included by design.
- Network traffic should only go to `https://api.github.com` unless you add support for GHES.

---

## License

MIT — see `LICENSE`.

---

## Contributing

For now:
- Keep the core logic in `Sources/Core` as dependency-free as possible.
- Keep UI in `Sources/AppKit`.
- Prefer explicit error handling; surface actionable errors in the popover UI.

## Disclaimer

Not affiliated with or endorsed by GitHub. “GitHub” and “Copilot” are trademarks of their respective owners.
