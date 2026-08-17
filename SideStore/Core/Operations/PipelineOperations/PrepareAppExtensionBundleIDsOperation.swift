//
//  PrepareAppExtensionBundleIDsOperation.swift
//  SideStore
//
//  Created by Magesh K on 01/08/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation

final class PrepareAppExtensionBundleIDsOperation: BasePipelineOperation<AppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        debugLog("[PrepareAppExtensionBundleIDsOperation] execute() started")
        defer { debugLog("[PrepareAppExtensionBundleIDsOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if self.context.useMainProfile {
            if let appBundle = self.context.targetAppBundle, let profile = self.context.provisioningProfiles?[self.context.bundleIdentifier] {
                var appexBundleIds: [String: String] = [:]
                for appex in appBundle.appExtensions {
                    appexBundleIds[appex.bundleIdentifier] = appex.bundleIdentifier
                        .replacingOccurrences(of: appBundle.bundleIdentifier, with: profile.bundleIdentifier)
                }
                self.context.appexBundleIds = appexBundleIds
            }
        }
        self.setProgress(100)
    }
}
