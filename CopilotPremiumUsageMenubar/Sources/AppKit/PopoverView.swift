import SwiftUI
import CopilotPremiumUsageMenubarCore

private let cpumDidAutoPromptForTokenKey = "cpum.didAutoPromptForToken"

/// Main popover UI shown when the user clicks the menubar item.
///
/// This view is intentionally compact and focused:
/// - Shows current usage (both Budget % and Included %)
/// - Allows refresh
/// - Allows quick token management actions
/// - Exposes settings controls (metric toggle, thresholds, refresh interval, budget override)
///
/// Notes:
/// - Token storage is in Keychain; this view delegates to an `AppController` for actions.
/// - Preferences are modeled via `Preferences` (UserDefaults-backed).
struct PopoverView: View {

	private func refreshButtonLabel() -> String {
		if app.isRefreshing { return "Refreshing…" }

		// Manual cooldown countdown (rapid-click protection)
		let s = app.manualRefreshCooldownRemainingSeconds
		if s > 0 { return "Refresh (\(s)s)" }

		// Rate-limit countdown (GitHub throttling/backoff)
		if let until = app.nextAllowedAutoRefreshAt, until > Date() {
			let remaining = Int(ceil(until.timeIntervalSinceNow))
			return "Refresh (\(remaining)s)"
		}

		return "Refresh"
	}
	@EnvironmentObject private var app: AppController
	@ObservedObject private var prefs = Preferences.shared

	@State private var showClearIncludedOverridePrompt: Bool = false
	@State private var pendingSelectedPlanId: String = ""

	@State private var didAttemptAutoPromptForTokenThisSession: Bool = false

	@State private var isSettingsExpanded: Bool = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				header

				if !app.hasToken {
					tokenMissingBanner
					Divider()
				} else {
					Divider()
				}

				usageSection

				Divider()

				actionsSection

				Divider()

				// Only build these sections when expanded to reduce steady-state view work.
				settingsSection

				Divider()

				// Diagnostics are only useful when troubleshooting; hide unless Debug Mode is enabled.
				if prefs.debugModeEnabled {
					diagnosticsSection
					Divider()
				}

				footerSection
			}
			.padding(12)
			.frame(width: 360)
		}
		.onAppear {
			// Lightweight refresh-on-open to keep the UI up to date without requiring a manual click.
			// This is safe because the controller can debounce.
			app.refreshIfStale()

			// One-time onboarding: if no token is configured, proactively open the Set Token prompt
			// the first time the user opens the popover.
			//
			// Guardrails:
			// - Only when token is missing
			// - Only once per app install (persisted)
			// - Only once per popover session (prevents repeat prompts if view re-renders)
			// On first-run, default Settings to expanded to help onboarding.
			// After the first run, default to collapsed to avoid rendering controls unnecessarily.
			if UserDefaults.standard.bool(forKey: cpumDidAutoPromptForTokenKey) == false {
				isSettingsExpanded = true
			}

			if !app.hasToken,
			   !didAttemptAutoPromptForTokenThisSession,
			   UserDefaults.standard.bool(forKey: cpumDidAutoPromptForTokenKey) == false {
				didAttemptAutoPromptForTokenThisSession = true
				UserDefaults.standard.set(true, forKey: cpumDidAutoPromptForTokenKey)

				DispatchQueue.main.async {
					app.promptSetToken()
				}
			}
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Copilot Premium Usage")
					.font(.headline)

				Text(app.viewState?.month.displayName ?? YearMonth.currentUTC().displayName)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}

			Spacer()

			StatusPill(health: app.viewState?.health)
		}
	}

	// MARK: - Usage

	private var usageSection: some View {
		let state = app.viewState

		return VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline) {
				Text("Status")
					.font(.subheadline.weight(.semibold))
				Spacer()
				if app.isRefreshing {
					ProgressView()
						.controlSize(.small)
				}
			}

			if let state {
				usageRows(for: state)
			} else if !app.hasToken {
				EmptyStateView(
					title: "GitHub token required",
					message: "Set a GitHub Personal Access Token (PAT) to fetch your Copilot billing usage."
				)
			} else {
				EmptyStateView(
					title: "No data yet",
					message: app.lastErrorMessage ?? "Click Refresh to fetch your usage."
				)
			}

			if let err = app.lastErrorMessage, !err.isEmpty {
				Text(err)
					.font(.caption)
					.foregroundStyle(.red)
					.textSelection(.enabled)
					.lineLimit(4)
			}
		}
	}

	private var tokenMissingBanner: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)

				Text("GitHub token required")
					.font(.subheadline.weight(.semibold))

				Spacer()

				Button {
					app.promptSetToken()
				} label: {
					Label("Set Token…", systemImage: "key")
				}
				.controlSize(.small)
			}

			Text("Add a GitHub Personal Access Token (PAT) to fetch your Copilot billing usage. Token is stored securely in Keychain.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(3)
		}
		.padding(10)
		.background(Color.orange.opacity(0.12))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.orange.opacity(0.25), lineWidth: 1)
		)
		.clipShape(RoundedRectangle(cornerRadius: 10))
	}

	@ViewBuilder
	private func usageRows(for state: UsageViewState) -> some View {
		// Budget row
		VStack(alignment: .leading, spacing: 6) {
			MetricRow(
				title: "Budget",
				primaryText: String(format: "%.0f%%", state.budgetPercent),
				secondaryText: String(format: "$%.2f / $%.2f", state.spendUsd, state.budgetUsd),
				progress: state.budgetPercent / 100.0,
				tint: budgetTint(for: state)
			)

			// Included row:
			// - If we have an included limit (plan/override), show % + used/limit meter.
			// - If not, show "used / —" with a muted bar (we can't compute % without a limit).
			if state.includedTotal > 0 {
				MetricRow(
					title: "Included",
					primaryText: String(format: "%.0f%%", state.includedPercent),
					secondaryText: "\(state.includedUsed) / \(state.includedTotal)",
					progress: state.includedPercent / 100.0,
					tint: .blue
				)
			} else {
				MetricRow(
					title: "Included",
					primaryText: "—",
					secondaryText: "\(state.includedUsed) / —",
					progress: 0,
					tint: .blue.opacity(0.25)
				)
				.opacity(0.7)
			}

			if let source = app.includedLimitSourceLabel, !source.isEmpty {
				Text(source)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.textSelection(.enabled)
			}

			HStack(spacing: 8) {
				Text("Phase:")
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(state.phase == .included ? "Included" : "Budget")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)

				Spacer()

				if let ts = state.lastRefreshAt {
					HStack(spacing: 4) {
						Text("Synced")
						RelativeTimeText(date: ts)
						Text("ago")
					}
					.font(.caption)
					.foregroundStyle(.secondary)
				} else {
					Text("Not synced yet")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private func budgetTint(for state: UsageViewState) -> Color {
		switch state.health {
		case .danger: return .red
		case .warning: return .yellow
		case .error: return .red
		case .stale: return .orange
		case .ok: return .green
		}
	}

	// MARK: - Actions

	private var actionsSection: some View {
		DisclosureGroup {
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 8) {
					Button {
						app.refreshNow()
					} label: {
						Label(refreshButtonLabel(), systemImage: "arrow.clockwise")
					}
					.disabled(!app.canManuallyRefresh)
					.keyboardShortcut("r", modifiers: [.command])

					Spacer()

					Menu {
						Button {
							app.promptSetToken()
						} label: {
							Label("Set / Update Token…", systemImage: "key")
						}

						Button {
							app.testTokenNow()
						} label: {
							Label("Test Token", systemImage: "checkmark.shield")
						}
						.disabled(!app.hasToken)

						Button(role: .destructive) {
							app.clearToken()
						} label: {
							Label("Clear Token", systemImage: "trash")
						}
						.disabled(!app.hasToken)

						Divider()

						Button {
							app.openGitHubBudgetsPage()
						} label: {
							Label("Open GitHub Budgets", systemImage: "link")
						}
					} label: {
						Label("More", systemImage: "ellipsis.circle")
					}
				}

				Text("Tip: Use Diagnostics to view and copy recent event logs for troubleshooting.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
		} label: {
			HStack(spacing: 8) {
				Text("Actions")
					.font(.subheadline.weight(.semibold))
				Spacer()
			}
		}
		.disclosureGroupStyle(.automatic)
	}

	private func levelBadge(for level: AppModel.DiagnosticEvent.Level) -> String {
		switch level {
		case .info: return "INFO"
		case .warn: return "WARN"
		case .error: return "ERROR"
		}
	}

	private func color(for level: AppModel.DiagnosticEvent.Level) -> Color {
		switch level {
		case .info: return .secondary
		case .warn: return .orange
		case .error: return .red
		}
	}

	// MARK: - Settings

	private var settingsSection: some View {
		DisclosureGroup(isExpanded: $isSettingsExpanded) {
			if isSettingsExpanded {
				VStack(alignment: .leading, spacing: 10) {
				// Primary metric toggle (Budget vs Included)
				HStack {
					Text("Menubar metric")
					Spacer()
					Picker("", selection: $prefs.menubarDisplayMode) {
						Text(Preferences.MenubarDisplayMode.budgetPercent.displayName)
							.tag(Preferences.MenubarDisplayMode.budgetPercent)
						Text(Preferences.MenubarDisplayMode.includedPercent.displayName)
							.tag(Preferences.MenubarDisplayMode.includedPercent)
						Text(Preferences.MenubarDisplayMode.includedThenBudgetCombined.displayName)
							.tag(Preferences.MenubarDisplayMode.includedThenBudgetCombined)
					}
					.labelsHidden()
					.frame(width: 260)
					.onChange(of: prefs.menubarDisplayMode) { _ in
						app.updateMenubarTitle()
					}
				}

				Text("Menubar shows Included % until you exhaust included requests, then shows 100 + Budget % (so the value can exceed 100 during overage).")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(3)

				// Included Premium Requests (manual override + built-in plan)
				//
				// GitHub does not expose a public API for personal Copilot subscription level (Pro/Pro+/etc),
				// so select a built-in plan and/or set a custom included limit.
				VStack(alignment: .leading, spacing: 6) {
					HStack {
						Text("Copilot plan")
						Spacer()
						Picker("", selection: $prefs.selectedPlanId) {
							Text("(Select built-in plan)").tag("")
							ForEach(CopilotPlanCatalog.listPlansBestEffort()) { plan in
								Text("\(plan.name) (\(plan.includedPremiumRequestsPerMonth) included)").tag(plan.id)
							}
						}
						.labelsHidden()
						.frame(width: 260)
						.onChange(of: prefs.selectedPlanId) { newPlanId in
							// Mirrors VS Code extension UX:
							// If a plan is selected while a custom included override is set, prompt to clear it
							// so the plan value can take effect.
							let customIncluded = prefs.includedPremiumRequestsOverride > 0
							let hasPlan = !newPlanId.isEmpty

							guard hasPlan, customIncluded else {
								app.recomputeViewState()
								app.updateMenubarTitle()
								return
							}

							pendingSelectedPlanId = newPlanId
							showClearIncludedOverridePrompt = true
						}
					}

					HStack {
						Text("Included premium requests")
						Spacer()
						TextField("", value: $prefs.includedPremiumRequestsOverride, format: .number)
							.multilineTextAlignment(.trailing)
							.frame(width: 120)
							.textFieldStyle(.roundedBorder)
							.onChange(of: prefs.includedPremiumRequestsOverride) { _ in
								// Mirrors VS Code extension priority:
								// custom includedPremiumRequests > selectedPlanId > billing-derived (if available)
								app.recomputeViewState()
								app.updateMenubarTitle()
							}
					}

					Text("Optional: Manually specify the number of included premium requests per month for your plan. Set to 0 to use a selected built-in plan or the estimated value.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.confirmationDialog(
					"Use plan limit instead of custom value?",
					isPresented: $showClearIncludedOverridePrompt,
					titleVisibility: .visible
				) {
					Button("Use plan") {
						prefs.includedPremiumRequestsOverride = 0
						prefs.selectedPlanId = pendingSelectedPlanId
						app.recomputeViewState()
						app.updateMenubarTitle()
					}
					Button("Keep custom value", role: .cancel) {
						// Revert plan selection so the custom value continues to apply.
						prefs.selectedPlanId = ""
						app.recomputeViewState()
						app.updateMenubarTitle()
					}
				} message: {
					Text("You have a custom Included premium requests value set. Clear it to let the selected plan’s included limit apply?")
				}

				// Budget mode + manual override dollars
				VStack(alignment: .leading, spacing: 6) {
					HStack {
						Text("Budget source")
						Spacer()
						Picker("", selection: $prefs.budgetMode) {
							Text(Preferences.BudgetMode.manualOverride.displayName).tag(Preferences.BudgetMode.manualOverride)
							Text(Preferences.BudgetMode.fetchFromGitHubIfAvailable.displayName).tag(Preferences.BudgetMode.fetchFromGitHubIfAvailable)
						}
						.labelsHidden()
						.frame(width: 220)
					}

					HStack {
						Text("Manual budget (USD)")
						Spacer()
						TextField("", value: $prefs.manualBudgetDollars, format: .number.precision(.fractionLength(2)))
							.multilineTextAlignment(.trailing)
							.frame(width: 120)
							.textFieldStyle(.roundedBorder)
							.onChange(of: prefs.manualBudgetDollars) { _ in
								app.recomputeViewState()
								app.updateMenubarTitle()
							}
					}

					Text("Tip: If GitHub budget fetch isn’t available, Manual is used.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				// Refresh interval
				HStack {
					Text("Refresh interval")
					Spacer()
					Picker("", selection: $prefs.refreshIntervalMinutes) {
						ForEach(Preferences.allowedRefreshIntervalsMinutesEffective, id: \.self) { minutes in
							Text(refreshIntervalLabel(minutes: minutes)).tag(minutes)
						}
					}
					.labelsHidden()
					.frame(width: 180, alignment: .trailing)
					.onChange(of: prefs.refreshIntervalMinutes) { _ in
						app.restartAutoRefresh()
					}
				}

				// Thresholds
				VStack(alignment: .leading, spacing: 8) {
					HStack {
						Text("Warn at")
						Spacer()
						ThresholdField(value: $prefs.warnAtPercent, suffix: "%", help: "Set to 0 to disable warning level.")
					}

					HStack {
						Text("Danger at")
						Spacer()
						ThresholdField(value: $prefs.dangerAtPercent, suffix: "%", help: "Set to 0 to disable danger level.")
					}

					Toggle(isOn: $prefs.notificationsEnabled) {
						Text("Enable notifications")
					}
					.onChange(of: prefs.notificationsEnabled) { newValue in
						app.setNotificationsEnabled(newValue)
					}

					Divider()
						.padding(.vertical, 4)

					Toggle(isOn: $prefs.debugModeEnabled) {
						Text("Debug mode")
					}

					Text("When enabled, the app keeps a larger diagnostics buffer and shows the Diagnostics section for troubleshooting.")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(3)
				}
				}
			}
		} label: {
			HStack(spacing: 8) {
				Text("Settings")
					.font(.subheadline.weight(.semibold))
				Spacer()
			}
		}
		.disclosureGroupStyle(.automatic)
	}

	// MARK: - Footer

	private var diagnosticsSection: some View {
		DisclosureGroup {
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 8) {
					Button {
						app.testTokenNow()
					} label: {
						Label("Test Token", systemImage: "checkmark.shield")
					}

					Spacer()

					if !app.diagnostics.isEmpty {
						Button {
							let text = app.diagnostics
								.suffix(200)
								.map { evt in
									let ts = DateFormatter.localizedString(from: evt.at, dateStyle: .none, timeStyle: .medium)
									return "\(ts) \(levelBadge(for: evt.level)) \(evt.message)"
								}
								.joined(separator: "\n")

							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(text, forType: .string)
						} label: {
							Label("Copy", systemImage: "doc.on.doc")
						}
						.controlSize(.small)
					}

					Button {
						app.refreshNow()
					} label: {
						Label(refreshButtonLabel(), systemImage: "arrow.clockwise")
					}
					.disabled(!app.canManuallyRefresh)
					.controlSize(.small)
				}

				if let msg = app.lastTokenTestResultMessage, !msg.isEmpty {
					Text(msg)
						.font(.caption)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
						.lineLimit(4)
				}

				if app.diagnostics.isEmpty {
					Text("No diagnostic events yet.")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					VStack(alignment: .leading, spacing: 6) {
						ForEach(app.diagnostics.suffix(12)) { evt in
							HStack(alignment: .firstTextBaseline, spacing: 8) {
								Text(evt.at, style: .time)
									.font(.caption.monospacedDigit())
									.foregroundStyle(.secondary)
									.frame(width: 60, alignment: .leading)

								Text(levelBadge(for: evt.level))
									.font(.caption.monospacedDigit().weight(.semibold))
									.foregroundStyle(color(for: evt.level))
									.frame(width: 44, alignment: .leading)

								Text(evt.message)
									.font(.caption)
									.foregroundStyle(.secondary)
									.textSelection(.enabled)
									.lineLimit(2)

								Spacer()
							}
						}
					}
					.padding(8)
					.background(Color.primary.opacity(0.06))
					.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
		} label: {
			HStack(spacing: 8) {
				Text("Diagnostics")
					.font(.subheadline.weight(.semibold))
				Spacer()
			}
		}
		.disclosureGroupStyle(.automatic)
	}




	private func refreshIntervalLabel(minutes: Int) -> String {
		if minutes < 60 { return "\(minutes) min" }
		if minutes == 60 { return "1 hr" }
		if minutes % 60 == 0 {
			let hours = minutes / 60
			return "\(hours) hr"
		}
		let hours = Double(minutes) / 60.0
		return String(format: "%.1f hr", hours)
	}

	private var footerSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Button("Reset settings") {
					prefs.resetToDefaults()
					app.restartAutoRefresh()
					app.recomputeViewState()
					app.updateMenubarTitle()
				}
				.buttonStyle(.link)

				Spacer()

				HStack(spacing: 6) {
					Text(appVersionString())
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
						.lineLimit(1)

					if !appVersionString().isEmpty {
						Button {
							let text = appVersionString()
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(text, forType: .string)
						} label: {
							Image(systemName: "doc.on.doc")
								.font(.caption)
						}
						.buttonStyle(.plain)
						.help("Copy version")
					}
				}

				Spacer()

				Button("Quit") {
					app.quit()
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
			}
		}
	}
}

// MARK: - Supporting Views

	private func appVersionString() -> String {
		let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
		let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

		let shortClean = short?.isEmpty == false ? short : nil
		let buildClean = build?.isEmpty == false ? build : nil

		#if DEBUG
		switch (shortClean, buildClean) {
		case let (s?, b?): return "v\(s) (\(b))"
		case let (s?, nil): return "v\(s)"
		case let (nil, b?): return "(\(b))"
		default: return ""
		}
		#else
		switch (shortClean, buildClean) {
		case let (s?, _): return "v\(s)"
		case let (nil, b?): return "\(b)"
		default: return ""
		}
		#endif
	}

	private struct MetricRow: View {
	let title: String
	let primaryText: String
	let secondaryText: String
	let progress: Double
	let tint: Color

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline) {
				Text(title)
					.font(.body.weight(.semibold))
				Spacer()
				Text(primaryText)
					.font(.body.monospacedDigit().weight(.semibold))
			}

			ProgressView(value: max(0, min(1, progress)))
				.progressViewStyle(.linear)
				.tint(tint)

			Text(secondaryText)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}
}

private struct StatusPill: View {
	let health: UsageViewState.Health?

	var body: some View {
		let (label, color): (String, Color) = {
			switch health {
			case .danger: return ("Danger", .red)
			case .warning: return ("Warning", .yellow)
			case .stale: return ("Stale", .orange)
			case .error: return ("Error", .red)
			case .ok, .none: return ("OK", .green)
			}
		}()

		return Text(label)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(color.opacity(0.18))
			.foregroundStyle(color)
			.clipShape(Capsule())
	}
}

private struct TokenStatusRow: View {
	let hasToken: Bool
	let detail: String?

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: hasToken ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
				.foregroundStyle(hasToken ? .green : .orange)

			Text(hasToken ? "Token set" : "Token missing")
				.font(.caption.weight(.semibold))

			if let detail, !detail.isEmpty {
				Text("• \(detail)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}

private struct ThresholdField: View {
	@Binding var value: Int
	let suffix: String
	let help: String

	var body: some View {
		HStack(spacing: 6) {
			TextField("", value: $value, format: .number)
				.multilineTextAlignment(.trailing)
				.frame(width: 56)
				.textFieldStyle(.roundedBorder)

			Text(suffix)
				.font(.caption)
				.foregroundStyle(.secondary)

			Text(help)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
	}
}

private struct EmptyStateView: View {
	let title: String
	let message: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.body.weight(.semibold))
			Text(message)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}
}

/// A small view that emits relative-time text.
/// This keeps the PopoverView pleasant without elevating this to a full "ticker" system yet.
private struct RelativeTimeText: View {
	let date: Date

	var body: some View {
		Text(date, style: .relative)
	}
}
