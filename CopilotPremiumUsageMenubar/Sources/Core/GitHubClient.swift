import Foundation

// MARK: - GitHub REST Client (minimal, no external deps)

public struct GitHubClientConfig: Sendable {
	/// Base URL for GitHub API. Defaults to public GitHub.
	/// If you ever support GHES, allow overriding this preference.
	public var baseURL: URL

	/// Optional extra headers applied to every request.
	public var defaultHeaders: [String: String]

	/// Request timeout.
	public var timeout: TimeInterval

	public init(
		baseURL: URL = URL(string: "https://api.github.com")!,
		defaultHeaders: [String: String] = [:],
		timeout: TimeInterval = 30
	) {
		self.baseURL = baseURL
		self.defaultHeaders = defaultHeaders
		self.timeout = timeout
	}
}

public enum GitHubAPIError: Error, Sendable, CustomStringConvertible {
	case invalidURL(String)
	case invalidResponse
	case transportError(String)
	case httpError(status: Int, message: String?, requestId: String?, documentationURL: String?)
	case rateLimited(resetAt: Date?, message: String?, requestId: String?)
	case decodingError(String)
	case unauthorized(message: String?, requestId: String?)
	case forbidden(message: String?, requestId: String?)

	public var description: String {
		switch self {
		case .invalidURL(let s):
			return "Invalid URL: \(s)"
		case .invalidResponse:
			return "Invalid HTTP response."
		case .transportError(let s):
			return "Network error: \(s)"
		case .httpError(let status, let message, let requestId, let docURL):
			var parts: [String] = ["GitHub API error (HTTP \(status))."]
			if let message, !message.isEmpty { parts.append(message) }
			if let requestId, !requestId.isEmpty { parts.append("Request ID: \(requestId)") }
			if let docURL, !docURL.isEmpty { parts.append("Docs: \(docURL)") }
			return parts.joined(separator: " ")
		case .rateLimited(let resetAt, let message, let requestId):
			var parts: [String] = ["GitHub API rate limited."]
			if let message, !message.isEmpty { parts.append(message) }
			if let resetAt { parts.append("Resets at: \(resetAt)") }
			if let requestId, !requestId.isEmpty { parts.append("Request ID: \(requestId)") }
			return parts.joined(separator: " ")
		case .decodingError(let s):
			return "Failed to decode response: \(s)"
		case .unauthorized(let message, let requestId):
			var parts: [String] = ["Unauthorized (HTTP 401)."]
			if let message, !message.isEmpty { parts.append(message) }
			if let requestId, !requestId.isEmpty { parts.append("Request ID: \(requestId)") }
			return parts.joined(separator: " ")
		case .forbidden(let message, let requestId):
			var parts: [String] = ["Forbidden (HTTP 403)."]
			if let message, !message.isEmpty { parts.append(message) }
			if let requestId, !requestId.isEmpty { parts.append("Request ID: \(requestId)") }
			return parts.joined(separator: " ")
		}
	}
}

/// Minimal GitHub REST client intended for:
/// - `GET /user`
/// - `GET /users/{username}/settings/billing/usage?...`
///
/// This avoids external dependencies (e.g., Octokit) to keep the menubar app lightweight.
public final class GitHubClient: @unchecked Sendable {
	public struct User: Codable, Equatable, Sendable {
		public let login: String?

		public init(login: String?) {
			self.login = login
		}
	}

	/// The response schema is not publicly documented in a strongly typed way for all fields,
	/// so we keep it minimal and decode only what we use.
	private struct BillingUsageResponse: Codable, Sendable {
		let usageItems: [BillingUsageItem]?
	}

	/// GitHub can return an error body like:
	/// `{ "message": "...", "documentation_url": "..." }`
	private struct GitHubErrorBody: Codable, Sendable {
		let message: String?
		let documentation_url: String?
	}

	private let config: GitHubClientConfig
	private let session: URLSession

	/// Create a new client.
	///
	/// - Parameters:
	///   - config: API base URL, timeout, and default headers.
	///   - session: Optional URLSession injection for tests.
	public init(config: GitHubClientConfig = GitHubClientConfig(), session: URLSession? = nil) {
		self.config = config

		if let session {
			self.session = session
		} else {
			let cfg = URLSessionConfiguration.ephemeral
			cfg.timeoutIntervalForRequest = config.timeout
			cfg.timeoutIntervalForResource = config.timeout
			cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
			cfg.httpAdditionalHeaders = [
				"Accept": "application/vnd.github+json",
				"X-GitHub-Api-Version": "2022-11-28"
			]
			self.session = URLSession(configuration: cfg)
		}
	}

	// MARK: - Public API

	/// Fetch the authenticated user (`/user`) to discover the `login`.
	public func fetchViewer(token: String) async throws -> User {
		return try await requestJSON(
			method: "GET",
			path: "/user",
			query: [],
			token: token,
			as: User.self
		)
	}



	/// Fetch the billing usage for a specific user and Year/Month (UTC).
	///
	/// Mirrors the VS Code extension behavior:
	/// - request `/users/{username}/settings/billing/usage`
	/// - filter usageItems by product == "copilot"
	/// - compute spend + quantities + derived included units and overage.
	public func fetchCopilotBillingUsage(username: String, token: String, month: YearMonth) async throws -> CopilotUsageSummary {
		var query: [URLQueryItem] = []
		query.append(URLQueryItem(name: "year", value: String(month.year)))
		query.append(URLQueryItem(name: "month", value: String(month.month)))

		let res = try await requestJSON(
			method: "GET",
			path: "/users/\(Self.urlPathEscape(username))/settings/billing/usage",
			query: query,
			token: token,
			as: BillingUsageResponse.self
		)

		let items = res.usageItems ?? []
		let copilotItems = items.filter { ($0.product ?? "").lowercased() == "copilot" }

		let spendUsd = copilotItems.reduce(0.0) { $0 + (Self.safeNumber($1.netAmount)) }
		let totalQuantityD = copilotItems.reduce(0.0) { $0 + (Self.safeNumber($1.quantity)) }
		let totalQuantity = Int(round(totalQuantityD))

		let included = Self.calculateIncludedQuantity(items: copilotItems)
		let overage = max(0, totalQuantity - included)

		return CopilotUsageSummary(
			spendUsd: spendUsd,
			totalQuantity: totalQuantity,
			totalIncludedQuantity: included,
			totalOverageQuantity: overage
		)
	}

	// MARK: - Core request/transport

	private func requestJSON<T: Decodable>(
		method: String,
		path: String,
		query: [URLQueryItem],
		token: String,
		as type: T.Type
	) async throws -> T {
		let (data, _) = try await requestData(method: method, path: path, query: query, token: token)

		do {
			let decoder = JSONDecoder()
			return try decoder.decode(T.self, from: data)
		} catch {
			// If the body is a GitHub error, surface that instead (helps debugging).
			if let apiError = try? decodeGitHubError(from: data) {
				throw apiError
			}
			throw GitHubAPIError.decodingError(String(describing: error))
		}
	}

	private func requestData(
		method: String,
		path: String,
		query: [URLQueryItem],
		token: String
	) async throws -> (Data, HTTPURLResponse) {
		let url = try makeURL(path: path, query: query)
		var req = URLRequest(url: url)
		req.httpMethod = method

		// Auth
		req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		// Merge default headers
		for (k, v) in config.defaultHeaders {
			req.setValue(v, forHTTPHeaderField: k)
		}

		let data: Data
		let resp: URLResponse
		do {
			(data, resp) = try await session.data(for: req)
		} catch {
			throw GitHubAPIError.transportError(String(describing: error))
		}

		guard let http = resp as? HTTPURLResponse else {
			throw GitHubAPIError.invalidResponse
		}

		// Handle non-2xx
		if !(200...299).contains(http.statusCode) {
			// Some endpoints return useful JSON error bodies.
			let requestId = http.value(forHTTPHeaderField: "x-github-request-id")

			// Try decode message/docs from body (best effort).
			let parsed = Self.parseErrorBody(data: data)
			let message = parsed.message
			let docURL = parsed.documentationURL

			// Throttling / rate-limiting:
			//
			// GitHub may indicate throttling via:
			// - HTTP 429 (Too Many Requests) with optional `Retry-After`
			// - HTTP 403 with `x-ratelimit-remaining: 0` and `x-ratelimit-reset`
			// - Sometimes `Retry-After` can appear on other non-2xx responses
			let retryAfter = Self.parseRetryAfter(from: http)
			let resetAt = Self.parseRateLimitReset(from: http)

			if http.statusCode == 429 {
				// If `Retry-After` is present, treat that as the effective reset.
				let effectiveReset = retryAfter.map { Date().addingTimeInterval($0) } ?? resetAt
				throw GitHubAPIError.rateLimited(resetAt: effectiveReset, message: message, requestId: requestId)
			}

			// Specific handling
			if http.statusCode == 401 {
				throw GitHubAPIError.unauthorized(message: message, requestId: requestId)
			}
			if http.statusCode == 403 {
				// Rate limit is surfaced as 403 in some cases.
				// GitHub often sets x-ratelimit-remaining: 0
				let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
				if remaining == "0" {
					throw GitHubAPIError.rateLimited(resetAt: resetAt, message: message, requestId: requestId)
				}
				throw GitHubAPIError.forbidden(message: message, requestId: requestId)
			}

			// If the server asked us to back off, surface it as a rate-limited error
			// even if the HTTP status isn't one of the common cases above.
			if let retryAfter {
				let effectiveReset = Date().addingTimeInterval(retryAfter)
				throw GitHubAPIError.rateLimited(resetAt: effectiveReset, message: message, requestId: requestId)
			}

			throw GitHubAPIError.httpError(
				status: http.statusCode,
				message: message,
				requestId: requestId,
				documentationURL: docURL
			)
		}

		return (data, http)
	}



	// MARK: - URL building

	private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
		guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
			throw GitHubAPIError.invalidURL(config.baseURL.absoluteString)
		}

		// Ensure path joins correctly.
		let basePath = comps.path
		if path.hasPrefix("/") {
			comps.path = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath) + path
		} else {
			comps.path = (basePath.hasSuffix("/") ? basePath : basePath + "/") + path
		}

		if !query.isEmpty {
			comps.queryItems = query
		}

		guard let url = comps.url else {
			throw GitHubAPIError.invalidURL("\(config.baseURL.absoluteString)\(path)")
		}
		return url
	}

	private static func urlPathEscape(_ s: String) -> String {
		// Percent-escape path segments (not the entire URL).
		// GitHub usernames are generally safe, but keep it robust.
		var allowed = CharacterSet.urlPathAllowed
		allowed.remove(charactersIn: "/")
		return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
	}

	// MARK: - Error parsing

	private static func parseErrorBody(data: Data) -> (message: String?, documentationURL: String?) {
		guard !data.isEmpty else { return (nil, nil) }
		if let err = try? JSONDecoder().decode(GitHubErrorBody.self, from: data) {
			return (err.message, err.documentation_url)
		}
		return (String(data: data, encoding: .utf8), nil)
	}

	private func decodeGitHubError(from data: Data) throws -> GitHubAPIError? {
		let parsed = Self.parseErrorBody(data: data)
		if parsed.message == nil && parsed.documentationURL == nil { return nil }
		return .httpError(status: -1, message: parsed.message, requestId: nil, documentationURL: parsed.documentationURL)
	}

	private static func parseRateLimitReset(from response: HTTPURLResponse) -> Date? {
		guard let resetStr = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
			  let resetSeconds = TimeInterval(resetStr) else {
			return nil
		}
		return Date(timeIntervalSince1970: resetSeconds)
	}

	private static func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
		guard let s = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !s.isEmpty else {
			return nil
		}

		// Per RFC 9110, Retry-After can be either:
		// - a delay-seconds integer
		// - an HTTP-date
		if let seconds = TimeInterval(s) {
			return max(0, seconds)
		}

		// Try parsing as HTTP-date (RFC 1123).
		let fmt = DateFormatter()
		fmt.locale = Locale(identifier: "en_US_POSIX")
		fmt.timeZone = TimeZone(secondsFromGMT: 0)
		fmt.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"

		if let date = fmt.date(from: s) {
			let delta = date.timeIntervalSinceNow
			return max(0, delta)
		}

		return nil
	}

	// MARK: - Included quantity derivation (mirrors VS Code extension concept)

	/// Derive included units from `discountAmount / unitPrice` per item, rounding to nearest whole unit.
	///
	/// This matches the extension comment:
	/// "Derive included units from discountAmount / pricePerUnit per item (guard division by zero)."
	private static func calculateIncludedQuantity(items: [BillingUsageItem]) -> Int {
		var total: Double = 0

		for item in items {
			let discount = safeNumber(item.discountAmount)
			let unitPrice = safeNumber(item.unitPrice)

			guard discount > 0, unitPrice > 0 else { continue }

			let includedForItem = discount / unitPrice
			if includedForItem.isFinite, includedForItem > 0 {
				total += includedForItem
			}
		}

		// Round to nearest whole unit (requests are integer counts).
		return Int(round(total))
	}

	private static func safeNumber(_ v: Double?) -> Double {
		guard let v, v.isFinite else { return 0 }
		return v
	}
}
