# Security Policy

## Supported Versions

Only the latest published version of this project receives security updates.

## Reporting a Vulnerability

Please **do not** open a public issue for suspected security vulnerabilities.

Instead, please use one of the following channels:

1. **GitHub Security Advisories** (preferred): open a private security advisory for this repository.
2. **Email**: contact the maintainer listed in `LICENSE`.

When reporting, include:

- A clear description of the issue and potential impact
- Steps to reproduce or a proof of concept
- Any relevant logs (please redact tokens / secrets)
- Suggested fix or mitigation (if known)

You should receive an acknowledgement within **3 business days**.

## Scope

This repository contains a macOS menubar app (Swift/SwiftUI/AppKit) that monitors **Copilot Premium Requests** usage and displays:

- Budget usage percent (user-configured budget with warn/danger thresholds)
- Included premium requests usage (based on a selected Copilot plan or manual override)
- Diagnostics and token troubleshooting actions
- Optional local notifications

### Network Access

The app performs outbound requests only to GitHub endpoints used to fetch authentication and billing usage data, including:

- `https://api.github.com/user`
- `https://api.github.com/users/{username}/settings/billing/usage?year=YYYY&month=M`

By default, the app does not send data to any third-party services.

### Data Storage

The app stores:

- **Personal Access Token (PAT)** in **macOS Keychain** (via the app’s Keychain storage)
- Preferences and display settings in **UserDefaults** (local only)
- In-memory diagnostics/events used for troubleshooting during runtime

The app is designed to avoid storing tokens in plaintext preferences.

### Telemetry

No telemetry or analytics are collected or transmitted by this app.

## Security Notes / Best Practices

- Treat GitHub tokens as sensitive and avoid pasting them into issue text, screenshots, or logs.
- Prefer GitHub fine-grained tokens when possible and grant the minimum required permissions.
- If you suspect a token has been exposed, revoke it immediately in GitHub settings and replace it.

## Non-Security Bugs

For regular bugs or feature requests, please open a normal GitHub issue.