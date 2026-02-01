import Foundation

// MARK: - UsageService

/// Fetches GitHub Enhanced Billing usage for the current user and computes a Copilot usage summary.
///
/// This mirrors the VS Code extension’s core behavior:
/// - `GET /user` to determine the authenticated login
/// - `GET /users/{username}/settings/billing/usage?year=&month=`
/// - filter usage items down to `product == "copilot"` (case-insensitive)
/// - compute:
///   - `totalNetAmount` (spend)
///   - `totalQuantity`
///   - `totalIncludedQuantity` derived from discount/unit computations
///   - `totalOverageQuantity = max(0, totalQuantity - totalIncludedQuantity)`
///
/// Notes:
/// - This file intentionally avoids external dependencies.
/// - The token is provided by the caller (typically loaded from Keychain in the app layer).
public final class UsageService: @unchecked Sendable {
	public enum UsageServiceError: Error, CustomStringConvertible, Sendable {
		case missingToken
		case invalidURL
		case httpError(status: Int, body: String?)
		case decodingError(String)
		case unexpectedResponse

		public var description: String {
			switch self {
			case .missingToken:
				return "Missing GitHub token."
			case .invalidURL:
				return "Invalid URL."
			case .httpError(let status, let body):
				if let body, !body.isEmpty {
					return "GitHub API error \(status): \(body)"
				}
				return "GitHub API error \(status)."
			case .decodingError(let message):
				return "Failed to decode response: \(message)"
			case .unexpectedResponse:
				return "Unexpected response from GitHub."
			}
		}
	}

	/// Allows dependency injection for testing.
	public protocol HTTPClient: Sendable {
		func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
	}

	public struct URLSessionHTTPClient: HTTPClient {
		private let session: URLSession

		public init(session: URLSession = .shared) {
			self.session = session
		}

		public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				throw UsageServiceError.unexpectedResponse
			}
			return (data, http)
		}
	}

	private let http: HTTPClient
	private let baseURL: URL
	private let apiVersionHeaderValue: String

	public init(
		http: HTTPClient = URLSessionHTTPClient(),
		baseURL: URL = URL(string: "https://api.github.com")!,
		apiVersionHeaderValue: String = "2022-11-28"
	) {
		self.http = http
		self.baseURL = baseURL
		self.apiVersionHeaderValue = apiVersionHeaderValue
	}

	// MARK: - Public API

	/// Fetches Copilot billing usage for the given month (UTC), using the provided GitHub token.
	public func fetchCopilotUsageSummary(
		month: YearMonth = .currentUTC(),
		token: String?
	) async throws -> CopilotUsageSummary {
		guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw UsageServiceError.missingToken
		}

		let login = try await fetchAuthenticatedLogin(token: token)

		let usageItems = try await fetchBillingUsageItems(
			username: login,
			month: month,
			token: token
		)

		let copilotItems = usageItems.filter { item in
			(item.product ?? "").lowercased() == "copilot"
		}

		let spendUsd = copilotItems.reduce(0.0) { partial, item in
			partial + (item.netAmount ?? 0.0)
		}

		let totalQtyDouble = copilotItems.reduce(0.0) { partial, item in
			partial + (item.quantity ?? 0.0)
		}
		let totalQuantity = Int((totalQtyDouble).rounded()) // GitHub quantities are effectively integral for requests

		let included = Self.calculateIncludedQuantity(from: copilotItems)
		let overage = max(0, totalQuantity - included)

		return CopilotUsageSummary(
			spendUsd: spendUsd,
			totalQuantity: totalQuantity,
			totalIncludedQuantity: included,
			totalOverageQuantity: overage
		)
	}

	/// Computes a `UsageViewState` (budget %, included %, phase/health) from a summary and preferences.
	/// This intentionally mirrors your VS Code “two-phase meter” concept:
	/// - Included phase when includedTotal > 0 and used < includedTotal
	/// - Budget phase otherwise
	public func computeViewState(
		month: YearMonth,
		summary: CopilotUsageSummary,
		preferences: UsagePreferences,
		lastRefreshAt: Date?,
		lastErrorMessage: String?
	) -> UsageViewState {
		let spend = max(0, summary.spendUsd)

		// GitHub billing usage gives us:
		// - used premium requests (summary.totalQuantity)
		// - included *consumed* (summary.totalIncludedQuantity, derived from discountAmount/pricePerUnit)
		//
		// But it does NOT tell us the plan's monthly included limit (e.g. 1500 for Pro+).
		// To compute "used / included limit", mirror the VS Code extension priority:
		//  1) User override (if > 0)
		//  2) Selected built-in plan (if available)
		//  3) Fallback to billing-derived included consumed (best-effort)
		let includedUsed = max(0, summary.totalQuantity)

		// Included limit selection (mirrors VS Code extension priority):
		//  1) user override (if > 0)
		//  2) selected plan (resolved in app layer; stored as override value here)
		//  3) fallback to billing-derived included consumed
		let overrideLimit = max(0, Int(preferences.includedPremiumRequestsOverride.rounded()))
		var includedTotal = overrideLimit

		if includedTotal <= 0 {
			includedTotal = max(0, summary.totalIncludedQuantity)
		}

		// Determine budget dollars based on preferences (GitHub budget fetch not implemented here).
		let budgetUsd: Double
		switch preferences.budgetLimitSource {
		case .manualOverride:
			budgetUsd = max(0, preferences.manualBudgetUsd)
		case .githubConfiguredBudget:
			// Placeholder: until a stable official API is confirmed, fall back to manual.
			budgetUsd = max(0, preferences.manualBudgetUsd)
		}

		let includedPercent = UsageCalculations.percentInt(numerator: includedUsed, denominator: includedTotal)
		let budgetPercent = UsageCalculations.percent(numerator: spend, denominator: budgetUsd)

		let phase: UsageViewState.Phase = (includedTotal > 0 && includedUsed < includedTotal) ? .included : .budget

		// Health is based on budget percent thresholds (matching extension’s budget-color threshold behavior).
		// In included phase, the VS Code extension suppresses warn/danger icons; for a first cut we’ll keep
		// health calculation based on budget percent but callers/UI can choose to render differently.
		let warnAt = preferences.warnAtPercent
		let dangerAt = preferences.dangerAtPercent

		let health: UsageViewState.Health
		if let lastErrorMessage, !lastErrorMessage.isEmpty {
			health = .error
		} else if budgetUsd <= 0 {
			// Budget disabled / unknown: treat as OK (you can tweak; this avoids constant warning states).
			health = .ok
		} else if dangerAt > 0 && budgetPercent >= dangerAt {
			health = .danger
		} else if warnAt > 0 && budgetPercent >= warnAt {
			health = .warning
		} else {
			health = .ok
		}

		return UsageViewState(
			month: month,
			spendUsd: spend,
			budgetUsd: budgetUsd,
			budgetPercent: budgetPercent,
			includedTotal: includedTotal,
			includedUsed: includedUsed,
			includedPercent: includedPercent,
			phase: phase,
			health: health,
			lastRefreshAt: lastRefreshAt,
			lastErrorMessage: lastErrorMessage
		)
	}

	// MARK: - GitHub API calls

	private struct GitHubUserResponse: Decodable {
		let login: String?
	}

	/// Response wrapper for the billing usage endpoint.
	/// We only decode the fields we need.
	private struct GitHubBillingUsageResponse: Decodable {
		let usageItems: [BillingUsageItemDTO]?

		struct BillingUsageItemDTO: Decodable {
			let product: String?
			let quantity: Double?
			let netAmount: Double?
			let unitPrice: Double?
			let discountAmount: Double?

			func toModel() -> BillingUsageItem {
				BillingUsageItem(
					product: product,
					quantity: quantity,
					netAmount: netAmount,
					unitPrice: unitPrice,
					discountAmount: discountAmount
				)
			}
		}
	}

	private func fetchAuthenticatedLogin(token: String) async throws -> String {
		let url = baseURL.appending(path: "user")
		var req = URLRequest(url: url)
		applyGitHubHeaders(&req, token: token)

		let (data, httpRes) = try await http.data(for: req)
		try validateOrThrow(httpRes: httpRes, data: data)

		do {
			let decoded = try JSONDecoder().decode(GitHubUserResponse.self, from: data)
			if let login = decoded.login, !login.isEmpty {
				return login
			}
			throw UsageServiceError.unexpectedResponse
		} catch {
			throw UsageServiceError.decodingError(String(describing: error))
		}
	}

	private func fetchBillingUsageItems(username: String, month: YearMonth, token: String) async throws -> [BillingUsageItem] {
		// Endpoint:
		// GET /users/{username}/settings/billing/usage?year=&month=
		let url = baseURL
			.appending(path: "users")
			.appending(path: username)
			.appending(path: "settings")
			.appending(path: "billing")
			.appending(path: "usage")

		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			throw UsageServiceError.invalidURL
		}
		components.queryItems = [
			URLQueryItem(name: "year", value: String(month.year)),
			URLQueryItem(name: "month", value: String(month.month))
		]
		guard let finalURL = components.url else {
			throw UsageServiceError.invalidURL
		}

		var req = URLRequest(url: finalURL)
		applyGitHubHeaders(&req, token: token)

		let (data, httpRes) = try await http.data(for: req)
		try validateOrThrow(httpRes: httpRes, data: data)

		do {
			let decoded = try JSONDecoder().decode(GitHubBillingUsageResponse.self, from: data)
			return (decoded.usageItems ?? []).map { $0.toModel() }
		} catch {
			throw UsageServiceError.decodingError(String(describing: error))
		}
	}

	private func applyGitHubHeaders(_ request: inout URLRequest, token: String) {
		request.httpMethod = "GET"
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue(apiVersionHeaderValue, forHTTPHeaderField: "X-GitHub-Api-Version")
	}

	private func validateOrThrow(httpRes: HTTPURLResponse, data: Data) throws {
		guard (200..<300).contains(httpRes.statusCode) else {
			let body = String(data: data, encoding: .utf8)
			throw UsageServiceError.httpError(status: httpRes.statusCode, body: body)
		}
	}

	// MARK: - Included quantity derivation

	/// Attempts to derive included quantity from billing items by using `discountAmount / unitPrice`.
	///
	/// The VS Code extension comment says:
	/// - derive included units from discountAmount / pricePerUnit per item (guard division by zero)
	/// - round per item to nearest whole unit since requests are integer counts
	///
	/// GitHub’s billing payload shape may vary; this is a best-effort heuristic.
	private static func calculateIncludedQuantity(from items: [BillingUsageItem]) -> Int {
		var sum = 0

		for item in items {
			// Your extension treats requests as integer counts, so per-item rounding is used.
			guard let discount = item.discountAmount, discount > 0 else { continue }

			// Prefer explicit unit price if present.
			let unitPrice = (item.unitPrice ?? 0)
			guard unitPrice > 0 else { continue }

			let includedForItem = Int((discount / unitPrice).rounded())
			if includedForItem > 0 {
				sum += includedForItem
			}
		}

		return max(0, sum)
	}
}
