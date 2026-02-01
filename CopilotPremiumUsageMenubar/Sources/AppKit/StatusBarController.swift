import AppKit
import SwiftUI
import CopilotPremiumUsageMenubarCore

private let CPUMPopoverMaxHeight: CGFloat = 340
private let CPUMPopoverPreferredWidth: CGFloat = 360

// Menubar gauge rendering
private let CPUMGaugeImagePointSize: CGFloat = 22
private let CPUMGaugeStrokeWidth: CGFloat = 2

// Menubar warning indicator overlay
private let CPUMGaugeWarnBadgeDiameter: CGFloat = 8

/// Owns the macOS menubar item (`NSStatusItem`) and its popover.
///
/// Responsibilities:
/// - Create a status bar item with a button (text-only for now).
/// - Present an `NSPopover` hosting SwiftUI content.
/// - Update the menubar title based on the latest `UsageViewState` + user preferences.
@MainActor
public final class StatusBarController: NSObject, ObservableObject {
	private let statusItem: NSStatusItem
	private let popover: NSPopover
	private let popoverDelegate: PopoverDelegate

	@Published public private(set) var isPopoverShown: Bool = false

	/// The latest computed view state. Setting this updates the menubar title/tooltip.
	public var viewState: UsageViewState? {
		didSet { refreshStatusBarPresentation() }
	}

	/// Preferences drive how the title is rendered (budget vs included, etc.)
	private let preferences: Preferences

	/// A callback for when the user selects "Quit" (or other menu items later).
	private let onQuit: () -> Void

	/// Create a status bar controller.
	///
	/// - Parameters:
	///   - preferences: Shared preferences wrapper.
	///   - rootView: SwiftUI view to host in the popover.
	///   - onQuit: Called when quitting; defaults to terminating the app.
	public init<RootView: View>(
		preferences: Preferences = .shared,
		rootView: RootView,
		onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
	) {
		self.preferences = preferences
		self.onQuit = { @MainActor in onQuit() }

		self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		self.popover = NSPopover()
		self.popoverDelegate = PopoverDelegate()

		super.init()

		configureStatusItem()
		configurePopover(with: rootView)
		refreshStatusBarPresentation()
	}

	// MARK: - Setup

	private func configureStatusItem() {
		guard let button = statusItem.button else { return }

		// Default title before we have data.
		button.title = ""
		button.imagePosition = .imageOnly
		button.image = makeGaugeImage(gaugeValue: nil, tint: .labelColor, template: true, showsWarningBadge: false)
		button.toolTip = "Copilot Premium Usage"

		button.target = self
		button.action = #selector(togglePopover(_:))

		// Optional: make the button slightly more clickable.
		button.sendAction(on: [.leftMouseUp, .rightMouseUp])
	}

	private func configurePopover<RootView: View>(with rootView: RootView) {
		popover.behavior = .transient
		popover.delegate = popoverDelegate

		let hosting = NSHostingController(rootView: rootView)

		// Let SwiftUI determine the natural height, but cap it so the popover can't render off-screen.
		// This avoids the top edge being clipped on shorter displays / when the user has large text sizes.
		hosting.view.translatesAutoresizingMaskIntoConstraints = false

		popover.contentViewController = hosting
		popover.contentSize = NSSize(width: CPUMPopoverPreferredWidth, height: CPUMPopoverMaxHeight)

		// Track popover open/close to keep state in sync.
		popoverDelegate.onDidShow = { [weak self] in self?.isPopoverShown = true }
		popoverDelegate.onDidClose = { [weak self] in self?.isPopoverShown = false }
	}

	// MARK: - Actions

	@objc private func togglePopover(_ sender: Any?) {
		if popover.isShown {
			closePopover(sender)
		} else {
			showPopover(sender)
		}
	}

	public func showPopover(_ sender: Any?) {
		guard let button = statusItem.button else { return }

		// Before showing, ask SwiftUI for its best-fitting size, then clamp the height so it never
		// extends beyond the top edge of the screen.
		if let hosting = popover.contentViewController as? NSHostingController<AnyView> {
			// This branch is unlikely with our current generic hosting controller; keep as a safe fallback.
			let fit = hosting.sizeThatFits(in: NSSize(width: CPUMPopoverPreferredWidth, height: .greatestFiniteMagnitude))
			let clamped = NSSize(width: CPUMPopoverPreferredWidth, height: min(CPUMPopoverMaxHeight, fit.height))
			popover.contentSize = clamped
		} else if let hosting = popover.contentViewController {
			// Best-effort sizing: use the current view fitting size if available.
			let fit = hosting.view.fittingSize
			let height = fit.height > 0 ? fit.height : CPUMPopoverMaxHeight
			popover.contentSize = NSSize(width: CPUMPopoverPreferredWidth, height: min(CPUMPopoverMaxHeight, height))
		} else {
			popover.contentSize = NSSize(width: CPUMPopoverPreferredWidth, height: CPUMPopoverMaxHeight)
		}

		// Position the popover under the status item.
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

		// Ensure we become key so fields in the popover can receive focus.
		NSApp.activate(ignoringOtherApps: true)
	}

	public func closePopover(_ sender: Any?) {
		popover.performClose(sender)
	}

	// MARK: - Menubar Presentation

	private func refreshStatusBarPresentation() {
		guard let button = statusItem.button else { return }

		guard let state = viewState else {
			button.title = ""
			button.imagePosition = .imageOnly
			button.image = makeGaugeImage(gaugeValue: nil, tint: .labelColor, template: true, showsWarningBadge: false)
			button.toolTip = "No usage data yet. Open to configure token and refresh."
			return
		}

		let gaugeValue = makeGaugeValue(from: state, preferences: preferences)
		let showsWarning = shouldShowWarningBadge(for: state)

		button.title = ""
		button.imagePosition = .imageOnly
		button.image = makeGaugeImage(gaugeValue: gaugeValue, tint: .labelColor, template: true, showsWarningBadge: showsWarning)

		button.toolTip = makeTooltip(from: state, preferences: preferences)
	}

	private struct GaugeValue {
		/// Value shown in the center of the gauge. Can exceed 100 once we enter budget/overage phase.
		let displayNumber: Int

		/// Progress arc fraction (0...1) rendered around the ring.
		///
		/// We always render the ring as "how far through the current phase":
		/// - included phase: included % (0...1)
		/// - budget phase: budget % (0...1)
		let ringProgress: Double
	}

	private func makeGaugeValue(from state: UsageViewState, preferences: Preferences) -> GaugeValue {
		// Menubar metric behavior is controlled by Preferences.MenubarDisplayMode:
		// - budgetPercent: always show Budget % (0...100)
		// - includedPercent: always show Included % (0...100)
		// - includedThenBudgetCombined: show Included % until included is exhausted, then show
		//   Included % + Budget % (so the number can exceed 100 once in budget/overage phase)
		//
		// Rendering behavior:
		// - The center number follows the selected display mode.
		// - The ring shows the corresponding phase progress for that chosen mode (clamped 0...1).
		let includedPercent = UsageCalculations.clampPercent(state.includedPercent)
		let budgetPercent = UsageCalculations.clampPercent(state.budgetPercent)

		switch preferences.menubarDisplayMode {
		case .budgetPercent:
			return GaugeValue(
				displayNumber: Int(round(budgetPercent)),
				ringProgress: max(0, min(1, budgetPercent / 100.0))
			)

		case .includedPercent:
			return GaugeValue(
				displayNumber: Int(round(includedPercent)),
				ringProgress: max(0, min(1, includedPercent / 100.0))
			)

		case .includedThenBudgetCombined:
			switch state.phase {
			case .included:
				return GaugeValue(
					displayNumber: Int(round(includedPercent)),
					ringProgress: max(0, min(1, includedPercent / 100.0))
				)
			case .budget:
				return GaugeValue(
					displayNumber: 100 + Int(round(budgetPercent)),
					ringProgress: max(0, min(1, budgetPercent / 100.0))
				)
			}
		}
	}

	private func shouldShowWarningBadge(for state: UsageViewState) -> Bool {
		switch state.health {
		case .warning, .danger, .error:
			return true
		case .ok, .stale:
			return false
		}
	}

	private func makeGaugeImage(gaugeValue: GaugeValue?, tint: NSColor, template: Bool, showsWarningBadge: Bool) -> NSImage {
		let size = NSSize(width: CPUMGaugeImagePointSize, height: CPUMGaugeImagePointSize)

		let img = NSImage(size: size)
		// Template images are tinted by the system to match menubar foreground color.
		img.isTemplate = template

		img.lockFocus()
		defer { img.unlockFocus() }

		let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
		let center = NSPoint(x: rect.midX, y: rect.midY)
		let radius = min(rect.width, rect.height) / 2.0 - CPUMGaugeStrokeWidth

		// Background ring
		let bgPath = NSBezierPath()
		bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
		bgPath.lineWidth = CPUMGaugeStrokeWidth
		NSColor.tertiaryLabelColor.setStroke()
		bgPath.stroke()

		// Foreground arc (phase progress)
		if let gaugeValue {
			let clampedProgress = max(0, min(1, gaugeValue.ringProgress))
			if clampedProgress > 0 {
				let startAngle: CGFloat = 90 // top
				let endAngle: CGFloat = startAngle - (CGFloat(clampedProgress) * 360.0)

				let fgPath = NSBezierPath()
				fgPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
				fgPath.lineWidth = CPUMGaugeStrokeWidth
				fgPath.lineCapStyle = .round
				tint.setStroke()
				fgPath.stroke()
			}
		}

		// Center text (combined value; can exceed 100 in budget/overage phase)
		let text: String = {
			guard let gaugeValue else { return "—" }
			let value = max(0, gaugeValue.displayNumber)
			return "\(value)"
		}()

		// Use a slightly smaller font when we have 3+ digits to keep it readable in 22pt.
		let fontSize: CGFloat = (text.count >= 3) ? 6.5 : 7.0

		let attrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
			.foregroundColor: NSColor.labelColor
		]

		let textSize = (text as NSString).size(withAttributes: attrs)
		let textRect = NSRect(
			x: rect.midX - textSize.width / 2.0,
			y: rect.midY - textSize.height / 2.0 - 0.5,
			width: textSize.width,
			height: textSize.height
		)
		(text as NSString).draw(in: textRect, withAttributes: attrs)

		// Optional warning badge overlay ("!" in a small circle)
		if showsWarningBadge {
			let badge = NSRect(
				x: rect.maxX - CPUMGaugeWarnBadgeDiameter - 0.5,
				y: rect.minY + 0.5,
				width: CPUMGaugeWarnBadgeDiameter,
				height: CPUMGaugeWarnBadgeDiameter
			)

			let badgePath = NSBezierPath(ovalIn: badge)
			NSColor.labelColor.setStroke()
			NSColor.windowBackgroundColor.setFill()
			badgePath.lineWidth = 1
			badgePath.fill()
			badgePath.stroke()

			let bang = "!"
			let bangAttrs: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 7, weight: .heavy),
				.foregroundColor: NSColor.labelColor
			]
			let bangSize = (bang as NSString).size(withAttributes: bangAttrs)
			let bangRect = NSRect(
				x: badge.midX - bangSize.width / 2.0,
				y: badge.midY - bangSize.height / 2.0 - 0.5,
				width: bangSize.width,
				height: bangSize.height
			)
			(bang as NSString).draw(in: bangRect, withAttributes: bangAttrs)
		}

		return img
	}

	private func makeTooltip(from state: UsageViewState, preferences: Preferences) -> String {
		var lines: [String] = []

		lines.append("Copilot Premium Usage")
		lines.append("Period: \(state.month.displayName)")

		// Always include both metrics, regardless of primary display.
		let spend = String(format: "$%.2f", state.spendUsd)
		let budget = String(format: "$%.2f", state.budgetUsd)
		lines.append("Spend: \(spend) / \(budget) (\(String(format: "%.1f", UsageCalculations.clampPercent(state.budgetPercent)))%)")

		if state.includedTotal > 0 {
			lines.append("Included: \(state.includedUsed) / \(state.includedTotal) (\(String(format: "%.1f", UsageCalculations.clampPercent(state.includedPercent)))%)")
		} else {
			lines.append("Included: (not available)")
		}

		if let lastRefresh = state.lastRefreshAt {
			let fmt = DateFormatter()
			fmt.locale = Locale(identifier: "en_US_POSIX")
			fmt.timeZone = TimeZone.current
			fmt.dateStyle = .medium
			fmt.timeStyle = .short
			lines.append("Last refresh: \(fmt.string(from: lastRefresh))")
		} else {
			lines.append("Last refresh: (never)")
		}

		if let err = state.lastErrorMessage, !err.isEmpty {
			lines.append("Error: \(err)")
		}

		return lines.joined(separator: "\n")
	}

	// MARK: - Optional right-click menu

	/// You can call this if you want to support right-click actions.
	/// For now it provides a minimal Quit entry.
	public func installRightClickMenu() {
		let menu = NSMenu()

		let refreshItem = NSMenuItem(title: "Refresh", action: #selector(onRefreshMenu(_:)), keyEquivalent: "r")
		refreshItem.target = self
		menu.addItem(refreshItem)

		menu.addItem(NSMenuItem.separator())

		let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuitMenu(_:)), keyEquivalent: "q")
		quitItem.target = self
		menu.addItem(quitItem)

		statusItem.menu = menu
	}

	@objc private func onQuitMenu(_ sender: Any?) {
		onQuit()
	}

	/// Placeholder: wire this up to your app coordinator / refresh controller.
	/// In the first cut, the popover UI can own refresh. This is here if you later want
	/// a menu-based refresh.
	@objc private func onRefreshMenu(_ sender: Any?) {
		// Intentionally left blank; coordinator can inject a handler later.
		NSApp.activate(ignoringOtherApps: true)
	}

	// MARK: - Popover delegate

	private final class PopoverDelegate: NSObject, NSPopoverDelegate {
		var onDidShow: (() -> Void)?
		var onDidClose: (() -> Void)?

		func popoverDidShow(_ notification: Notification) {
			onDidShow?()
		}

		func popoverDidClose(_ notification: Notification) {
			onDidClose?()
		}

		func popoverShouldClose(_ popover: NSPopover) -> Bool {
			return true
		}
	}
}
