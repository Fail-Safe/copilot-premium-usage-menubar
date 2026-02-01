// SPDX-License-Identifier: MIT
//
// Copilot Premium Requests — macOS menubar app
//
// This file is part of Copilot Premium Usage Menubar.
// See the root LICENSE file for details.
//
//  CopilotPremiumUsageMenubarAppWrapperApp.swift
//  CopilotPremiumUsageMenubarAppWrapper
//
//  Created by Mark Baker on 1/31/26.
//
//  This wrapper exists purely to run the menubar app as a proper `.app` bundle
//  (stable bundle identifier, Info.plist, notifications, etc.).
//

import SwiftUI
import CopilotPremiumUsageMenubarAppKit

@main
struct CopilotPremiumUsageMenubarAppWrapperApp: App {
    /// No windows/scenes: this wrapper is menubar-only.
    var body: some Scene {
        // Intentionally empty — the menubar UI is created by `MenubarAppRunner`.
        Settings { EmptyView() }
    }

    init() {
        // Wrapper-mode bootstrap:
        // Do NOT start a second run loop from inside a SwiftUI `@main App`.
        // SwiftUI already owns the main run loop; we only need to install our AppKit delegate/UI.
        Task { @MainActor in
            MenubarAppRunner.bootstrapFromWrapperApp()
        }
    }
}
