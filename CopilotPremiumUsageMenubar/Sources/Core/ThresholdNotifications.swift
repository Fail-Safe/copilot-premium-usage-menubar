import Foundation
import UserNotifications

/// Helper for sending (optional) warn/danger notifications when usage crosses configured thresholds.
///
/// Design goals:
/// - Notify only on *transitions* across thresholds (avoid spam on every refresh).
/// - Keep state per-month (monthly billing resets).
/// - Provide a simple cooldown guard (optional) to avoid too-frequent alerts if the API data jitters.
/// - Work for both Budget % and Included % (user-selectable primary metric).
///
/// Notes:
/// - This module does not decide *what* the metric is (budget vs included). It receives the current
///   computed percentages and preferences and decides whether to notify.
/// - Callers should request notification permission when the user enables notifications in settings.
public enum ThresholdNotifications {
	// MARK: - Types

	public enum Level: Int, Codable, Sendable, CaseIterable {
		case none = 0
		case warn = 1
		case danger = 2
	}

	public enum MetricKind: String, Codable, Sendable, CaseIterable {
		case budgetPercent
		case includedPercent

		public var displayName: String {
			switch self {
			case .budgetPercent: return "Budget"
			case .includedPercent: return "Included"
			}
		}
	}

	/// Minimal info required to evaluate notifications for the current refresh tick.
	public struct EvaluationInput: Sendable {
		public var month: YearMonth

		/// Which metric we are evaluating thresholds against.
		public var metricKind: MetricKind

		/// Current percent [0, 100] for the selected metric.
		public var percent: Double

		/// Warn threshold, where nil means disabled.
		public var warnAtPercent: Int?

		/// Danger threshold, where nil means disabled.
		public var dangerAtPercent: Int?

		/// Whether notifications are enabled (user preference).
		public var notificationsEnabled: Bool

		/// Optional name to include in notifications (e.g., "Copilot Premium Requests").
		public var label: String

		/// Optional additional context to include (e.g., "$12.34 / $20.00" or "134 / 50").
		public var detail: String?

		/// The time of evaluation (defaults to now).
		public var now: Date

		public init(
			month: YearMonth,
			metricKind: MetricKind,
			percent: Double,
			warnAtPercent: Int?,
			dangerAtPercent: Int?,
			notificationsEnabled: Bool,
			label: String,
			detail: String? = nil,
			now: Date = Date()
		) {
			self.month = month
			self.metricKind = metricKind
			self.percent = percent
			self.warnAtPercent = warnAtPercent
			self.dangerAtPercent = dangerAtPercent
			self.notificationsEnabled = notificationsEnabled
			self.label = label
			self.detail = detail
			self.now = now
		}
	}

	/// Stored state for transition detection and cooldown.
	public struct State: Codable, Equatable, Sendable {
		public var month: YearMonth
		public var metricKind: MetricKind

		/// Last level we notified (or observed) for this month+metric.
		public var lastLevel: Level

		/// Last time we sent a notification (any level) for this month+metric.
		public var lastNotifyAt: Date?

		/// The last percent we evaluated (for debugging/diagnostics).
		public var lastPercent: Double?

		public init(month: YearMonth, metricKind: MetricKind, lastLevel: Level = .none, lastNotifyAt: Date? = nil, lastPercent: Double? = nil) {
			self.month = month
			self.metricKind = metricKind
			self.lastLevel = lastLevel
			self.lastNotifyAt = lastNotifyAt
			self.lastPercent = lastPercent
		}
	}

	/// Result of evaluating current usage against thresholds.
	public struct EvaluationResult: Sendable {
		public var newState: State
		public var shouldNotify: Bool
		public var notifyLevel: Level
		public var title: String?
		public var body: String?

		public init(newState: State, shouldNotify: Bool, notifyLevel: Level, title: String?, body: String?) {
			self.newState = newState
			self.shouldNotify = shouldNotify
			self.notifyLevel = notifyLevel
			self.title = title
			self.body = body
		}
	}

	// MARK: - Public API

	/// Decide whether a warn/danger notification should fire, based on threshold crossings.
	///
	/// - Parameters:
	///   - input: Current evaluation input.
	///   - previousState: Previously persisted state (if any). If nil, this function will create a baseline state and never notify on first evaluation.
	///   - minimumCooldownSeconds: Optional cooldown to prevent repeated alerts if values oscillate. Default is 6 hours.
	///
	/// - Returns: An `EvaluationResult` holding the updated state and any notification content.
	public static func evaluate(
		input: EvaluationInput,
		previousState: State?,
		minimumCooldownSeconds: TimeInterval = 6 * 60 * 60
	) -> EvaluationResult {
		// If notifications are disabled, just update state baseline and never notify.
		guard input.notificationsEnabled else {
			let next = baselineState(for: input, previousState: previousState)
			return EvaluationResult(newState: next, shouldNotify: false, notifyLevel: .none, title: nil, body: nil)
		}

		// If thresholds are not configured, do not notify.
		let warnAt = input.warnAtPercent.flatMap { $0 > 0 ? $0 : nil }
		let dangerAt = input.dangerAtPercent.flatMap { $0 > 0 ? $0 : nil }
		if warnAt == nil && dangerAt == nil {
			let next = baselineState(for: input, previousState: previousState)
			return EvaluationResult(newState: next, shouldNotify: false, notifyLevel: .none, title: nil, body: nil)
		}

		// Normalize thresholds: if both exist and warn > danger, treat danger as higher priority but keep ordering sane.
		let normalized = normalizeThresholds(warnAt: warnAt, dangerAt: dangerAt)
		let currentLevel = classifyLevel(percent: input.percent, warnAt: normalized.warnAt, dangerAt: normalized.dangerAt)

		// Establish baseline if this is the first time we see this month+metric.
		let prev = previousState
		let base = baselineState(for: input, previousState: prev)

		// If month or metric changed, treat as baseline and do not notify immediately.
		guard base.month == input.month, base.metricKind == input.metricKind else {
			let next = State(month: input.month, metricKind: input.metricKind, lastLevel: currentLevel, lastNotifyAt: nil, lastPercent: input.percent)
			return EvaluationResult(newState: next, shouldNotify: false, notifyLevel: .none, title: nil, body: nil)
		}

		// No transition upward: do not notify.
		let lastLevel = base.lastLevel
		if currentLevel.rawValue <= lastLevel.rawValue {
			let next = State(month: input.month, metricKind: input.metricKind, lastLevel: currentLevel, lastNotifyAt: base.lastNotifyAt, lastPercent: input.percent)
			return EvaluationResult(newState: next, shouldNotify: false, notifyLevel: .none, title: nil, body: nil)
		}

		// Cooldown guard.
		if let lastNotifyAt = base.lastNotifyAt, minimumCooldownSeconds > 0 {
			let delta = input.now.timeIntervalSince(lastNotifyAt)
			if delta < minimumCooldownSeconds {
				let next = State(month: input.month, metricKind: input.metricKind, lastLevel: currentLevel, lastNotifyAt: base.lastNotifyAt, lastPercent: input.percent)
				return EvaluationResult(newState: next, shouldNotify: false, notifyLevel: .none, title: nil, body: nil)
			}
		}

		// Build notification content.
		let content = buildNotificationContent(input: input, level: currentLevel, warnAt: normalized.warnAt, dangerAt: normalized.dangerAt)

		let next = State(month: input.month, metricKind: input.metricKind, lastLevel: currentLevel, lastNotifyAt: input.now, lastPercent: input.percent)
		return EvaluationResult(newState: next, shouldNotify: true, notifyLevel: currentLevel, title: content.title, body: content.body)
	}

	/// Fire a user notification using `UNUserNotificationCenter`.
	///
	/// You typically call this with the result of `evaluate(...)` if `shouldNotify` is true.
	public static func postUserNotification(
		center: UNUserNotificationCenter = .current(),
		identifier: String,
		title: String,
		body: String
	) async throws {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default

		// Deliver immediately.
		let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

		try await center.add(request)
	}

	/// Generate a stable notification identifier for a given month + metric + level.
	/// This helps prevent stacking identical notifications on rapid refreshes.
	public static func notificationIdentifier(appPrefix: String = "cpum", month: YearMonth, metricKind: MetricKind, level: Level) -> String {
		return "\(appPrefix).\(month.year)-\(month.month).\(metricKind.rawValue).\(level.rawValue)"
	}

	// MARK: - Internals

	private static func baselineState(for input: EvaluationInput, previousState: State?) -> State {
		guard let previousState else {
			// First run: create baseline but do not notify.
			return State(month: input.month, metricKind: input.metricKind, lastLevel: .none, lastNotifyAt: nil, lastPercent: input.percent)
		}

		// If we are in a different month or metric, reset baseline.
		if previousState.month != input.month || previousState.metricKind != input.metricKind {
			return State(month: input.month, metricKind: input.metricKind, lastLevel: .none, lastNotifyAt: nil, lastPercent: input.percent)
		}

		// Otherwise keep prior state.
		return previousState
	}

	private static func normalizeThresholds(warnAt: Int?, dangerAt: Int?) -> (warnAt: Int?, dangerAt: Int?) {
		switch (warnAt, dangerAt) {
		case (nil, nil):
			return (nil, nil)
		case (let w?, nil):
			return (w, nil)
		case (nil, let d?):
			return (nil, d)
		case (let w?, let d?):
			if w <= d { return (w, d) }
			// If misconfigured, swap to keep ordering sane.
			return (d, w)
		}
	}

	private static func classifyLevel(percent: Double, warnAt: Int?, dangerAt: Int?) -> Level {
		let p = UsageCalculations.clampPercent(percent)

		if let dangerAt, dangerAt > 0, p >= Double(dangerAt) {
			return .danger
		}
		if let warnAt, warnAt > 0, p >= Double(warnAt) {
			return .warn
		}
		return .none
	}

	private static func buildNotificationContent(
		input: EvaluationInput,
		level: Level,
		warnAt: Int?,
		dangerAt: Int?
	) -> (title: String, body: String) {
		let percent = UsageCalculations.clampPercent(input.percent)
		let rounded = Int(round(percent))

		let levelWord: String = {
			switch level {
			case .danger: return "Danger"
			case .warn: return "Warning"
			case .none: return "Update"
			}
		}()

		let thresholdText: String = {
			switch level {
			case .danger:
				if let dangerAt { return "≥ \(dangerAt)%" }
				return "threshold reached"
			case .warn:
				if let warnAt { return "≥ \(warnAt)%" }
				return "threshold reached"
			case .none:
				return ""
			}
		}()

		let metricName = input.metricKind.displayName
		let title = "\(levelWord): \(metricName) usage at \(rounded)%"

		var bodyParts: [String] = []
		bodyParts.append("\(input.label) is at \(String(format: "%.1f", percent))% (\(thresholdText)).")

		if let detail = input.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			bodyParts.append(detail)
		}

		// Mention month context to reduce confusion at month rollover.
		bodyParts.append("Period: \(input.month.displayName) (UTC).")

		return (title, bodyParts.joined(separator: " "))
	}
}
