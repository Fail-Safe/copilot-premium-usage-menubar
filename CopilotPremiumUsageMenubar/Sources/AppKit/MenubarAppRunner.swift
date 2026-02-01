// SPDX-License-Identifier: MIT
//
// Copilot Premium Requests — macOS menubar app
//
// This file is part of Copilot Premium Usage Menubar.
// See the root LICENSE file for details.

import AppKit
import SwiftUI

/// Reusable entrypoints for launching the menubar app in two different hosting modes.
///
/// Why there are *two* modes:
/// - **SwiftPM (`swift run`)** is convenient for iteration, but there is no SwiftUI `@main App` driving
///   the process. In this mode we must start an AppKit run loop ourselves and keep the process alive.
/// - **Xcode wrapper `.app`** already has a SwiftUI app lifecycle (and a proper bundle). In this mode,
///   starting another run loop (`NSApplication.run()` + `dispatchMain()`) can interfere with Swift
///   concurrency scheduling and event delivery (symptoms: actions appear to hang, tasks never start).
///
/// Use:
/// - SwiftPM executable `main.swift`: call `MenubarAppRunner.runAsSwiftPMExecutable()`
/// - Xcode wrapper app `@main App`: call `MenubarAppRunner.bootstrapFromWrapperApp()`
public enum MenubarAppRunner {

	/// SwiftPM mode: start the AppKit app lifecycle + run loop and keep the process alive.
	///
	/// This is appropriate for:
	/// - `swift run CopilotPremiumUsageMenubarApp`
	///
	/// It is *not* appropriate to call this from an Xcode SwiftUI wrapper app, because it can
	/// introduce nested run-loop / dispatch-main conflicts.
	public static func runAsSwiftPMExecutable() {
		DispatchQueue.main.async {
			// Menubar-only feel.
			NSApplication.shared.setActivationPolicy(.accessory)

			// Wire up the delegate (creates menubar item + popover).
			let delegate = MenubarAppDelegate()
			NSApplication.shared.delegate = delegate

			// Start the run loop (blocking call).
			NSApplication.shared.run()
		}

		// Keep the process alive until AppKit takes over.
		// (Required for SwiftPM executables; there is no SwiftUI App lifecycle managing the main run loop.)
		dispatchMain()
	}

	/// Wrapper mode: bootstrap the menubar UI *without* starting another run loop.
	///
	/// This is appropriate for:
	/// - an Xcode SwiftUI wrapper app target (`@main struct ...: App`)
	///
	/// In wrapper mode, the SwiftUI app lifecycle already owns the main run loop, so we only
	/// install our AppKit delegate/UI and return.
	@MainActor
	public static func bootstrapFromWrapperApp() {
		// Menubar-only policy. Wrapper may also enforce LSUIElement in Info.plist.
		NSApplication.shared.setActivationPolicy(.accessory)

		// Important: the delegate must be retained, otherwise it may be deallocated.
		// Keep it alive by storing it in the application object.
		let delegate: MenubarAppDelegate
		if let existing = NSApplication.shared.delegate as? MenubarAppDelegate {
			delegate = existing
		} else {
			let created = MenubarAppDelegate()
			NSApplication.shared.delegate = created
			delegate = created
		}

		// Force initial menubar UI setup even if AppKit has not yet delivered
		// `applicationDidFinishLaunching`. This makes wrapper-mode reliable when called
		// from SwiftUI `App.init()`.
		delegate.ensureSetupIfNeeded()

		// Ensure we also get called once the app finishes launching, in case wrapper-mode
		// is invoked extremely early and other AppKit state isn't ready yet.
		NotificationCenter.default.addObserver(
			forName: NSApplication.didFinishLaunchingNotification,
			object: NSApplication.shared,
			queue: .main
		) { _ in
			Task { @MainActor in
				delegate.ensureSetupIfNeeded()
			}
		}
	}
}

/// Internal app delegate used by both runner modes.
///
/// This is intentionally self-contained so a wrapper app can invoke the same behavior
/// without duplicating UI wiring logic.
@MainActor
final class MenubarAppDelegate: NSObject, NSApplicationDelegate {

	private var didSetup = false

	private var statusBarController: StatusBarController?
	private var appModel: AppModel?

	/// Strong reference so SwiftUI actions remain wired.
	private var appController: AppController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// In SwiftPM mode, this will be called after `NSApplication.run()` starts.
		// In wrapper mode, this will be called by the wrapper's lifecycle.
		ensureSetupIfNeeded()
	}

	/// Idempotent setup so wrapper-mode can call it safely.
	func ensureSetupIfNeeded() {
		guard !didSetup else { return }
		didSetup = true

		// Create the model (refresh, token handling, state computation, notifications).
		let model = AppModel()
		self.appModel = model

		// Create the app controller (no polling; uses explicit callbacks).
		let controller = AppController(model: model)
		self.appController = controller

		let contentView = PopoverView()
			.environmentObject(controller)

		// Create the menubar item + popover host.
		let sb = StatusBarController(rootView: contentView) { @MainActor in
			NSApplication.shared.terminate(nil)
		}
		self.statusBarController = sb

		// Keep menubar title up to date when state changes.
		controller.onViewStateChanged = { [weak sb] newState in
			Task { @MainActor in
				sb?.viewState = newState
			}
		}

		// Seed initial title/tool-tip.
		sb.viewState = model.state

		// Add a startup diagnostic to make it obvious the UI wiring is live.
		model.appendDiagnostic(.info("Menubar app launched; UI wired"))

		// Startup refresh + timer scheduling are owned by `AppModel`.
		//
		// Rationale:
		// - Prevent duplicate refreshes/scheduling when both the runner and model try to "help".
		// - Keep lifecycle policy in one place (AppModel handles token-missing pause, wake refresh, timer resets).

		// Menubar-only feel.
		NSApp.setActivationPolicy(.accessory)
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		// If the user somehow "reopens" the app, show the popover for convenience.
		statusBarController?.showPopover(nil)
		return true
	}
}
