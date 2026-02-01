import Foundation

/// A lightweight preferences wrapper around `UserDefaults` for the menubar app.
///
/// Notes:
/// - This intentionally mirrors the VS Code extension's core settings: refresh interval and thresholds,
///   but adapts them to a macOS app context.
/// - Token storage is handled separately via Keychain (not UserDefaults).
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    // MARK: - Types

    public enum PrimaryMetric: String, CaseIterable, Codable, Sendable {
        case budgetPercent
        case includedPercent

        public var displayName: String {
            switch self {
            case .budgetPercent: return "Budget %"
            case .includedPercent: return "Included %"
            }
        }
    }

    /// How the menubar should display the primary number/icon.
    ///
    /// Notes:
    /// - `.includedThenBudgetCombined` shows Included % until included is exhausted, then shows
    ///   `Included % + Budget %` (so the number can exceed 100 once in budget/overage phase).
    /// - This is intended to be compact/at-a-glance and may differ from the popover's full breakdown.
    public enum MenubarDisplayMode: String, CaseIterable, Codable, Sendable {
        /// Always show Budget %.
        case budgetPercent
        /// Always show Included %.
        case includedPercent
        /// Show Included % while in included phase, then show Included % + Budget % once in budget phase.
        case includedThenBudgetCombined

        public var displayName: String {
            switch self {
            case .budgetPercent: return "Budget %"
            case .includedPercent: return "Included %"
            case .includedThenBudgetCombined: return "Included → Budget (combined)"
            }
        }
    }

    /// How the app should determine the budget dollars used for Budget % computations.
    public enum BudgetMode: String, CaseIterable, Codable, Sendable {
        /// Always use the user-provided override.
        case manualOverride

        /// Placeholder for a future implementation if/when an official budgets API is available and stable.
        /// For now, the app should behave like `.manualOverride` unless you implement fetch logic.
        case fetchFromGitHubIfAvailable

        public var displayName: String {
            switch self {
            case .manualOverride: return "Manual override"
            case .fetchFromGitHubIfAvailable: return "Fetch from GitHub (if available)"
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let refreshIntervalMinutes = "cpum.refreshIntervalMinutes"
        static let warnAtPercent = "cpum.warnAtPercent"
        static let dangerAtPercent = "cpum.dangerAtPercent"
        static let notificationsEnabled = "cpum.notificationsEnabled"
        static let primaryMetric = "cpum.primaryMetric"
        static let menubarDisplayMode = "cpum.menubarDisplayMode"
        static let budgetMode = "cpum.budgetMode"
        static let manualBudgetDollars = "cpum.manualBudgetDollars"
        static let selectedPlanId = "cpum.selectedPlanId"
        static let includedPremiumRequestsOverride = "cpum.includedPremiumRequestsOverride" // optional
        static let pricePerPremiumRequestOverride = "cpum.pricePerPremiumRequestOverride" // optional

        // One-time onboarding: used to decide whether we should auto-open the token prompt
        // the first time the user opens the UI and no token is configured.
        static let didAutoPromptForToken = "cpum.didAutoPromptForToken"
    }

    // MARK: - Defaults (keep aligned with VS Code extension where useful)

    // Refresh interval choices:
    // - In the normal UI, the refresh interval should be constrained to a safe set of values to avoid
    //   excessive GitHub API calls and popover UI quirks from numeric steppers.
    // - We still allow an internal/dev override for faster testing.
    public static let defaultRefreshIntervalMinutes: Int = 15

    /// Standard, user-facing refresh interval choices (in minutes).
    public static let allowedRefreshIntervalsMinutes: [Int] = [
        15,   // 15 min
        30,   // 30 min
        60,   // 1 hr
        120,  // 2 hr
        240,  // 4 hr
        480,  // 8 hr
        1440  // 24 hr
    ]

    /// Dev-only fast refresh choice for testing (hidden in UI unless enabled).
    public static let devAllowedRefreshIntervalMinutes: Int = 5

    /// If enabled, the app will accept and expose a dev-only 5 minute refresh interval option.
    ///
    /// This is intentionally "invisible" for normal users: it is gated by an environment variable.
    /// Set `CPUM_ENABLE_DEV_REFRESH=1` in the environment when launching the app to enable.
    public static var devRefreshOverrideEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["CPUM_ENABLE_DEV_REFRESH"] ?? ""
        return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
    }

    /// Allowed refresh intervals given the current runtime gating.
    public static var allowedRefreshIntervalsMinutesEffective: [Int] {
        var v = allowedRefreshIntervalsMinutes
        if devRefreshOverrideEnabled, !v.contains(devAllowedRefreshIntervalMinutes) {
            v.insert(devAllowedRefreshIntervalMinutes, at: 0)
        }
        return v.sorted()
    }

    /// Minimum/maximum kept for compatibility; clamping uses allowed values now.
    public static let minimumRefreshIntervalMinutes: Int = devAllowedRefreshIntervalMinutes
    public static let maximumRefreshIntervalMinutes: Int = 1440

    public static let defaultWarnAtPercent: Int = 75
    public static let defaultDangerAtPercent: Int = 90

    public static let defaultManualBudgetDollars: Double = 10.0

    // MARK: - Backing storage

    private let defaults: UserDefaults

    // MARK: - Published preferences (UI can bind directly)

    @Published public var refreshIntervalMinutes: Int {
        didSet { defaults.set(Self.clampRefresh(refreshIntervalMinutes), forKey: Keys.refreshIntervalMinutes) }
    }

    /// 0 disables warning threshold coloring/notifications at the warning level.
    @Published public var warnAtPercent: Int {
        didSet { defaults.set(Self.clampPercentAllowZero(warnAtPercent), forKey: Keys.warnAtPercent) }
    }

    /// 0 disables danger threshold coloring/notifications at the danger level.
    @Published public var dangerAtPercent: Int {
        didSet { defaults.set(Self.clampPercentAllowZero(dangerAtPercent), forKey: Keys.dangerAtPercent) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published public var primaryMetric: PrimaryMetric {
        didSet { defaults.set(primaryMetric.rawValue, forKey: Keys.primaryMetric) }
    }

    /// Controls how the menubar renders its compact display (icon/number).
    @Published public var menubarDisplayMode: MenubarDisplayMode {
        didSet { defaults.set(menubarDisplayMode.rawValue, forKey: Keys.menubarDisplayMode) }
    }

    @Published public var budgetMode: BudgetMode {
        didSet { defaults.set(budgetMode.rawValue, forKey: Keys.budgetMode) }
    }

    /// Manual budget dollars used for Budget % computations and display.
    @Published public var manualBudgetDollars: Double {
        didSet { defaults.set(Self.clampMoney(manualBudgetDollars), forKey: Keys.manualBudgetDollars) }
    }

    /// Selected built-in Copilot plan ID (mirrors the VS Code extension's `selectedPlanId` setting).
    /// Empty string means "not selected".
    @Published public var selectedPlanId: String {
        didSet { defaults.set(selectedPlanId, forKey: Keys.selectedPlanId) }
    }

    // Optional advanced overrides (kept for parity with VS Code; safe to ignore in v1 UI)
    @Published public var includedPremiumRequestsOverride: Int {
        didSet { defaults.set(max(0, includedPremiumRequestsOverride), forKey: Keys.includedPremiumRequestsOverride) }
    }

    @Published public var pricePerPremiumRequestOverride: Double {
        didSet { defaults.set(max(0, pricePerPremiumRequestOverride), forKey: Keys.pricePerPremiumRequestOverride) }
    }

    // MARK: - One-time onboarding (token prompt)

    /// If `false` and no token is configured, the UI may choose to auto-open the "Set Token" prompt
    /// once to help first-time users.
    ///
    /// This is just a persisted hint; the actual decision to show a prompt belongs in the UI layer
    /// (e.g. PopoverView / AppController) where token presence can be checked.
    @Published public var didAutoPromptForToken: Bool {
        didSet { defaults.set(didAutoPromptForToken, forKey: Keys.didAutoPromptForToken) }
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load persisted values (or defaults).
        let refresh = defaults.object(forKey: Keys.refreshIntervalMinutes) as? Int ?? Self.defaultRefreshIntervalMinutes
        self.refreshIntervalMinutes = Self.clampRefresh(refresh)

        let warn = defaults.object(forKey: Keys.warnAtPercent) as? Int ?? Self.defaultWarnAtPercent
        self.warnAtPercent = Self.clampPercentAllowZero(warn)

        let danger = defaults.object(forKey: Keys.dangerAtPercent) as? Int ?? Self.defaultDangerAtPercent
        self.dangerAtPercent = Self.clampPercentAllowZero(danger)

        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? false

        let metricRaw = defaults.string(forKey: Keys.primaryMetric)
        self.primaryMetric = PrimaryMetric(rawValue: metricRaw ?? "") ?? .budgetPercent

        // Menubar display mode:
        // - Default to the new phase-based combined behavior for a better at-a-glance signal.
        let menubarModeRaw = defaults.string(forKey: Keys.menubarDisplayMode)
        self.menubarDisplayMode = MenubarDisplayMode(rawValue: menubarModeRaw ?? "") ?? .includedThenBudgetCombined

        let budgetModeRaw = defaults.string(forKey: Keys.budgetMode)
        self.budgetMode = BudgetMode(rawValue: budgetModeRaw ?? "") ?? .manualOverride

        let budget = defaults.object(forKey: Keys.manualBudgetDollars) as? Double ?? Self.defaultManualBudgetDollars
        self.manualBudgetDollars = Self.clampMoney(budget)

        self.selectedPlanId = defaults.string(forKey: Keys.selectedPlanId) ?? ""

        let includedOverride = defaults.object(forKey: Keys.includedPremiumRequestsOverride) as? Int ?? 0
        self.includedPremiumRequestsOverride = max(0, includedOverride)

        let priceOverride = defaults.object(forKey: Keys.pricePerPremiumRequestOverride) as? Double ?? 0.0
        self.pricePerPremiumRequestOverride = max(0, priceOverride)

        self.didAutoPromptForToken = defaults.object(forKey: Keys.didAutoPromptForToken) as? Bool ?? false
    }

    // MARK: - Derived helpers

    /// Returns warn threshold as an `Int?` where `nil` means disabled.
    public var warnThresholdOrNil: Int? {
        let v = warnAtPercent
        return v > 0 ? v : nil
    }

    /// Returns danger threshold as an `Int?` where `nil` means disabled.
    public var dangerThresholdOrNil: Int? {
        let v = dangerAtPercent
        return v > 0 ? v : nil
    }

    /// Convenience to keep UI sane if a user sets warn >= danger etc.
    /// This does not enforce ordering automatically (to avoid surprising changes),
    /// but gives callers a place to clamp for presentation/notification logic.
    public func normalizedThresholds() -> (warn: Int?, danger: Int?) {
        let warn = warnThresholdOrNil
        let danger = dangerThresholdOrNil
        return (warn, danger)
    }

    // MARK: - Reset

    public func resetToDefaults() {
        refreshIntervalMinutes = Self.defaultRefreshIntervalMinutes
        warnAtPercent = Self.defaultWarnAtPercent
        dangerAtPercent = Self.defaultDangerAtPercent
        notificationsEnabled = false
        primaryMetric = .budgetPercent
        menubarDisplayMode = .includedThenBudgetCombined
        budgetMode = .manualOverride
        manualBudgetDollars = Self.defaultManualBudgetDollars
        selectedPlanId = ""
        includedPremiumRequestsOverride = 0
        pricePerPremiumRequestOverride = 0
        didAutoPromptForToken = false
    }

    // MARK: - Validation / clamping

    private static func clampPercentAllowZero(_ v: Int) -> Int {
        if v <= 0 { return 0 }
        if v > 100 { return 100 }
        return v
    }

    private static func clampRefresh(_ v: Int) -> Int {
        // Constrain to a fixed set of values to avoid overly frequent polling.
        // If a persisted value is not in the allowed list, pick the nearest allowed value.
        let allowed = allowedRefreshIntervalsMinutesEffective
        guard !allowed.isEmpty else {
            // Should never happen, but fall back to legacy min/max clamping.
            if v < minimumRefreshIntervalMinutes { return minimumRefreshIntervalMinutes }
            if v > maximumRefreshIntervalMinutes { return maximumRefreshIntervalMinutes }
            return v
        }

        // If already allowed, accept as-is.
        if allowed.contains(v) { return v }

        // Otherwise pick nearest by absolute distance; tie-breaker prefers larger interval.
        var best = allowed[0]
        var bestDist = abs(best - v)

        for candidate in allowed.dropFirst() {
            let dist = abs(candidate - v)
            if dist < bestDist {
                best = candidate
                bestDist = dist
            } else if dist == bestDist, candidate > best {
                best = candidate
            }
        }

        return best
    }

    private static func clampMoney(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        // Allow 0 budget (effectively disables Budget %); keep non-negative.
        return max(0, v)
    }
}
