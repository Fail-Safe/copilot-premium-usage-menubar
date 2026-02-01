// SPDX-License-Identifier: MIT
//
// Copilot Premium Requests — macOS menubar app
//
// This file is part of Copilot Premium Usage Menubar.
// See the root LICENSE file for details.

import AppKit
import CopilotPremiumUsageMenubarAppKit

/// App entrypoint for the menubar utility (SwiftPM executable).
///
/// This executable intentionally uses the SwiftPM runner mode:
/// - Starts the AppKit run loop
/// - Keeps the process alive (required for `swift run`)
///
/// The Xcode wrapper `.app` should *not* call this entrypoint; it should call
/// `MenubarAppRunner.bootstrapFromWrapperApp()` from its SwiftUI `@main`.
MenubarAppRunner.runAsSwiftPMExecutable()
