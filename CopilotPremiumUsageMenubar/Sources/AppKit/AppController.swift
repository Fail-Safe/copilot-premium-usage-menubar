import AppKit
import Foundation
import SwiftUI
import UserNotifications

import CopilotPremiumUsageMenubarCore

/// Bridges `AppModel` (fetching, Keychain, notifications, computation) to SwiftUI-friendly bindings
/// and provides side-effectful actions (refresh, prompt token, open URLs, quit).
///
/// This is intended to be injected into SwiftUI as an `EnvironmentObject`.
@MainActor
final class AppController: ObservableObject {

	// MARK: - Troubleshooting

	@Published private(set) var lastTokenTestResultMessage: String?

	// MARK: - Published state (UI binds to these)

	@Published private(set) var viewState: UsageViewState?
	@Published private(set) var isRefreshing: Bool = false
	@Published private(set) var manualRefreshCooldownRemainingSeconds: Int = 0
	@Published private(set) var canManuallyRefresh: Bool = true
	@Published private(set) var nextAllowedAutoRefreshAt: Date?
	@Published private(set) var lastErrorMessage: String?
	@Published private(set) var hasToken: Bool = false
	@Published private(set) var tokenHint: String?

	@Published private(set) var diagnostics: [AppModel.DiagnosticEvent] = []

	// MARK: - Included limit source (for UI)

	@Published private(set) var includedLimitSourceLabel: String?

	// MARK: - Callbacks

	/// Called whenever `viewState` changes (used to push into `StatusBarController`).
	var onViewStateChanged: ((UsageViewState?) -> Void)?

	// MARK: - Dependencies

	private let model: AppModel
	private let preferences: Preferences

	// MARK: - Refresh behavior

	/// When the popover opens, a refresh can be performed if data is missing/stale.
	private let refreshIfStaleAfterSeconds: TimeInterval

	// MARK: - Init

	init(
		model: AppModel,
		preferences: Preferences = .shared,
		refreshIfStaleAfterSeconds: TimeInterval = 5 * 60
	) {
		self.model = model
		self.preferences = preferences
		self.refreshIfStaleAfterSeconds = refreshIfStaleAfterSeconds

		// Seed immediately
		syncFromModel()

		// Subscribe to model changes (no polling).
		//
		// AppModel is @MainActor and publishes state via closure hooks; AppController binds those
		// to its own @Published properties and forwards changes to the status bar host.
		model.onDidChange = { [weak self] in
			guard let self else { return }
			self.syncFromModel()
		}
	}

	// MARK: - Public API (used by PopoverView / UI)

	func refreshIfStale() {
		// If we have no refresh timestamp, refresh right away.
		guard let last = model.lastRefreshAt else {
			refreshNow()
			return
		}

		// If the data is stale enough, refresh.
		if Date().timeIntervalSince(last) > refreshIfStaleAfterSeconds {
			refreshNow()
		}
	}

	func refreshNow() {
		model.refreshNow()
	}

	/// One-click token test for troubleshooting:
	/// - Calls GitHub `/user` via `AppModel.testToken()`
	/// - Updates `lastTokenTestResultMessage` with a human-readable result
	/// - Appends to diagnostics via `AppModel`
	///
	/// Important: run the network call off the MainActor so the UI stays responsive
	/// and so we don't accidentally block the UI event loop in `.app` mode.
	func testTokenNow() {
		model.appendDiagnostic(.info("testTokenNow(): entered"))
		// Immediate feedback so the user sees *something* even if the request takes time or fails early.
		guard hasToken else {
			model.appendDiagnostic(.warn("testTokenNow(): aborted (hasToken == false)"))
			lastTokenTestResultMessage = "Token test failed: No token set."
			syncFromModel()
			return
		}

		lastTokenTestResultMessage = "Testing token…"
		model.appendDiagnostic(.info("Token test initiated"))
		syncFromModel()

		Task.detached(priority: .userInitiated) { [model] in
			await MainActor.run {
				model.appendDiagnostic(.info("testTokenNow(): detached task started"))
			}

			let result = await model.testToken()

			await MainActor.run { [weak self] in
				guard let self else { return }
				self.model.appendDiagnostic(.info("testTokenNow(): model.testToken() returned"))
				self.model.appendDiagnostic(.info("testTokenNow(): updating UI on MainActor"))

				switch result {
				case .success(let login):
					self.lastTokenTestResultMessage = "Token OK (as \(login))."
				case .failure(let error):
					self.lastTokenTestResultMessage = "Token test failed: \(error.localizedDescription)"
				}

				// Ensure UI reflects any diagnostics/events emitted by the model during the test.
				self.syncFromModel()
			}
		}
	}

	func restartAutoRefresh() {
		model.startAutoRefresh()
	}

	func recomputeViewState() {
		// The view state is based on fetched summary + preferences.
		// For simplicity, we just trigger a refresh if we already have any state.
		if model.state != nil {
			model.refreshNow()
		} else {
			syncFromModel()
		}
	}

	func updateMenubarTitle() {
		// StatusBarController is fed via `onViewStateChanged`, so syncing is enough.
		syncFromModel()
	}

	func setNotificationsEnabled(_ enabled: Bool) {
		// When enabling notifications, request permission.
		// The model itself checks authorization before posting.
		guard enabled else { return }

		// Running from `swift run` / SwiftPM build output is not a real app bundle, and
		// UNUserNotificationCenter can crash with:
		// "bundleProxyForCurrentProcess is nil"
		//
		// Only attempt to request authorization when we are running from a proper
		// app bundle (`.../*.app/Contents/...`).
		let bundleURL = Bundle.main.bundleURL
		let path = bundleURL.path
		guard path.contains(".app/") else {
			return
		}

		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.alert, .sound]) { _, _ in
			// No-op: the model will handle posting behavior based on authorization.
		}
	}

	func promptSetToken() {
		let alert = NSAlert()
		alert.messageText = "Set GitHub Token"
		alert.informativeText = "Paste a GitHub Personal Access Token (PAT) that can read billing usage. The token will be stored securely in Keychain."
		alert.alertStyle = .informational

		let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
		field.placeholderString = "ghp_…"
		alert.accessoryView = field

		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")

		let response = alert.runModal()
		guard response == .alertFirstButtonReturn else { return }

		let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		model.setToken(token)

		// Refresh immediately after saving.
		model.refreshNow()

		syncFromModel()
	}

	func clearToken() {
		model.clearToken()
		syncFromModel()
	}

	func openGitHubBudgetsPage() {
		guard let url = URL(string: "https://github.com/settings/billing/budgets") else { return }
		NSWorkspace.shared.open(url)
	}

	func quit() {
		NSApplication.shared.terminate(nil)
	}

	// MARK: - Internal wiring

	private func syncFromModel() {
		let didChangeState = (viewState != model.state)

		viewState = model.state
		isRefreshing = model.isRefreshing
		manualRefreshCooldownRemainingSeconds = model.manualRefreshCooldownRemainingSeconds
		canManuallyRefresh = model.canManuallyRefresh
		nextAllowedAutoRefreshAt = model.nextAllowedAutoRefreshAt
		lastErrorMessage = model.lastError
		diagnostics = model.diagnostics
		hasToken = model.hasToken

		// Included limit source label (mirrors VS Code panel hint text)
		includedLimitSourceLabel = model.includedLimitSourceLabel

		tokenHint = hasToken ? "Stored in Keychain" : "Set via Actions → More"

		// Clear token-test message when token is missing (prevents stale OK/fail messages).
		if !hasToken {
			lastTokenTestResultMessage = nil
		}

		// Notify status bar host if state changed (avoid extra updates).
		if didChangeState {
			onViewStateChanged?(viewState)
		}
	}
}
