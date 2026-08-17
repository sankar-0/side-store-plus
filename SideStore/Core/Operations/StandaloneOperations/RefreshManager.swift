//
//  RefreshManager.swift
//  SideStore
//
//  Created by SideStore Team on 8/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import BackgroundTasks
import UserNotifications
import CoreData
import UIKit
@preconcurrency import AltSign

/// RefreshManager orchestrates background application renewal via `BGTaskScheduler`.
/// It implements proactive multi-account certificate renewal (< 48 hours), automatically establishes
/// the embedded WireGuard VPN loopback tunnel, hydrates credentials/Anisette per Apple Account,
/// handles task expiration cleanly, and posts notifications upon completion.
@MainActor
public final class RefreshManager: NSObject, @unchecked Sendable {
    public static let shared = RefreshManager()
    
    public enum TaskIdentifiers {
        public static let appRefresh = "com.sidestore.SideStore.refresh"
        public static let processingRefresh = "com.sidestore.SideStore.backgroundrefresh"
    }
    
    private var activeRefreshTask: BGTask?
    private var isRefreshing: Bool = false
    private var currentExecutionTask: Task<Void, Never>?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Registration
    
    /// Registers background refresh tasks with iOS BGTaskScheduler.
    /// Must be called during application launch in `application(_:didFinishLaunchingWithOptions:)`.
    public func registerBackgroundTasks() {
        debugLog("[RefreshManager] Registering BGTaskScheduler identifiers...")
        
        // 1. Register BGAppRefreshTask
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TaskIdentifiers.appRefresh,
            using: nil
        ) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                self.handleAppRefreshTask(appRefreshTask)
            }
        }
        
        // 2. Register BGProcessingTask
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TaskIdentifiers.processingRefresh,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Task { @MainActor in
                self.handleProcessingTask(processingTask)
            }
        }
        
        debugLog("[RefreshManager] BGTaskScheduler tasks successfully registered.")
    }
    
    // MARK: - Scheduling
    
    /// Submits periodic background refresh requests to BGTaskScheduler.
    public func scheduleAppRefresh(earliestBeginIn seconds: TimeInterval = 3600) {
        guard UserDefaults.standard.isBackgroundRefreshEnabled else {
            debugLog("[RefreshManager] Background refresh is disabled in Settings, skipping schedule.")
            return
        }
        
        // 1. Submit App Refresh Task (runs frequently for quick checks)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: TaskIdentifiers.appRefresh)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            debugLog("[RefreshManager] Submitted BGAppRefreshTaskRequest for \(seconds)s from now.")
        } catch {
            debugLog("[RefreshManager] Failed to submit BGAppRefreshTaskRequest: \(error)")
        }
        
        // 2. Submit Processing Task (longer execution window with power & network)
        let processingRequest = BGProcessingTaskRequest(identifier: TaskIdentifiers.processingRefresh)
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: seconds * 2)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(processingRequest)
            debugLog("[RefreshManager] Submitted BGProcessingTaskRequest.")
        } catch {
            debugLog("[RefreshManager] Failed to submit BGProcessingTaskRequest: \(error)")
        }
    }
    
    // MARK: - Task Handlers
    
    private func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        debugLog("[RefreshManager] handleAppRefreshTask() fired")
        self.performBackgroundRenewal(task: task)
    }
    
    private func handleProcessingTask(_ task: BGProcessingTask) {
        debugLog("[RefreshManager] handleProcessingTask() fired")
        self.performBackgroundRenewal(task: task)
    }
    
    private func performBackgroundRenewal(task: BGTask) {
        self.activeRefreshTask = task
        self.isRefreshing = true
        
        // Reschedule immediately for subsequent checks
        self.scheduleAppRefresh()
        
        // Handle iOS background execution cutoff gracefully
        task.expirationHandler = { [weak self] in
            debugLog("[RefreshManager] ⚠️ Background task expirationHandler invoked by iOS. Canceling renewal...")
            Task { @MainActor in
                self?.currentExecutionTask?.cancel()
                self?.currentExecutionTask = nil
                self?.isRefreshing = false
                self?.activeRefreshTask = nil
                task.setTaskCompleted(success: false)
            }
        }
        
        self.currentExecutionTask = Task {
            let success = await self.executeMultiAccountRenewalPipeline()
            self.isRefreshing = false
            self.activeRefreshTask = nil
            self.currentExecutionTask = nil
            task.setTaskCompleted(success: success)
            debugLog("[RefreshManager] Background renewal finished with success: \(success)")
        }
    }
    
    // MARK: - Multi-Account Renewal Pipeline
    
    /// Core execution pipeline: Proactively identifies apps expiring in < 48 hours,
    /// connects internal VPN, hydrates credentials per Apple ID account, and executes batch resigning.
    public func executeMultiAccountRenewalPipeline() async -> Bool {
        debugLog("[RefreshManager] Starting Multi-Account Renewal Pipeline...")
        
        guard UserDefaults.standard.isBackgroundRefreshEnabled else {
            debugLog("[RefreshManager] Background refresh is disabled, aborting.")
            return true
        }
        
        // 1. Ensure Database is started
        if !DatabaseManager.shared.isStarted {
            let startResult: Bool = await withCheckedContinuation { continuation in
                DatabaseManager.shared.start { error in
                    continuation.resume(returning: error == nil)
                }
            }
            guard startResult else {
                debugLog("[RefreshManager] Database failed to start during background refresh.")
                return false
            }
        }
        
        // 2. Proactively identify apps expiring within 48 hours (< 2 days)
        let backgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let expiringApps = await self.fetchAppsNeedingRenewal(in: backgroundContext)
        
        guard !expiringApps.isEmpty else {
            debugLog("[RefreshManager] No apps require renewal at this time (all certificates valid for > 48 hours).")
            return true
        }
        
        debugLog("[RefreshManager] Found \(expiringApps.count) apps requiring proactive certificate renewal.")
        
        // 3. Wake up & establish internal WireGuard loopback VPN connection
        do {
            debugLog("[RefreshManager] Establishing internal VPN connection for background refresh...")
            try await VPNManager.shared.ensureConnected(timeoutSeconds: 15.0)
            debugLog("[RefreshManager] Internal VPN loopback connection ready.")
        } catch {
            debugLog("[RefreshManager] Failed to establish VPN for background refresh: \(error.localizedDescription)")
            self.postRenewalNotification(
                title: NSLocalizedString("Background Refresh Failed", comment: ""),
                body: String(format: NSLocalizedString("Could not connect to internal tunnel: %@", comment: ""), error.localizedDescription),
                isSuccess: false
            )
            return false
        }
        
        // 4. Group expiring apps by assigned AppleAccount
        let accountAppGroups = await self.groupAppsByAccount(expiringApps, in: backgroundContext)
        
        var totalRefreshedCount = 0
        var totalFailedCount = 0
        var refreshedAccountsCount = 0
        var errorSummaries: [String] = []
        
        // 5. Iterate through each AppleAccount sequentially
        for (account, apps) in accountAppGroups {
            if Task.isCancelled { break }
            
            debugLog("[RefreshManager] Hydrating credentials and Anisette for account: \(account.appleID) (\(apps.count) apps)...")
            MultiAccountManager.shared.hydrateCredentials(for: account)
            
            // Allow session headers to propagate
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            do {
                let refreshResults = try await self.refreshAppsBatch(apps)
                var accountSuccessCount = 0
                for (bundleID, result) in refreshResults {
                    switch result {
                    case .success:
                        accountSuccessCount += 1
                        totalRefreshedCount += 1
                    case .failure(let error):
                        totalFailedCount += 1
                        errorSummaries.append("\(bundleID): \(error.localizedDescription)")
                    }
                }
                
                if accountSuccessCount > 0 {
                    refreshedAccountsCount += 1
                }
                debugLog("[RefreshManager] Completed renewal for account \(account.appleID): \(accountSuccessCount)/\(apps.count) succeeded.")
            } catch {
                debugLog("[RefreshManager] Error renewing apps for account \(account.appleID): \(error.localizedDescription)")
                totalFailedCount += apps.count
                errorSummaries.append("\(account.appleID): \(error.localizedDescription)")
            }
        }
        
        // 6. Post Local Notification with Detailed Outcome
        self.postRenewalSummaryNotification(
            refreshedCount: totalRefreshedCount,
            failedCount: totalFailedCount,
            accountsCount: refreshedAccountsCount,
            errors: errorSummaries
        )
        
        return totalFailedCount == 0
    }
    
    // MARK: - Query & Grouping Helpers
    
    /// Identifies active apps whose expiration date is within 48 hours (2 days) or past due.
    private func fetchAppsNeedingRenewal(in context: NSManagedObjectContext) async -> [InstalledApp] {
        return await context.perform {
            let twoDaysFromNow = Date().addingTimeInterval(48 * 60 * 60) // 48 hours
            
            let fetchRequest = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
            fetchRequest.predicate = NSPredicate(
                format: "(%K == YES) AND (%K <= %@)",
                #keyPath(InstalledApp.isActive),
                #keyPath(InstalledApp.expirationDate),
                twoDaysFromNow as NSDate
            )
            
            do {
                let apps = try context.fetch(fetchRequest)
                return apps.sorted { $0.expirationDate < $1.expirationDate }
            } catch {
                debugLog("[RefreshManager] Failed to fetch expiring apps: \(error)")
                return []
            }
        }
    }
    
    /// Groups installed apps by their designated AppleAccount from MultiAccountManager.
    private func groupAppsByAccount(_ apps: [InstalledApp], in context: NSManagedObjectContext) async -> [(AppleAccount, [InstalledApp])] {
        var groups: [String: (account: AppleAccount, apps: [InstalledApp])] = [:]
        
        let primaryAccount = MultiAccountManager.shared.primaryAccount
        
        for app in apps {
            let assignedAccount = MultiAccountManager.shared.account(for: app.bundleIdentifier) ?? primaryAccount
            guard let account = assignedAccount else { continue }
            
            if var existing = groups[account.id] {
                existing.apps.append(app)
                groups[account.id] = existing
            } else {
                groups[account.id] = (account: account, apps: [app])
            }
        }
        
        return Array(groups.values)
    }
    
    /// Executes app refresh batch for a group of applications.
    private func refreshAppsBatch(_ apps: [InstalledApp]) async throws -> [String: Result<InstalledApp, Error>] {
        return try await withCheckedThrowingContinuation { continuation in
            let group = AppManager.shared.refresh(apps, presentingViewController: nil)
            group.completionHandler = { results in
                continuation.resume(returning: results)
            }
        }
    }
    
    // MARK: - Notification Delivery
    
    private func postRenewalSummaryNotification(
        refreshedCount: Int,
        failedCount: Int,
        accountsCount: Int,
        errors: [String]
    ) {
        guard refreshedCount > 0 || failedCount > 0 else { return }
        
        if failedCount == 0 {
            let title = NSLocalizedString("Apps Refreshed", comment: "")
            let body = String(
                format: NSLocalizedString("Successfully renewed %d %@ across %d Apple %@ in the background.", comment: ""),
                refreshedCount,
                refreshedCount == 1 ? "app" : "apps",
                accountsCount,
                accountsCount == 1 ? "account" : "accounts"
            )
            self.postRenewalNotification(title: title, body: body, isSuccess: true)
        } else if refreshedCount > 0 {
            let title = NSLocalizedString("Partial App Refresh", comment: "")
            let body = String(
                format: NSLocalizedString("Renewed %d %@, but %d failed. Open SideStore to inspect details.", comment: ""),
                refreshedCount,
                refreshedCount == 1 ? "app" : "apps",
                failedCount
            )
            self.postRenewalNotification(title: title, body: body, isSuccess: false)
        } else {
            let title = NSLocalizedString("Background Refresh Failed", comment: "")
            let body = String(
                format: NSLocalizedString("Failed to renew %d %@ in the background. Open SideStore to manually refresh.", comment: ""),
                failedCount,
                failedCount == 1 ? "app" : "apps"
            )
            self.postRenewalNotification(title: title, body: body, isSuccess: false)
        }
    }
    
    private func postRenewalNotification(title: String, body: String, isSuccess: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isSuccess ? .default : .defaultCritical
        
        let request = UNNotificationRequest(
            identifier: "sidestore-bg-refresh-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("[RefreshManager] Failed to schedule notification: \(error)")
            }
        }
    }
}
