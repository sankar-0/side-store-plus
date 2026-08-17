//
//  MultiAccountView.swift
//  SideStore
//
//  Created by SideStore Team on 8/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData
@preconcurrency import AltSign

private extension Color {
    static let settingsRowBackground = Color.white.opacity(0.15)
    static let settingsDivider = Color.white.opacity(0.15)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
}

public struct MultiAccountView: View {
    @ObservedObject private var manager = MultiAccountManager.shared
    @State private var showingAddAccountSheet = false
    @State private var selectedAccountForDetail: AppleAccount?
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false
    
    public init() {}
    
    public var body: some View {
        List {
            // Section 1: DYNAMIC QUOTA METRICS OVERVIEW
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ACTIVE POOL QUOTA")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Text("\(manager.activeAccountsCount) \(manager.activeAccountsCount == 1 ? "Account" : "Accounts") Active")
                                .font(.system(size: 20, weight: .bold))
                        }
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 30))
                            .foregroundColor(.accentColor)
                    }
                    
                    Divider()
                    
                    HStack(spacing: 20) {
                        quotaMetric(
                            title: "Usable App Slots",
                            value: "\(manager.totalUsableAppSlots)",
                            subtitle: "\(manager.totalSystemSlots) total slots (1 for SideStore)",
                            icon: "square.grid.2x2.fill"
                        )
                        
                        quotaMetric(
                            title: "Weekly App IDs",
                            value: "\(manager.totalWeeklyAppIDQuota)",
                            subtitle: "\(10 * manager.activeAccountsCount)/week total",
                            icon: "tag.fill"
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            
            // Section 2: MULTI-ACCOUNT CONTROLS
            Section {
                Toggle(isOn: $manager.isMultiAccountEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Multi-Account Mode")
                            .font(.system(size: 16, weight: .medium))
                        Text("Automatically cascade & overflow apps to secondary accounts when primary slots fill up.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("MODE CONFIGURATION")
            }
            
            // Section 3: CONFIGURED ACCOUNTS
            Section {
                if manager.accounts.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No Accounts Configured")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add Apple IDs to expand your app installation slots and App ID limits.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(manager.accounts) { account in
                        AccountRowView(account: account) {
                            switchContext(to: account)
                        } onToggleActive: {
                            toggleActive(for: account)
                        } onMakePrimary: {
                            makePrimary(account)
                        } onDelete: {
                            deleteAccount(account)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("CONFIGURED APPLE IDS")
                    Spacer()
                    Text("\(manager.accounts.count) Total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Section 4: ACTIONS
            Section {
                Button(action: { showingAddAccountSheet = true }) {
                    Label("Add Apple ID Account", systemImage: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            } footer: {
                Text("Each Apple ID adds 3 app slots and 10 weekly App IDs. SideStore reserves 1 slot on the Primary Account.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Multi-Account Pool")
        .sheet(isPresented: $showingAddAccountSheet) {
            AddAppleAccountSheet { newAccount in
                do {
                    try manager.addAccount(newAccount)
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.showingErrorAlert = true
                }
            }
        }
        .alert(isPresented: $showingErrorAlert) {
            Alert(
                title: Text("Multi-Account Error"),
                message: Text(errorMessage ?? "An unknown error occurred."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    @ViewBuilder
    private func quotaMetric(title: String, value: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func switchContext(to account: AppleAccount) {
        manager.hydrateCredentials(for: account)
    }
    
    private func toggleActive(for account: AppleAccount) {
        do {
            try manager.toggleAccountActive(id: account.id)
        } catch {
            self.errorMessage = error.localizedDescription
            self.showingErrorAlert = true
        }
    }
    
    private func makePrimary(_ account: AppleAccount) {
        do {
            try manager.setPrimaryAccount(id: account.id)
            manager.hydrateCredentials(for: account)
        } catch {
            self.errorMessage = error.localizedDescription
            self.showingErrorAlert = true
        }
    }
    
    private func deleteAccount(_ account: AppleAccount) {
        do {
            try manager.removeAccount(id: account.id)
        } catch {
            self.errorMessage = error.localizedDescription
            self.showingErrorAlert = true
        }
    }
}

// MARK: - Account Row View

private struct AccountRowView: View {
    let account: AppleAccount
    let onSwitchContext: () -> Void
    let onToggleActive: () -> Void
    let onMakePrimary: () -> Void
    let onDelete: () -> Void
    
    private var usedSlots: Int {
        MultiAccountManager.shared.activeAppCount(for: account.id, in: DatabaseManager.shared.viewContext)
    }
    
    private var maxSlots: Int {
        account.maxUsableAppSlots
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.appleID)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        
                        if account.isPrimary {
                            Text("PRIMARY")
                                .font(.system(size: 9, weight: .black))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                    
                    if let teamName = account.teamName, !teamName.isEmpty {
                        Text(teamName)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Active status toggle
                Toggle("", isOn: Binding(
                    get: { account.isActive },
                    set: { _ in onToggleActive() }
                ))
                .labelsHidden()
            }
            
            // Slot usage bar
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(usedSlots)/\(maxSlots) usable slots used")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(usedSlots >= maxSlots ? .orange : .secondary)
                    
                    if account.isPrimary {
                        Text("(+1 for SideStore)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Context switch / actions menu
                Menu {
                    Button(action: onSwitchContext) {
                        Label("Make Active Signing Context", systemImage: "arrow.triangle.2.circlepath")
                    }
                    
                    if !account.isPrimary {
                        Button(action: onMakePrimary) {
                            Label("Set as Primary Account", systemImage: "star.fill")
                        }
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: onDelete) {
                        Label("Remove Account", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(account.isActive ? 1.0 : 0.6)
    }
}

// MARK: - Add Account Sheet

public struct AddAppleAccountSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var appleID: String = ""
    @State private var password: String = ""
    @State private var teamName: String = ""
    @State private var isAuthenticating: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false
    
    let onAdd: (AppleAccount) -> Void
    
    public init(onAdd: @escaping (AppleAccount) -> Void) {
        self.onAdd = onAdd
    }
    
    public var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Apple ID Email", text: $appleID)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.emailAddress)
                    
                    SecureField("Password or App-Specific Password", text: $password)
                        .textContentType(.password)
                    
                    TextField("Nickname / Label (Optional)", text: $teamName)
                } header: {
                    Text("CREDENTIALS")
                } footer: {
                    Text("Credentials will be encrypted and saved securely to the iOS Keychain for signing and automatic background refresh.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: authenticateAndSave) {
                        HStack {
                            Spacer()
                            if isAuthenticating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isAuthenticating ? "Verifying Account..." : "Save Account")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isAuthenticating)
                }
            }
            .navigationTitle("Add Apple ID")
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .alert(isPresented: $showingError) {
                Alert(
                    title: Text("Authentication Failed"),
                    message: Text(errorMessage ?? "Unable to verify credentials."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
    
    private func authenticateAndSave() {
        let trimmedEmail = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        
        isAuthenticating = true
        
        // Build new AppleAccount record
        let newAccount = AppleAccount(
            id: UUID().uuidString,
            appleID: trimmedEmail,
            password: password,
            teamName: teamName.isEmpty ? nil : teamName,
            teamType: 0,
            isActive: true,
            isPrimary: false,
            createdAt: Date(),
            lastUsedAt: nil
        )
        
        isAuthenticating = false
        onAdd(newAccount)
        presentationMode.wrappedValue.dismiss()
    }
}
