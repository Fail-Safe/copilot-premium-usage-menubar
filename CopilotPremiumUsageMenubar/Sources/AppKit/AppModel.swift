import Foundation
import CopilotPremiumUsageMenubarCore
import UserNotifications

private let cpumTokenTestTimeoutSeconds: TimeInterval = 10

/// Cooldown applied to manual refresh actions (button-triggered), to avoid hammering the API.
private let cpumManualRefreshCooldownSeconds: TimeInterval = 15

/// Throttling/backoff behavior:
/// - Prefer server-provided retry windows (`Retry-After` / rate limit reset) when available.
/// - Otherwise fall back to exponential backoff.
/// - Cap waits to keep the app responsive.
private let cpumBackoffInitialSeconds: TimeInterval = 30
private let cpumBackoffMaxSeconds: TimeInterval = 60 * 60 // 1 hour

/// Top-level observable model for the menubar app.
///
/// Responsibilities:
/// - Loads token from Keychain
/// - Refreshes GitHub usage (manual + periodic)
/// - Computes `UsageViewState` for UI
/// - Evaluates and optionally posts threshold notifications
/// - Keeps lightweight diagnostics for UI (last refresh, last error, recent events)
///
/// Notes:
/// - This model intentionally does *not* know about AppKit UI plumbing (status item, popover).
///   Those should observe `AppModel` and render accordingly.
/// - Notifications permission prompting should be done on user action (e.g. when enabling
///   notifications in settings). This model will only post if enabled and authorized.
@MainActor
public final class AppModel: ObservableObject {

	/// Called whenever the model's observable state changes in a meaningful way.
	///
	/// This is intended to eliminate polling in the app layer. The `AppController` (or any other
	/// coordinator) can set this callback and update menubar/UI immediately.
	///
	/// Notes:
	/// - Invoked on the main actor.
	/// - Keep this lightweight; it can be called multiple times per refresh.
	public var onDidChange: (() -> Void)?

	/// If true, diagnostics will include extra detail about the raw billing response and filtering.
	/// Keep this off by default to avoid noise in normal use.
	private let verboseDiagnostics: Bool = true

	// MARK: - Included limit source (for UI parity with the VS Code extension)

	public enum IncludedLimitSource: String, Codable, Sendable {
		case customValue
		case copilotPlan
		case notSet
	}

	/// Tracks how the Included limit was determined for the current computed state.
	@Published public private(set) var includedLimitSource: IncludedLimitSource = .notSet {
		didSet { onDidChange?() }
	}

	/// Human-friendly label mirroring the VS Code panel wording.
	@Published public private(set) var includedLimitSourceLabel: String? {
		didSet { onDidChange?() }
	}

	// MARK: - Published state (UI binds to these)

	@Published public private(set) var isRefreshing: Bool = false {
		didSet { onDidChange?() }
	}

	/// Manual refresh button cooldown state (UI can disable the button and show a countdown).
	@Published public private(set) var manualRefreshCooldownRemainingSeconds: Int = 0 {
		didSet { onDidChange?() }
	}

	/// If set, auto-refresh (timer) should not attempt network calls until this time.
	/// Manual refresh is still allowed (but will likely fail fast if GitHub is still throttling).
	@Published public private(set) var nextAllowedAutoRefreshAt: Date? {
		didSet { onDidChange?() }
	}

	/// Convenience for UI: whether manual refresh is currently allowed.
	///
	/// Manual refresh is disabled while:
	/// - a refresh is already in progress
	/// - the manual refresh button cooldown is active
	/// - GitHub has indicated rate limiting (we respect this to be kind to the API)
	public var canManuallyRefresh: Bool {
		guard !isRefreshing else { return false }
		guard manualRefreshCooldownRemainingSeconds <= 0 else { return false }

		if let until = nextAllowedAutoRefreshAt, until > Date() {
			return false
		}

		return true
	}
	@Published public private(set) var state: UsageViewState? {
		didSet { onDidChange?() }
	}
	@Published public private(set) var lastRefreshAt: Date? {
		didSet { onDidChange?() }
	}
	@Published public private(set) var lastError: String? {
		didSet { onDidChange?() }
	}

	/// A rolling buffer of diagnostic events (for a simple "Details" view / debugging).
	@Published public private(set) var diagnostics: [DiagnosticEvent] = [] {
		didSet { onDidChange?() }
	}

	/// If you want UI to show "token missing" explicitly without trying a refresh.
	@Published public private(set) var hasToken: Bool = false {
		didSet { onDidChange?() }
	}


	// MARK: - Dependencies

	private let preferences: Preferences
	private let keychain: KeychainStore
	private let usageService: UsageService
	private let githubClient: GitHubClient

	// MARK: - Refresh scheduling

	private var refreshTimer: Timer?

	// MARK: - Manual refresh cooldown

	private var manualRefreshCooldownTimer: Timer?

	// MARK: - Throttling / backoff state

	/// Exponential backoff attempt counter for auto-refresh (timer) failures attributable to throttling.
	/// Reset on successful refresh.
	private var autoRefreshBackoffAttempt: Int = 0

	// MARK: - Notification state persistence

	/// Persist notification transition state in UserDefaults, but keep it separate from `Preferences` keys.
	private let notificationStateDefaultsKey = "cpum.notificationState.v1"


	// MARK: - Init

	public init(
		preferences: Preferences = .shared,
		keychain: KeychainStore = KeychainStore(),
		usageService: UsageService = UsageService(),
		githubClient: GitHubClient = GitHubClient()
	) {
		self.preferences = preferences
		self.keychain = keychain
		self.usageService = usageService
		self.githubClient = githubClient

		self.hasToken = (try? keychain.readToken())?.isEmpty == false

		// React to preference changes that affect refresh cadence.
		// (Optional) You can get fancier with Combine; this is simple/robust for small apps.
		startAutoRefresh()
	}

	deinit {
		refreshTimer?.invalidate()
		manualRefreshCooldownTimer?.invalidate()
	}


	// MARK: - Public API

	/// Force a refresh (manual user action).
	///
	/// This is rate-limited with a short cooldown to avoid excessive API calls.
	public func refreshNow() {
		guard canManuallyRefresh else {
			// Provide a helpful diagnostic for why the button is disabled.
			if isRefreshing {
				appendDiagnostic(.info("Manual refresh ignored: refresh already in progress"))
			} else if manualRefreshCooldownRemainingSeconds > 0 {
				appendDiagnostic(.info("Manual refresh ignored: cooldown (\(manualRefreshCooldownRemainingSeconds)s remaining)"))
			} else if let until = nextAllowedAutoRefreshAt, until > Date() {
				let remaining = Int(ceil(until.timeIntervalSinceNow))
				appendDiagnostic(.info("Manual refresh ignored: rate limited (\(remaining)s remaining)"))
			} else {
				appendDiagnostic(.info("Manual refresh ignored"))
			}
			return
		}

		// Start cooldown immediately to prevent rapid repeated clicks.
		startManualRefreshCooldown(seconds: cpumManualRefreshCooldownSeconds)

		Task { await refreshInternal(reason: .manual) }
	}

	/// Useful to call from app lifecycle hooks (e.g. on launch / wake).
	public func refreshIfPossible() {
		Task { await refreshInternal(reason: .startup) }
	}

	public func startAutoRefresh() {
		refreshTimer?.invalidate()

		let minutes = max(1, preferences.refreshIntervalMinutes)
		let interval = TimeInterval(minutes * 60)

		// Schedule on main run loop.
		let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			guard let self else { return }
			Task { await self.refreshInternal(reason: .timer) }
		}
		timer.tolerance = min(30, interval * 0.1) // be a good citizen
		refreshTimer = timer

		appendDiagnostic(.info("Auto-refresh scheduled every \(minutes) min"))
	}

	public func stopAutoRefresh() {
		refreshTimer?.invalidate()
		refreshTimer = nil
		appendDiagnostic(.info("Auto-refresh stopped"))
	}

	// MARK: - Manual refresh cooldown

	private func startManualRefreshCooldown(seconds: TimeInterval) {
		manualRefreshCooldownTimer?.invalidate()

		let total = max(0, Int(ceil(seconds)))
		manualRefreshCooldownRemainingSeconds = total

		guard total > 0 else { return }

		// Tick once per second on the main run loop.
		//
		// Timer callbacks are not actor-isolated, so hop explicitly to the main actor
		// before accessing/mutating @MainActor state.
		let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
			guard let self else {
				t.invalidate()
				return
			}

			Task { @MainActor in
				self.tickManualRefreshCooldown(timer: t)
			}
		}
		timer.tolerance = 0.2
		manualRefreshCooldownTimer = timer
	}

	@MainActor
	private func tickManualRefreshCooldown(timer: Timer) {
		let next = max(0, manualRefreshCooldownRemainingSeconds - 1)
		manualRefreshCooldownRemainingSeconds = next

		if next <= 0 {
			timer.invalidate()
			manualRefreshCooldownTimer = nil
		}
	}



	/// Save/update token in Keychain.
	/// Call this from your token entry UI.
	public func setToken(_ token: String) {
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		do {
			try keychain.writeToken(trimmed)
			hasToken = !trimmed.isEmpty
			appendDiagnostic(.info("Token saved to Keychain"))
		} catch {
			appendDiagnostic(.error("Failed saving token to Keychain: \(error)"))
			lastError = "Failed to save token."
		}
	}

	/// Clear token from Keychain.
	public func clearToken() {
		do {
			try keychain.deleteToken()
			hasToken = false
			appendDiagnostic(.info("Token deleted from Keychain"))
		} catch {
			appendDiagnostic(.error("Failed deleting token from Keychain: \(error)"))
			lastError = "Failed to clear token."
		}
	}

	/// Quick token validation (optional for UI "Test token" button).
	/// This calls `/user` and returns the login if successful.
	public func testToken() async -> Result<String, Error> {
		let start = Date()
		appendDiagnostic(.info("Token test started (GET /user)"))

		do {
			guard let token = try keychain.readToken(), !token.isEmpty else {
				appendDiagnostic(.warn("Token test aborted: no token set"))
				return .failure(NSError(domain: "CopilotPremiumUsageMenubar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No token set."]))
			}

			appendDiagnostic(.info("Token test: about to call GitHubClient.fetchViewer"))

			// Run the network call with an explicit timeout so it never appears to hang forever.
			let user: GitHubClient.User
			do {
				user = try await withThrowingTaskGroup(of: GitHubClient.User.self) { group in
					group.addTask {
						try await self.githubClient.fetchViewer(token: token)
					}
					group.addTask {
						try await Task.sleep(nanoseconds: UInt64(cpumTokenTestTimeoutSeconds * 1_000_000_000))
						throw NSError(
							domain: "CopilotPremiumUsageMenubar",
							code: 3,
							userInfo: [NSLocalizedDescriptionKey: "Token test timed out after \(Int(cpumTokenTestTimeoutSeconds)) seconds."]
						)
					}

					let result = try await group.next()!
					group.cancelAll()
					return result
				}
			} catch {
				let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
				appendDiagnostic(.error("Token test failed after \(elapsedMs)ms: \(error)"))
				return .failure(error)
			}

			let login = user.login ?? ""
			if login.isEmpty {
				let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
				appendDiagnostic(.warn("Token test returned empty login after \(elapsedMs)ms"))
				return .failure(NSError(domain: "CopilotPremiumUsageMenubar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Token worked but GitHub did not return a login."]))
			}

			let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
			appendDiagnostic(.info("Token test succeeded for \(login) (\(elapsedMs)ms)"))
			return .success(login)
		} catch {
			let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
			appendDiagnostic(.error("Token test failed after \(elapsedMs)ms: \(error)"))
			return .failure(error)
		}
	}




	// MARK: - Internals

	private enum RefreshReason: String {
		case startup
		case manual
		case timer
	}

	private func refreshInternal(reason: RefreshReason) async {
		guard !isRefreshing else { return }

		// If this is an auto-refresh tick and we are currently rate-limited, skip until allowed.
		if reason == .timer, let until = nextAllowedAutoRefreshAt, until > Date() {
			let remaining = Int(ceil(until.timeIntervalSinceNow))
			appendDiagnostic(.info("Auto-refresh skipped due to rate limiting (\(remaining)s remaining)"))
			return
		}

		isRefreshing = true
		defer { isRefreshing = false }

		let month = YearMonth.currentUTC()

		appendDiagnostic(.info("Refresh started (\(reason.rawValue)) for \(month.displayName)"))

		do {
			let token = try keychain.readToken()
			hasToken = (token?.isEmpty == false)

			guard let token, !token.isEmpty else {
				// Don’t treat as an error; show a clear state and skip network.
				lastError = "No GitHub token configured."
				state = nil
				lastRefreshAt = nil
				appendDiagnostic(.warn("Refresh skipped: token missing"))
				return
			}

			// Fetch usage summary (billing usage endpoint).
			//
			// NOTE: Use `GitHubClient` since it matches the real API field names
			// (e.g. `pricePerUnit` vs `unitPrice`) and the app should mirror the
			// VS Code extension logic.
			let viewer = try await githubClient.fetchViewer(token: token)
			let login = (viewer.login ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			guard !login.isEmpty else {
				throw NSError(
					domain: "CopilotPremiumUsageMenubar",
					code: 3,
					userInfo: [NSLocalizedDescriptionKey: "GitHub did not return a login for the authenticated user."]
				)
			}

			let summary = try await githubClient.fetchCopilotBillingUsage(username: login, token: token, month: month)

			// Success: clear rate-limit/backoff state for auto-refresh.
			nextAllowedAutoRefreshAt = nil
			autoRefreshBackoffAttempt = 0

			// Included limit selection (mirrors VS Code extension priority):
			//  1) includedPremiumRequestsOverride (if > 0)
			//  2) selectedPlanId -> plan mapping (bundled)
			//  3) otherwise: NOT SET (do NOT treat billing "included consumed" as the plan limit)
			let selectedPlanId = preferences.selectedPlanId.trimmingCharacters(in: .whitespacesAndNewlines)
			let overrideIncluded = max(0, preferences.includedPremiumRequestsOverride)

			var effectiveIncludedLimit = overrideIncluded

			if effectiveIncludedLimit > 0 {
				includedLimitSource = .customValue
				includedLimitSourceLabel = "Included limit: Custom value"
			} else if !selectedPlanId.isEmpty, let plan = CopilotPlanCatalog.findPlanBestEffort(id: selectedPlanId) {
				effectiveIncludedLimit = max(0, plan.includedPremiumRequestsPerMonth)
				includedLimitSource = .copilotPlan
				includedLimitSourceLabel = "Included limit: GitHub plan (\(plan.name))"

				// If the user hasn't overridden the price, adopt the bundled default price when available.
				if preferences.pricePerPremiumRequestOverride <= 0,
				   let bundledPrice = CopilotPlanCatalog.bundledPricePerPremiumRequestBestEffort() {
					preferences.pricePerPremiumRequestOverride = bundledPrice
				}
			} else {
				// No plan and no override: we can still show "included consumed" from billing,
				// but we cannot compute "used / plan limit" without a user-selected limit.
				includedLimitSource = .notSet
				includedLimitSourceLabel = "Included limit: Not set"
				effectiveIncludedLimit = 0
			}

			let prefs = UsagePreferences(
				refreshIntervalMinutes: preferences.refreshIntervalMinutes,
				warnAtPercent: Double(preferences.warnAtPercent),
				dangerAtPercent: Double(preferences.dangerAtPercent),
				notificationsEnabled: preferences.notificationsEnabled,
				primaryMetric: (preferences.primaryMetric == .includedPercent ? .includedPercent : .budgetPercent),
				budgetLimitSource: (preferences.budgetMode == .fetchFromGitHubIfAvailable ? .githubConfiguredBudget : .manualOverride),
				manualBudgetUsd: preferences.manualBudgetDollars,
				selectedPlanId: selectedPlanId.isEmpty ? nil : selectedPlanId,
				includedPremiumRequestsOverride: Double(effectiveIncludedLimit)
			)

			// Compute view state.
			let computed = usageService.computeViewState(
				month: month,
				summary: summary,
				preferences: prefs,
				lastRefreshAt: Date(),
				lastErrorMessage: nil
			)

			state = computed
			lastRefreshAt = Date()
			lastError = nil

			if verboseDiagnostics {
				appendDiagnostic(.info("Billing parsed for \(login): spend=$\(formatMoney(summary.spendUsd)), premiumRequests=\(summary.totalQuantity), discountDerivedIncludedConsumed=\(summary.totalIncludedQuantity), computedOverageFromDiscount=\(summary.totalOverageQuantity) (note: 'discountDerivedIncludedConsumed' is derived from billing discounts and is not your plan’s monthly included limit)"))
			} else {
				appendDiagnostic(.info("Refresh succeeded: spend=$\(formatMoney(summary.spendUsd)), premiumRequests=\(summary.totalQuantity) (note: plan limit is configured separately; billing does not reliably report included limit)"))
			}

			// Evaluate notifications (optional).
			await maybeNotify(for: computed, summary: summary, preferences: prefs)

		} catch let apiError as GitHubAPIError {
			// Keep last good `state` (if any) but mark error for UI.
			lastError = "\(apiError)"
			lastRefreshAt = Date()

			// If GitHub told us we are rate limited, respect it (especially for auto-refresh).
			switch apiError {
			case .rateLimited(let resetAt, let message, _):
				if reason == .timer {
					if let resetAt, resetAt > Date() {
						nextAllowedAutoRefreshAt = resetAt
						appendDiagnostic(.warn("Rate limited: deferring auto-refresh until \(resetAt)"))
					} else {
						// No reset provided: exponential backoff.
						autoRefreshBackoffAttempt = min(autoRefreshBackoffAttempt + 1, 10)
						let wait = min(cpumBackoffMaxSeconds, cpumBackoffInitialSeconds * pow(2.0, Double(autoRefreshBackoffAttempt - 1)))
						let until = Date().addingTimeInterval(wait)
						nextAllowedAutoRefreshAt = until
						appendDiagnostic(.warn("Rate limited: no reset provided; backing off auto-refresh for \(Int(wait))s"))
					}
				} else {
					appendDiagnostic(.warn("Rate limited on \(reason.rawValue) refresh: \(message ?? "GitHub asked to slow down.")"))
				}

			default:
				appendDiagnostic(.error("Refresh failed: \(apiError)"))
			}
		} catch {
			// Keep last good `state` (if any) but mark error for UI.
			lastError = "\(error)"
			lastRefreshAt = Date()
			appendDiagnostic(.error("Refresh failed: \(error)"))
		}
	}

	private func maybeNotify(for viewState: UsageViewState, summary: CopilotUsageSummary, preferences: UsagePreferences) async {
		guard preferences.notificationsEnabled else { return }

		let metricKind: ThresholdNotifications.MetricKind = {
			switch preferences.primaryMetric {
			case .budgetPercent: return .budgetPercent
			case .includedPercent: return .includedPercent
			}
		}()

		let percent: Double = {
			switch metricKind {
			case .budgetPercent: return viewState.budgetPercent
			case .includedPercent: return viewState.includedPercent
			}
		}()

		let warn = preferences.warnAtPercent > 0 ? Int(preferences.warnAtPercent) : nil
		let danger = preferences.dangerAtPercent > 0 ? Int(preferences.dangerAtPercent) : nil

		let detail: String? = {
			switch metricKind {
			case .budgetPercent:
				let budget = viewState.budgetUsd
				return "$\(formatMoney(viewState.spendUsd)) / $\(formatMoney(budget))"
			case .includedPercent:
				return "\(viewState.includedUsed) / \(viewState.includedTotal) requests"
			}
		}()

		let input = ThresholdNotifications.EvaluationInput(
			month: viewState.month,
			metricKind: metricKind,
			percent: percent,
			warnAtPercent: warn,
			dangerAtPercent: danger,
			notificationsEnabled: preferences.notificationsEnabled,
			label: "Copilot Premium Usage",
			detail: detail,
			now: Date()
		)

		let prevState = loadNotificationState()
		let result = ThresholdNotifications.evaluate(input: input, previousState: prevState)

		saveNotificationState(result.newState)

		guard result.shouldNotify,
			  let title = result.title,
			  let body = result.body
		else { return }

		// Only attempt to post if we're authorized. If not, keep silent (UI should guide the user).
		let center = UNUserNotificationCenter.current()
		let settings = await center.notificationSettings()
		guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
			appendDiagnostic(.warn("Notification suppressed: not authorized by system"))
			return
		}

		do {
			let identifier = ThresholdNotifications.notificationIdentifier(
				appPrefix: "cpum",
				month: viewState.month,
				metricKind: metricKind,
				level: result.notifyLevel
			)

			try await ThresholdNotifications.postUserNotification(
				center: center,
				identifier: identifier,
				title: title,
				body: body
			)

			appendDiagnostic(.info("Notification posted: \(title)"))
		} catch {
			appendDiagnostic(.error("Failed posting notification: \(error)"))
		}
	}


	// MARK: - Diagnostics

	public struct DiagnosticEvent: Identifiable, Codable, Equatable, Sendable {
		public enum Level: String, Codable, Sendable {
			case info
			case warn
			case error
		}

		public let id: UUID
		public let at: Date
		public let level: Level
		public let message: String

		public init(id: UUID = UUID(), at: Date = Date(), level: Level, message: String) {
			self.id = id
			self.at = at
			self.level = level
			self.message = message
		}

		public static func info(_ msg: String) -> DiagnosticEvent { .init(level: .info, message: msg) }
		public static func warn(_ msg: String) -> DiagnosticEvent { .init(level: .warn, message: msg) }
		public static func error(_ msg: String) -> DiagnosticEvent { .init(level: .error, message: msg) }
	}

	public func appendDiagnostic(_ event: DiagnosticEvent) {
		diagnostics.append(event)

		// Keep bounded.
		if diagnostics.count > 200 {
			diagnostics.removeFirst(diagnostics.count - 200)
		}

		// Ensure observers who aren't using Combine get notified promptly.
		onDidChange?()
	}

	private static func prettyJSONString(_ obj: Any) -> String? {
		guard JSONSerialization.isValidJSONObject(obj) else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
			  let s = String(data: data, encoding: .utf8) else {
			return nil
		}
		return s
	}


	// MARK: - Notification state persistence

	private func loadNotificationState() -> ThresholdNotifications.State? {
		guard let data = UserDefaults.standard.data(forKey: notificationStateDefaultsKey) else { return nil }
		do {
			return try JSONDecoder().decode(ThresholdNotifications.State.self, from: data)
		} catch {
			// If schema changes, just reset.
			appendDiagnostic(.warn("Failed decoding notification state; resetting. \(error)"))
			return nil
		}
	}

	private func saveNotificationState(_ state: ThresholdNotifications.State) {
		do {
			let data = try JSONEncoder().encode(state)
			UserDefaults.standard.set(data, forKey: notificationStateDefaultsKey)
		} catch {
			appendDiagnostic(.warn("Failed encoding notification state. \(error)"))
		}
	}


	// MARK: - Formatting helpers

	private func formatMoney(_ v: Double) -> String {
		let clamped = v.isFinite ? max(0, v) : 0
		return String(format: "%.2f", clamped)
	}
}
