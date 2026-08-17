//
//  MultiAccountManager.swift
//  SideStore
//
//  Created by SideStore Team on 8/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CoreData
import Combine
@preconcurrency import AltSign
private import KeychainAccess

// MARK: - AppleAccount Model

public struct AppleAccount: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: String
    public var appleID: String
    public var password: String?
    public var adsid: String?
    public var xcodeToken: String?
    public var teamID: String?
    public var teamName: String?
    public var teamType: Int16? // 0: free, 1: individual, 2: organization
    public var certificateData: Data?
    public var certificatePassword: String?
    public var certificateSerialNumber: String?
    public var anisetteIdentifier: String?
    public var anisetteAdiBlob: String?
    public var isActive: Bool
    public var isPrimary: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?
    
    public init(
        id: String = UUID().uuidString,
        appleID: String,
        password: String? = nil,
        adsid: String? = nil,
        xcodeToken: String? = nil,
        teamID: String? = nil,
        teamName: String? = nil,
        teamType: Int16? = 0,
        certificateData: Data? = nil,
        certificatePassword: String? = nil,
        certificateSerialNumber: String? = nil,
        anisetteIdentifier: String? = nil,
        anisetteAdiBlob: String? = nil,
        isActive: Bool = true,
        isPrimary: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.appleID = appleID
        self.password = password
        self.adsid = adsid
        self.xcodeToken = xcodeToken
        self.teamID = teamID
        self.teamName = teamName
        self.teamType = teamType
        self.certificateData = certificateData
        self.certificatePassword = certificatePassword
        self.certificateSerialNumber = certificateSerialNumber
        self.anisetteIdentifier = anisetteIdentifier
        self.anisetteAdiBlob = anisetteAdiBlob
        self.isActive = isActive
        self.isPrimary = isPrimary
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
    
    public var displayName: String {
        if let teamName = teamName, !teamName.isEmpty {
            return "\(teamName) (\(appleID))"
        }
        return appleID
    }
    
    public var isFreeAccount: Bool {
        guard let teamType = teamType else { return true }
        return teamType == 0
    }
    
    /// Total active app limit for this single account (3 for free, 10 if MacDirtyCow/unlimited)
    public var totalSlotCapacity: Int {
        if UserDefaults.standard.isAppLimitDisabled {
            return 10
        }
        return 3
    }
    
    /// SideStore itself occupies 1 slot on the Primary Account.
    public var reservedSlots: Int {
        return isPrimary ? 1 : 0
    }
    
    /// Maximum number of third-party user apps this account can sign simultaneously.
    /// Account 1 (Primary) has 2 usable slots; Secondary accounts have 3 usable slots.
    public var maxUsableAppSlots: Int {
        return max(totalSlotCapacity - reservedSlots, 0)
    }
    
    /// Max weekly App ID quota for this account
    public var weeklyAppIDQuota: Int {
        return isFreeAccount ? Team.maximumFreeAppIDs : 100
    }
}

// MARK: - MultiAccountError

public enum MultiAccountError: LocalizedError, Sendable {
    case allAccountsExhausted
    case accountNotFound(String)
    case accountDisabled(String)
    case noAvailableAppIDs(String)
    case cannotRemovePrimaryAccount
    case duplicateAccount(String)
    
    public var errorDescription: String? {
        switch self {
        case .allAccountsExhausted:
            return NSLocalizedString("All configured Apple ID accounts have reached their maximum active app limit. Please add another Apple ID in Settings or deactivate an app.", comment: "")
        case .accountNotFound(let id):
            return String(format: NSLocalizedString("Target Apple ID account (%@) could not be found.", comment: ""), id)
        case .accountDisabled(let id):
            return String(format: NSLocalizedString("Apple ID account (%@) is disabled.", comment: ""), id)
        case .noAvailableAppIDs(let id):
            return String(format: NSLocalizedString("No available App IDs remain on account (%@).", comment: ""), id)
        case .cannotRemovePrimaryAccount:
            return NSLocalizedString("Cannot remove the primary Apple ID account while other accounts depend on it. Please designate another primary account first or sign out completely.", comment: "")
        case .duplicateAccount(let email):
            return String(format: NSLocalizedString("An account with Apple ID %@ is already added.", comment: ""), email)
        }
    }
}

// MARK: - MultiAccountManager

@MainActor
public final class MultiAccountManager: ObservableObject, @unchecked Sendable {
    public static let shared = MultiAccountManager()
    
    public static let accountsDidChangeNotification = Notification.Name("MultiAccountManagerAccountsDidChangeNotification")
    public static let activeAccountSwitchedNotification = Notification.Name("MultiAccountManagerActiveAccountSwitchedNotification")
    
    private let keychain = KeychainAccess.Keychain(service: Bundle.Info.appbundleIdentifier)
        .accessibility(.afterFirstUnlock)
        .synchronizable(true)
    
    private let accountsKeychainKey = "multi_account_pool_v1"
    private let mappingsKeychainKey = "multi_account_mappings_v1"
    
    @Published public private(set) var accounts: [AppleAccount] = []
    @Published public private(set) var appAccountMappings: [String: String] = [:] // bundleIdentifier -> accountID
    
    @Published public var isMultiAccountEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMultiAccountEnabled, forKey: "isMultiAccountEnabled")
            self.updateDynamicLimits()
            NotificationCenter.default.post(name: Self.accountsDidChangeNotification, object: self)
        }
    }
    
    private init() {
        self.isMultiAccountEnabled = UserDefaults.standard.object(forKey: "isMultiAccountEnabled") as? Bool ?? true
        self.loadAccountsFromStorage()
        self.loadMappingsFromStorage()
        self.ensurePrimaryAccountMigrationIfNeeded()
        self.updateDynamicLimits()
    }
    
    // MARK: - Persistence
    
    private func loadAccountsFromStorage() {
        guard let data = try? self.keychain.getData(self.accountsKeychainKey) else {
            self.accounts = []
            return
        }
        
        do {
            let decoder = JSONDecoder()
            self.accounts = try decoder.decode([AppleAccount].self, from: data)
            debugLog("[MultiAccountManager] Loaded \(self.accounts.count) accounts from Keychain.")
        } catch {
            debugLog("[MultiAccountManager] Failed to decode accounts from Keychain: \(error)")
            self.accounts = []
        }
    }
    
    private func saveAccountsToStorage() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.accounts)
            try self.keychain.set(data, key: self.accountsKeychainKey)
            self.updateDynamicLimits()
            NotificationCenter.default.post(name: Self.accountsDidChangeNotification, object: self)
            debugLog("[MultiAccountManager] Saved \(self.accounts.count) accounts to Keychain.")
        } catch {
            debugLog("[MultiAccountManager] Failed to save accounts to Keychain: \(error)")
        }
    }
    
    private func loadMappingsFromStorage() {
        guard let data = try? self.keychain.getData(self.mappingsKeychainKey) else {
            self.appAccountMappings = [:]
            return
        }
        
        do {
            let decoder = JSONDecoder()
            self.appAccountMappings = try decoder.decode([String: String].self, from: data)
        } catch {
            debugLog("[MultiAccountManager] Failed to decode app mappings: \(error)")
            self.appAccountMappings = [:]
        }
    }
    
    private func saveMappingsToStorage() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.appAccountMappings)
            try self.keychain.set(data, key: self.mappingsKeychainKey)
        } catch {
            debugLog("[MultiAccountManager] Failed to save app mappings: \(error)")
        }
    }
    
    // MARK: - Legacy / Primary Migration
    
    /// Migrates existing legacy single-account Keychain data into the primary AppleAccount record if the pool is empty.
    public func ensurePrimaryAccountMigrationIfNeeded() {
        guard self.accounts.isEmpty else { return }
        
        guard let email = Keychain.shared.appleIDEmailAddress, !email.isEmpty else {
            return
        }
        
        debugLog("[MultiAccountManager] Migrating existing primary account (\(email)) into MultiAccount pool...")
        let primary = AppleAccount(
            id: Keychain.shared.identifier ?? UUID().uuidString,
            appleID: email,
            password: Keychain.shared.appleIDPassword,
            adsid: Keychain.shared.appleIDAdsid,
            xcodeToken: Keychain.shared.appleIDXcodeToken,
            teamID: DatabaseManager.shared.activeTeam()?.identifier,
            teamName: DatabaseManager.shared.activeTeam()?.name,
            teamType: DatabaseManager.shared.activeTeam()?.typeValue ?? 0,
            certificateData: Keychain.shared.signingCertificate,
            certificatePassword: Keychain.shared.signingCertificatePassword,
            certificateSerialNumber: Keychain.shared.signingCertificateSerialNumber,
            anisetteIdentifier: AnisetteDataManager.shared.anisetteIdentifier,
            anisetteAdiBlob: AnisetteDataManager.shared.anisetteAdiBlob,
            isActive: true,
            isPrimary: true,
            createdAt: Date(),
            lastUsedAt: Date()
        )
        
        self.accounts.append(primary)
        self.saveAccountsToStorage()
    }
    
    // MARK: - Dynamic Quota & Formula Metrics
    
    public var activeAccounts: [AppleAccount] {
        return self.accounts.filter { $0.isActive }
    }
    
    public var activeAccountsCount: Int {
        return max(self.activeAccounts.count, 1)
    }
    
    public var primaryAccount: AppleAccount? {
        return self.accounts.first(where: { $0.isPrimary }) ?? self.accounts.first
    }
    
    /// Total system slots across all active accounts (3 * N)
    public var totalSystemSlots: Int {
        if UserDefaults.standard.isAppLimitDisabled {
            return 10 * self.activeAccountsCount
        }
        return 3 * self.activeAccountsCount
    }
    
    /// Total usable slots for third-party user applications:
    /// Account 1 (Primary) has 2 usable slots (since SideStore occupies 1 slot).
    /// Secondary accounts each have 3 usable slots.
    /// Formula: 2 + 3 * (N - 1) = 3N - 1
    public var totalUsableAppSlots: Int {
        if UserDefaults.standard.isAppLimitDisabled {
            return max(10 * self.activeAccountsCount - 1, 9)
        }
        let count = self.activeAccountsCount
        guard count > 0 else { return 2 }
        return 2 + (3 * (count - 1))
    }
    
    /// Total weekly App ID quota across all active accounts (10 * N)
    public var totalWeeklyAppIDQuota: Int {
        return 10 * self.activeAccountsCount
    }
    
    public func updateDynamicLimits() {
        if self.isMultiAccountEnabled {
            UserDefaults.standard.activeAppsLimit = self.totalSystemSlots
        } else {
            UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
        }
    }
    
    // MARK: - Account CRUD
    
    public func addAccount(_ account: AppleAccount) throws {
        if self.accounts.contains(where: { $0.appleID.lowercased() == account.appleID.lowercased() }) {
            throw MultiAccountError.duplicateAccount(account.appleID)
        }
        
        var newAccount = account
        if self.accounts.isEmpty {
            newAccount.isPrimary = true
        }
        
        self.accounts.append(newAccount)
        self.saveAccountsToStorage()
    }
    
    public func updateAccount(_ account: AppleAccount) {
        if let index = self.accounts.firstIndex(where: { $0.id == account.id }) {
            self.accounts[index] = account
            self.saveAccountsToStorage()
        }
    }
    
    public func removeAccount(id: String) throws {
        guard let account = self.accounts.first(where: { $0.id == id }) else {
            throw MultiAccountError.accountNotFound(id)
        }
        
        if account.isPrimary && self.accounts.count > 1 {
            throw MultiAccountError.cannotRemovePrimaryAccount
        }
        
        self.accounts.removeAll(where: { $0.id == id })
        
        // Remove associated mappings
        self.appAccountMappings = self.appAccountMappings.filter { $0.value != id }
        self.saveMappingsToStorage()
        
        if let first = self.accounts.first, !self.accounts.contains(where: { $0.isPrimary }) {
            var updated = first
            updated.isPrimary = true
            self.accounts[0] = updated
        }
        
        self.saveAccountsToStorage()
    }
    
    public func setPrimaryAccount(id: String) throws {
        guard self.accounts.contains(where: { $0.id == id }) else {
            throw MultiAccountError.accountNotFound(id)
        }
        
        for i in 0..<self.accounts.count {
            self.accounts[i].isPrimary = (self.accounts[i].id == id)
        }
        
        self.saveAccountsToStorage()
    }
    
    public func toggleAccountActive(id: String) throws {
        guard let index = self.accounts.firstIndex(where: { $0.id == id }) else {
            throw MultiAccountError.accountNotFound(id)
        }
        
        self.accounts[index].isActive.toggle()
        self.saveAccountsToStorage()
    }
    
    public func account(id: String) -> AppleAccount? {
        return self.accounts.first(where: { $0.id == id })
    }
    
    public func account(for bundleID: String) -> AppleAccount? {
        if let accountID = self.appAccountMappings[bundleID], let account = self.account(id: accountID) {
            return account
        }
        return nil
    }
    
    public func setAccountID(_ accountID: String, for bundleID: String) {
        self.appAccountMappings[bundleID] = accountID
        self.saveMappingsToStorage()
    }
    
    public func removeAccountMapping(for bundleID: String) {
        self.appAccountMappings.removeValue(forKey: bundleID)
        self.saveMappingsToStorage()
    }
    
    // MARK: - Smart Overflow & Slot Allocator
    
    /// Counts the active third-party apps signed by a specific account in CoreData.
    public func activeAppCount(for accountID: String, in context: NSManagedObjectContext) -> Int {
        let activeApps = InstalledApp.fetchActiveApps(in: context)
            .filter { $0.bundleIdentifier != StoreApp.altstoreAppID }
        
        var count = 0
        for app in activeApps {
            if let assignedAccountID = self.appAccountMappings[app.bundleIdentifier], assignedAccountID == accountID {
                count += app.requiredActiveSlots
            } else if let team = app.team, team.account.identifier == accountID || team.account.appleID == self.account(id: accountID)?.appleID {
                count += app.requiredActiveSlots
            }
        }
        return count
    }
    
    /// Returns the number of remaining usable slots for a specific account.
    public func availableSlots(for account: AppleAccount, in context: NSManagedObjectContext) -> Int {
        guard account.isActive else { return 0 }
        let used = self.activeAppCount(for: account.id, in: context)
        let maxSlots = account.maxUsableAppSlots
        return max(maxSlots - used, 0)
    }
    
    /// Finds the first active Apple Account with available slots sequentially (Cascading / Overflow).
    public func firstAccountWithAvailableSlot(in context: NSManagedObjectContext) -> AppleAccount? {
        let sortedAccounts = self.activeAccounts.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.createdAt < $1.createdAt
        }
        
        for account in sortedAccounts {
            let available = self.availableSlots(for: account, in: context)
            if available > 0 {
                return account
            }
        }
        return nil
    }
    
    /// Selects or allocates the target AppleAccount for a given bundle ID:
    /// 1. If already bound, reuses the existing account.
    /// 2. If Account A is full (3/3 or 2/2 usable), cascades to Account B, Account C, etc.
    /// 3. If all accounts are exhausted, throws `MultiAccountError.allAccountsExhausted`.
    public func selectTargetAccount(for bundleID: String, in context: NSManagedObjectContext) throws -> AppleAccount {
        // 1. If SideStore itself, always use Primary Account
        if bundleID == StoreApp.altstoreAppID {
            guard let primary = self.primaryAccount else {
                throw MultiAccountError.accountNotFound("Primary")
            }
            return primary
        }
        
        // 2. Check existing mapping
        if let existing = self.account(for: bundleID), existing.isActive {
            return existing
        }
        
        // 3. Smart Slot Allocator / Overflow
        guard let available = self.firstAccountWithAvailableSlot(in: context) else {
            throw MultiAccountError.allAccountsExhausted
        }
        
        self.setAccountID(available.id, for: bundleID)
        return available
    }
    
    // MARK: - Credentials & Anisette Hydration
    
    /// Hydrates Keychain and Anisette global singletons with the specified AppleAccount credentials
    /// so the signing pipeline operates in that account's context.
    public func hydrateCredentials(for account: AppleAccount) {
        debugLog("[MultiAccountManager] Hydrating credentials for account: \(account.appleID) (ID: \(account.id))...")
        
        Keychain.shared.appleIDEmailAddress = account.appleID
        Keychain.shared.appleIDPassword = account.password
        Keychain.shared.appleIDAdsid = account.adsid
        Keychain.shared.appleIDXcodeToken = account.xcodeToken
        
        if let certData = account.certificateData {
            Keychain.shared.signingCertificate = certData
            Keychain.shared.signingCertificatePassword = account.certificatePassword ?? ""
        }
        if let serial = account.certificateSerialNumber {
            Keychain.shared.signingCertificateSerialNumber = serial
        }
        
        if let anisetteID = account.anisetteIdentifier {
            Keychain.shared.identifier = anisetteID
            AnisetteDataManager.shared.anisetteIdentifier = anisetteID
        }
        if let adiBlob = account.anisetteAdiBlob {
            Keychain.shared.adiPb = adiBlob
            AnisetteDataManager.shared.anisetteAdiBlob = adiBlob
        }
        
        var updated = account
        updated.lastUsedAt = Date()
        self.updateAccount(updated)
        
        NotificationCenter.default.post(
            name: Self.activeAccountSwitchedNotification,
            object: self,
            userInfo: ["accountID": account.id]
        )
    }
    
    /// Captures the current Keychain and Anisette state back into the stored AppleAccount record.
    public func persistActiveAccountState(for accountID: String) {
        guard var account = self.account(id: accountID) else { return }
        
        if let email = Keychain.shared.appleIDEmailAddress { account.appleID = email }
        if let password = Keychain.shared.appleIDPassword { account.password = password }
        if let adsid = Keychain.shared.appleIDAdsid { account.adsid = adsid }
        if let token = Keychain.shared.appleIDXcodeToken { account.xcodeToken = token }
        if let cert = Keychain.shared.signingCertificate { account.certificateData = cert }
        if let pass = Keychain.shared.signingCertificatePassword { account.certificatePassword = pass }
        if let serial = Keychain.shared.signingCertificateSerialNumber { account.certificateSerialNumber = serial }
        if let anisetteID = AnisetteDataManager.shared.anisetteIdentifier { account.anisetteIdentifier = anisetteID }
        if let adiBlob = AnisetteDataManager.shared.anisetteAdiBlob { account.anisetteAdiBlob = adiBlob }
        
        self.updateAccount(account)
    }
}
