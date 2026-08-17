//
//  VPNManager.swift
//  SideStore
//
//  Created by SideStore Team on 8/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import NetworkExtension
import Combine
import UIKit

// MARK: - VPN Errors

public enum VPNError: LocalizedError, Sendable {
    case managerUnavailable
    case tunnelDisabled
    case connectionFailed(String)
    case connectionTimeout
    case pairingFileMissing
    
    public var errorDescription: String? {
        switch self {
        case .managerUnavailable:
            return NSLocalizedString("NetworkExtension tunnel provider manager could not be loaded.", comment: "")
        case .tunnelDisabled:
            return NSLocalizedString("The SideStore VPN configuration is currently disabled in iOS Settings.", comment: "")
        case .connectionFailed(let reason):
            return String(format: NSLocalizedString("Failed to establish internal VPN tunnel: %@", comment: ""), reason)
        case .connectionTimeout:
            return NSLocalizedString("Timed out waiting for internal VPN loopback tunnel to connect.", comment: "")
        case .pairingFileMissing:
            return NSLocalizedString("Pairing file is missing. Please import a valid pairing file before starting the VPN.", comment: "")
        }
    }
}

// MARK: - VPNManager

@MainActor
public final class VPNManager: ObservableObject, @unchecked Sendable {
    public static let shared = VPNManager()
    
    public static let vpnStatusDidChangeNotification = Notification.Name("SideStoreVPNStatusDidChangeNotification")
    
    private let tunnelBundleIdentifierSuffix = ".SideStoreTunnel"
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?
    private var configObserver: AnyCancellable?
    
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isConnecting: Bool = false
    @Published public private(set) var status: NEVPNStatus = .disconnected
    @Published public private(set) var lastError: Error? = nil
    
    @Published public var isAutoVPNEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoVPNEnabled, forKey: "isAutoVPNEnabled")
        }
    }
    
    @Published public var isAutoDisconnectOnBackgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoDisconnectOnBackgroundEnabled, forKey: "isAutoDisconnectVPNOnBackgroundEnabled")
        }
    }
    
    public var tunnelBundleIdentifier: String {
        let base = Bundle.main.bundleIdentifier ?? "com.SideStore.SideStore"
        return base + tunnelBundleIdentifierSuffix
    }
    
    private init() {
        self.isAutoVPNEnabled = UserDefaults.standard.object(forKey: "isAutoVPNEnabled") as? Bool ?? true
        self.isAutoDisconnectOnBackgroundEnabled = UserDefaults.standard.object(forKey: "isAutoDisconnectVPNOnBackgroundEnabled") as? Bool ?? false
        
        self.setupObservers()
        Task {
            try? await self.loadOrCreateTunnelManager()
        }
    }
    
    // MARK: - Observers
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.vpnConfigurationDidChange(_:)),
            name: .NEVPNConfigurationChange,
            object: nil
        )
    }
    
    @objc private func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else {
            self.refreshStatus()
            return
        }
        
        self.updateStatus(connection.status)
    }
    
    @objc private func vpnConfigurationDidChange(_ notification: Notification) {
        Task {
            try? await self.loadOrCreateTunnelManager()
        }
    }
    
    private func updateStatus(_ newStatus: NEVPNStatus) {
        self.status = newStatus
        self.isConnected = (newStatus == .connected)
        self.isConnecting = (newStatus == .connecting || newStatus == .reasserting)
        
        debugLog("[VPNManager] Status updated to: \(newStatus.description) (connected: \(self.isConnected), connecting: \(self.isConnecting))")
        
        NotificationCenter.default.post(
            name: Self.vpnStatusDidChangeNotification,
            object: self,
            userInfo: ["status": newStatus.rawValue]
        )
    }
    
    public func refreshStatus() {
        if let manager = self.tunnelManager {
            self.updateStatus(manager.connection.status)
        } else {
            self.updateStatus(.disconnected)
        }
    }
    
    // MARK: - Manager Lifecycle & Shared Container Sync
    
    @discardableResult
    public func loadOrCreateTunnelManager() async throws -> NETunnelProviderManager {
        if let existing = self.tunnelManager {
            try await existing.loadFromPreferences()
            self.updateStatus(existing.connection.status)
            return existing
        }
        
        debugLog("[VPNManager] Loading tunnel provider managers from system preferences...")
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        
        let targetBundleID = self.tunnelBundleIdentifier
        if let found = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == targetBundleID
        }) {
            debugLog("[VPNManager] Found existing tunnel manager for: \(targetBundleID)")
            self.tunnelManager = found
            self.updateStatus(found.connection.status)
            return found
        }
        
        // Create new NETunnelProviderManager
        debugLog("[VPNManager] Creating new NETunnelProviderManager for: \(targetBundleID)...")
        let newManager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = targetBundleID
        proto.serverAddress = "127.0.0.1:51820"
        proto.providerConfiguration = [
            "interfaceAddress": "10.7.0.10",
            "endpointAddress": "127.0.0.1",
            "endpointPort": 51820
        ]
        
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "SideStore Loopback Tunnel"
        newManager.isEnabled = true
        
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        
        self.tunnelManager = newManager
        self.updateStatus(newManager.connection.status)
        debugLog("[VPNManager] Successfully created and saved tunnel manager.")
        return newManager
    }
    
    /// Syncs local pairing file and WireGuard config into the shared App Group directory
    /// so SideStoreTunnel can access it in its isolated container.
    public func syncConfigurationToSharedContainer() throws {
        guard let sharedDirectory = FileManager.default.altstoreSharedDirectory else {
            debugLog("[VPNManager] Warning: altstoreSharedDirectory is nil, skipping file sync.")
            return
        }
        
        let pairingFileName = "ALTPairingFile.mobiledevicepairing"
        let wireGuardConfName = "SideStore.conf"
        
        // 1. Sync Pairing File
        if let pairingContents = PairingFileManager.shared.fetchPairingFile() {
            let targetURL = sharedDirectory.appendingPathComponent(pairingFileName)
            try pairingContents.write(to: targetURL, atomically: true, encoding: .utf8)
            debugLog("[VPNManager] Synced pairing file to App Group: \(targetURL.path)")
        }
        
        // 2. Sync SideStore.conf
        let bundleConfURL = Bundle.main.url(forResource: "SideStore", withExtension: "conf")
        let targetConfURL = sharedDirectory.appendingPathComponent(wireGuardConfName)
        if let bundleConfURL = bundleConfURL, FileManager.default.fileExists(atPath: bundleConfURL.path) {
            try? FileManager.default.removeItem(at: targetConfURL)
            try? FileManager.default.copyItem(at: bundleConfURL, to: targetConfURL)
            debugLog("[VPNManager] Synced SideStore.conf to App Group.")
        }
    }
    
    // MARK: - Tunnel Control Operations
    
    public func startTunnel() {
        Task {
            do {
                try await self.startTunnelAsync()
            } catch {
                debugLog("[VPNManager] startTunnel() failed: \(error)")
                self.lastError = error
            }
        }
    }
    
    public func startTunnelAsync() async throws {
        debugLog("[VPNManager] startTunnelAsync() invoked")
        try self.syncConfigurationToSharedContainer()
        
        let manager = try await self.loadOrCreateTunnelManager()
        
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw VPNError.managerUnavailable
        }
        
        if session.status == .connected {
            debugLog("[VPNManager] Tunnel is already connected.")
            self.updateStatus(.connected)
            return
        }
        
        do {
            try session.startTunnel(options: nil)
            debugLog("[VPNManager] session.startTunnel() called successfully.")
        } catch {
            debugLog("[VPNManager] Failed to start tunnel: \(error.localizedDescription)")
            self.lastError = error
            throw VPNError.connectionFailed(error.localizedDescription)
        }
    }
    
    public func stopTunnel() {
        Task {
            await self.stopTunnelAsync()
        }
    }
    
    public func stopTunnelAsync() async {
        debugLog("[VPNManager] stopTunnelAsync() invoked")
        guard let manager = self.tunnelManager,
              let session = manager.connection as? NETunnelProviderSession else {
            return
        }
        
        session.stopTunnel()
        self.updateStatus(.disconnected)
        debugLog("[VPNManager] session.stopTunnel() called.")
    }
    
    public func toggleTunnel() {
        if self.isConnected || self.isConnecting {
            self.stopTunnel()
        } else {
            self.startTunnel()
        }
    }
    
    // MARK: - Readiness Guard & Interceptor
    
    /// Ensures that the internal WireGuard tunnel is actively connected before proceeding with sideloading or device operations.
    /// If not connected, it automatically establishes the tunnel and waits up to `timeoutSeconds`.
    public func ensureConnected(timeoutSeconds: Double = 10.0) async throws {
        self.refreshStatus()
        if self.isConnected {
            return
        }
        
        debugLog("[VPNManager] ensureConnected(): Tunnel is \(self.status.description), initiating connection...")
        try await self.startTunnelAsync()
        
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            self.refreshStatus()
            if self.isConnected {
                debugLog("[VPNManager] ensureConnected(): Connected successfully after \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s.")
                return
            }
            if self.status == .invalid {
                throw VPNError.connectionFailed("VPN configuration became invalid.")
            }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms polling step
        }
        
        if !self.isConnected {
            debugLog("[VPNManager] ensureConnected() TIMED OUT after \(timeoutSeconds)s. Status: \(self.status.description)")
            throw VPNError.connectionTimeout
        }
    }
    
    // MARK: - Lifecycle Automation
    
    /// Auto-connects the tunnel when SideStore is brought to the foreground if enabled in Settings.
    public func autoConnectIfEnabled() {
        guard self.isAutoVPNEnabled else {
            debugLog("[VPNManager] autoConnect skipped: isAutoVPNEnabled is false.")
            return
        }
        
        guard !self.isConnected && !self.isConnecting else {
            debugLog("[VPNManager] autoConnect skipped: Tunnel is already connected or connecting.")
            return
        }
        
        debugLog("[VPNManager] Lifecycle trigger: Auto-connecting internal VPN on app activation...")
        Task {
            do {
                try await self.startTunnelAsync()
            } catch {
                debugLog("[VPNManager] Auto-connect failed: \(error)")
            }
        }
    }
    
    /// Disconnects the tunnel when SideStore enters the background if enabled in Settings.
    public func autoDisconnectIfEnabled() {
        guard self.isAutoDisconnectOnBackgroundEnabled else {
            return
        }
        
        guard self.isConnected || self.isConnecting else {
            return
        }
        
        debugLog("[VPNManager] Lifecycle trigger: Auto-disconnecting internal VPN on entering background...")
        self.stopTunnel()
    }
}

// MARK: - NEVPNStatus Helper

public extension NEVPNStatus {
    var description: String {
        switch self {
        case .invalid: return "Invalid"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reasserting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }
}
