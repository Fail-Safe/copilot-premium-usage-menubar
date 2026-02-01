import Foundation

// MARK: - Core Domain Models

/// Which metric the menubar should primarily display.
public enum PrimaryMetric: String, Codable, CaseIterable, Sendable {
	case budgetPercent
	case includedPercent

	public var displayName: String {
		switch self {
		case .budgetPercent: return "Budget %"
		case .includedPercent: return "Included %"
		}
	}
}

/// Source of the monthly budget limit (USD) used to compute "budget percent".
public enum BudgetLimitSource: String, Codable, CaseIterable, Sendable {
	/// User supplied a manual override.
	case manualOverride

	/// A placeholder for a future "fetch configured budget from GitHub" option.
	/// Not implemented until a stable official API is confirmed.
	case githubConfiguredBudget

	public var displayName: String {
		switch self {
		case .manualOverride: return "Manual"
		case .githubConfiguredBudget: return "GitHub (if available)"
		}
	}
}

/// User-configurable settings that affect calculations and UX.
public struct UsagePreferences: Codable, Equatable, Sendable {
	public var refreshIntervalMinutes: Int
	public var warnAtPercent: Double
	public var dangerAtPercent: Double
	public var notificationsEnabled: Bool

	public var primaryMetric: PrimaryMetric

	/// Budget configuration
	public var budgetLimitSource: BudgetLimitSource
	public var manualBudgetUsd: Double

	/// Included premium request limit configuration (parity with VS Code extension)
	///
	/// Priority (mirrors VS Code):
	/// 1) `includedPremiumRequestsOverride` (if > 0)
	/// 2) `selectedPlanId` (if set; resolved via bundled plan mapping in the app layer)
	/// 3) Billing-derived included consumed (best-effort fallback, if used by callers)
	public var selectedPlanId: String?
	public var includedPremiumRequestsOverride: Double

	public init(
		refreshIntervalMinutes: Int = 15,
		warnAtPercent: Double = 75,
		dangerAtPercent: Double = 90,
		notificationsEnabled: Bool = false,
		primaryMetric: PrimaryMetric = .budgetPercent,
		budgetLimitSource: BudgetLimitSource = .manualOverride,
		manualBudgetUsd: Double = 10,
		selectedPlanId: String? = nil,
		includedPremiumRequestsOverride: Double = 0
	) {
		self.refreshIntervalMinutes = max(1, refreshIntervalMinutes)
		self.warnAtPercent = warnAtPercent
		self.dangerAtPercent = dangerAtPercent
		self.notificationsEnabled = notificationsEnabled
		self.primaryMetric = primaryMetric
		self.budgetLimitSource = budgetLimitSource
		self.manualBudgetUsd = manualBudgetUsd
		self.selectedPlanId = selectedPlanId?.trimmingCharacters(in: .whitespacesAndNewlines)
		self.includedPremiumRequestsOverride = max(0, includedPremiumRequestsOverride)
	}
}

/// Represents a month in UTC terms (matching how your VS Code extension queries GitHub billing usage).
public struct YearMonth: Codable, Equatable, Hashable, Sendable {
	public let year: Int
	public let month: Int // 1-12

	public init(year: Int, month: Int) {
		self.year = year
		self.month = month
	}

	public static func currentUTC(using date: Date = Date()) -> YearMonth {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		let comps = cal.dateComponents([.year, .month], from: date)
		return YearMonth(year: comps.year ?? 1970, month: comps.month ?? 1)
	}

	public var displayName: String {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		var comps = DateComponents()
		comps.year = year
		comps.month = month
		comps.day = 1
		let date = cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)

		let fmt = DateFormatter()
		fmt.locale = Locale(identifier: "en_US_POSIX")
		fmt.timeZone = cal.timeZone
		fmt.dateFormat = "LLLL yyyy"
		return fmt.string(from: date)
	}
}

/// A single Copilot usage/billing item as returned by GitHub Billing usage (surface area intentionally small).
public struct BillingUsageItem: Codable, Equatable, Sendable {
	public let product: String?
	public let quantity: Double?
	public let netAmount: Double?
	public let unitPrice: Double?
	public let discountAmount: Double?

	public init(
		product: String?,
		quantity: Double?,
		netAmount: Double?,
		unitPrice: Double?,
		discountAmount: Double?
	) {
		self.product = product
		self.quantity = quantity
		self.netAmount = netAmount
		self.unitPrice = unitPrice
		self.discountAmount = discountAmount
	}
}

/// Reduced computed usage derived from billing items (mirrors your extension's derivations).
public struct CopilotUsageSummary: Codable, Equatable, Sendable {
	/// Total net amount (USD) for Copilot items for the selected month.
	public let spendUsd: Double

	/// Total quantity (premium requests) for Copilot items for the selected month.
	public let totalQuantity: Int

	/// Derived included quantity for the month (integer units).
	public let totalIncludedQuantity: Int

	/// Overage quantity for the month (integer units).
	public let totalOverageQuantity: Int

	public init(spendUsd: Double, totalQuantity: Int, totalIncludedQuantity: Int, totalOverageQuantity: Int) {
		self.spendUsd = spendUsd
		self.totalQuantity = totalQuantity
		self.totalIncludedQuantity = totalIncludedQuantity
		self.totalOverageQuantity = totalOverageQuantity
	}
}

/// The "current state" computed for UI consumption (menubar + popover).
public struct UsageViewState: Codable, Equatable, Sendable {
	public enum Phase: String, Codable, Sendable {
		/// Total usage is still within included units (if included > 0 and used < included).
		case included
		/// Included has been exhausted (or not applicable), so budget/spend becomes primary.
		case budget
	}

	public enum Health: String, Codable, Sendable {
		case ok
		case warning
		case danger
		case stale
		case error
	}

	public let month: YearMonth

	/// Raw computed values.
	public let spendUsd: Double
	public let budgetUsd: Double
	public let budgetPercent: Double

	public let includedTotal: Int
	public let includedUsed: Int
	public let includedPercent: Double

	public let phase: Phase
	public let health: Health

	public let lastRefreshAt: Date?
	public let lastErrorMessage: String?

	public init(
		month: YearMonth,
		spendUsd: Double,
		budgetUsd: Double,
		budgetPercent: Double,
		includedTotal: Int,
		includedUsed: Int,
		includedPercent: Double,
		phase: Phase,
		health: Health,
		lastRefreshAt: Date?,
		lastErrorMessage: String?
	) {
		self.month = month
		self.spendUsd = spendUsd
		self.budgetUsd = budgetUsd
		self.budgetPercent = budgetPercent
		self.includedTotal = includedTotal
		self.includedUsed = includedUsed
		self.includedPercent = includedPercent
		self.phase = phase
		self.health = health
		self.lastRefreshAt = lastRefreshAt
		self.lastErrorMessage = lastErrorMessage
	}
}

// MARK: - Helpers

public enum UsageCalculations {
	/// Clamp a percentage to [0, 100].
	public static func clampPercent(_ v: Double) -> Double {
		return max(0, min(100, v))
	}

	public static func percent(numerator: Double, denominator: Double) -> Double {
		guard denominator > 0 else { return 0 }
		return clampPercent((numerator / denominator) * 100.0)
	}

	public static func percentInt(numerator: Int, denominator: Int) -> Double {
		return percent(numerator: Double(numerator), denominator: Double(denominator))
	}
}
