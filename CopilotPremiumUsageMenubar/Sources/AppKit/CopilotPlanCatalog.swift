import Foundation

/// Loads a bundled Copilot plan mapping JSON and provides lookup helpers.
///
/// Why this exists:
/// - GitHub does not expose personal Copilot plan/licensing + included premium request limits via any stable public API.
/// - The menubar app therefore uses a bundled mapping (and/or user overrides) to compute "used / included limit".
///
/// Resource expectations:
/// - The plan JSON should be bundled as an app resource at:
///   `Resources/generated/copilot-plans.json`
///
/// Notes:
/// - When the resource cannot be loaded (e.g. in some `swift run` layouts or missing resources),
///   this catalog falls back to a small embedded default plan list matching the VS Code extension.
enum CopilotPlanCatalog {

	/// A single built-in plan entry.
	struct Plan: Codable, Equatable, Sendable, Identifiable {
		let id: String
		let name: String
		let includedPremiumRequestsPerMonth: Int

		var displayName: String { name }
	}

	/// Envelope for the bundled JSON file.
	struct BundleFile: Codable, Equatable, Sendable {
		let source: String?
		let description: String?
		let fetchedAt: String?
		let pricePerPremiumRequest: Double?
		let plans: [Plan]

		/// Normalizes plan IDs for reliable comparisons.
		func normalized() -> BundleFile {
			BundleFile(
				source: source,
				description: description,
				fetchedAt: fetchedAt,
				pricePerPremiumRequest: pricePerPremiumRequest,
				plans: plans.map { plan in
					Plan(
						id: CopilotPlanCatalog.normalizePlanId(plan.id),
						name: plan.name,
						includedPremiumRequestsPerMonth: max(0, plan.includedPremiumRequestsPerMonth)
					)
				}
			)
		}
	}

	enum Error: Swift.Error, CustomStringConvertible {
		case resourceNotFound(String)
		case invalidData
		case decodingFailed(String)

		var description: String {
			switch self {
			case .resourceNotFound(let name):
				return "Bundled plan resource not found: \(name)"
			case .invalidData:
				return "Bundled plan resource was empty or invalid."
			case .decodingFailed(let message):
				return "Failed to decode bundled plan resource: \(message)"
			}
		}
	}

	/// Resource path inside the bundled `Resources` directory.
	static let bundledResourcePath = "generated/copilot-plans.json"

	/// Embedded fallback plan mapping (matches VS Code extension defaults).
	private static let fallbackPlans: [Plan] = [
		Plan(id: "copilot-free", name: "Copilot Free", includedPremiumRequestsPerMonth: 50),
		Plan(id: "copilot-pro", name: "Copilot Pro", includedPremiumRequestsPerMonth: 300),
		Plan(id: "copilot-proplus", name: "Copilot Pro+", includedPremiumRequestsPerMonth: 1500),
		Plan(id: "copilot-business", name: "Copilot Business", includedPremiumRequestsPerMonth: 300),
		Plan(id: "copilot-enterprise", name: "Copilot Enterprise", includedPremiumRequestsPerMonth: 1000)
	]

	/// Loads and decodes the bundled plan file.
	///
	/// - Note: This is intentionally strict: if the JSON is missing or cannot be decoded,
	///   it throws so the caller can fall back to safe defaults and/or show a diagnostic.
	static func loadBundled() throws -> BundleFile {
		guard let url = resolveBundledPlanURL() else {
			throw Error.resourceNotFound(bundledResourcePath)
		}

		let data = try Data(contentsOf: url)
		guard !data.isEmpty else { throw Error.invalidData }

		do {
			let decoded = try JSONDecoder().decode(BundleFile.self, from: data)
			return decoded.normalized()
		} catch {
			throw Error.decodingFailed(String(describing: error))
		}
	}

	/// Returns all available plans (sorted by name).
	///
	/// Priority:
	/// 1) Bundled JSON (if loadable)
	/// 2) Embedded fallback list (always present)
	static func listPlansBestEffort() -> [Plan] {
		let plans: [Plan]
		do {
			plans = try loadBundled().plans
		} catch {
			plans = fallbackPlans
		}
		return plans.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// Looks up a single plan by ID (case/format-insensitive).
	static func findPlanBestEffort(id: String) -> Plan? {
		let wanted = normalizePlanId(id)
		guard !wanted.isEmpty else { return nil }

		// Avoid calling listPlansBestEffort() twice.
		let plans = listPlansBestEffort()
		return plans.first { normalizePlanId($0.id) == wanted }
	}

	/// Default per-premium-request price suggested by the bundled file, if present.
	/// Falls back to the known default used throughout the project.
	static func bundledPricePerPremiumRequestBestEffort() -> Double? {
		let price = (try? loadBundled().pricePerPremiumRequest) ?? nil
		if let v = price, v.isFinite, v > 0 { return v }
		return 0.04
	}

	// MARK: - Resource location

	private static func resolveBundledPlanURL() -> URL? {
		// 1) Preferred: resource embedded in an app bundle (Xcode / exported .app).
		//    Look for Resources/generated/copilot-plans.json.
		let appBundle = Bundle.main
		if let url = appBundle.url(forResource: "copilot-plans", withExtension: "json", subdirectory: "generated") {
			return url
		}
		if let url = appBundle.url(forResource: "copilot-plans", withExtension: "json") {
			return url
		}

		// 2) Fallback: when running from `swift run` / SwiftPM build output, Bundle.main
		//    is often the executable directory. Attempt to locate Resources/generated relative to it.
		let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)
			.deletingLastPathComponent()

		let candidates: [URL] = [
			exeDir.appendingPathComponent("Resources/generated/copilot-plans.json"),
			exeDir.appendingPathComponent("../Resources/generated/copilot-plans.json"),
			exeDir.appendingPathComponent("../../Resources/generated/copilot-plans.json")
		].map { $0.standardizedFileURL }

		for url in candidates where FileManager.default.fileExists(atPath: url.path) {
			return url
		}

		return nil
	}

	/// Attempt to normalize plan IDs so that:
	/// - "Copilot Pro+" => "copilot-proplus"
	/// - "copilot-pro-plus" => "copilot-proplus"
	/// - " copilot-proplus " => "copilot-proplus"
	static func normalizePlanId(_ raw: String) -> String {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "" }

		// Lowercase, remove common separators, and normalize plus symbols.
		let lower = trimmed.lowercased()
		let noSpaces = lower.replacingOccurrences(of: " ", with: "")
		let noDashes = noSpaces.replacingOccurrences(of: "-", with: "")
		let noUnderscores = noDashes.replacingOccurrences(of: "_", with: "")
		let normalizedPlus = noUnderscores.replacingOccurrences(of: "+", with: "plus")

		return normalizedPlus
	}
}
