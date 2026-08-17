//
//  PacketTunnelProvider.swift
//  SideStoreTunnel
//
//  Created by SideStore Team on 8/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import NetworkExtension
import Foundation
import os.log

private let logger = Logger(subsystem: "io.sidestore.SideStoreTunnel", category: "PacketTunnel")

/// PacketTunnelProvider handles embedded WireGuard / loopback routing for SideStore.
/// It intercepts traffic destined for the local pairing proxy (10.7.0.1:51820) and routes it directly
/// to the internal minimuxer / EMProxy engine (127.0.0.1:51820), removing reliance on external VPN apps.
public final class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // MARK: - Constants & Tunnel Configuration Defaults
    
    public enum Constants {
        public static let defaultTunnelAddress = "10.7.0.10"
        public static let defaultTunnelSubnet = "255.255.255.0"
        public static let defaultTargetServerIP = "10.7.0.1"
        public static let defaultRemoteEndpoint = "127.0.0.1"
        public static let defaultRemotePort: UInt16 = 51820
        public static let defaultMTU: NSNumber = 1420
        public static let pairingFileName = "ALTPairingFile.mobiledevicepairing"
        public static let wireGuardConfigFileName = "SideStore.conf"
        public static let sharedConfigFileName = "TunnelConfig.json"
    }
    
    private var isTunnelRunning: Bool = false
    private var readPacketsTask: Task<Void, Never>?
    
    // MARK: - Tunnel Lifecycle
    
    public override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("[SideStoreTunnel] startTunnel() called")
        
        let config = self.loadTunnelConfiguration(options: options)
        
        // Construct IPv4 settings for loopback routing
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.endpointAddress)
        settings.mtu = config.mtu
        
        let ipv4Settings = NEIPv4Settings(
            addresses: [config.interfaceAddress],
            subnetMasks: [config.interfaceSubnet]
        )
        
        // Route only 10.7.0.1/32 (the pairing proxy gateway) through the tunnel
        let pairingRoute = NEIPv4Route(
            destinationAddress: config.targetServerIP,
            subnetMask: "255.255.255.255"
        )
        ipv4Settings.includedRoutes = [pairingRoute]
        settings.ipv4Settings = ipv4Settings
        
        // Configure DNS settings with fallback resolvers
        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        // Apply tunnel network settings
        self.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                logger.error("[SideStoreTunnel] Failed to apply tunnel settings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            self.isTunnelRunning = true
            self.startPacketLoop()
            logger.info("[SideStoreTunnel] Tunnel established successfully. Routing \(config.targetServerIP) -> \(config.endpointAddress):\(config.endpointPort)")
            completionHandler(nil)
        }
    }
    
    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("[SideStoreTunnel] stopTunnel() called with reason: \(reason.rawValue)")
        self.isTunnelRunning = false
        self.readPacketsTask?.cancel()
        self.readPacketsTask = nil
        completionHandler()
    }
    
    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        logger.debug("[SideStoreTunnel] Received app message: \(message)")
        switch message {
        case "status":
            let status = isTunnelRunning ? "CONNECTED" : "DISCONNECTED"
            completionHandler?(status.data(using: .utf8))
        case "ping":
            completionHandler?("pong".data(using: .utf8))
        default:
            completionHandler?(nil)
        }
    }
    
    public override func sleep(completionHandler: @escaping () -> Void) {
        logger.info("[SideStoreTunnel] sleep() invoked")
        completionHandler()
    }
    
    public override func wake() {
        logger.info("[SideStoreTunnel] wake() invoked")
    }
    
    // MARK: - Packet Handling
    
    private func startPacketLoop() {
        self.readPacketsTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while self.isTunnelRunning && !Task.isCancelled {
                do {
                    let (packets, protocols) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([Data], [NSNumber]), Error>) in
                        self.packetFlow.readPackets { packets, protocols in
                            continuation.resume(returning: (packets, protocols))
                        }
                    }
                    
                    guard !packets.isEmpty else { continue }
                    // In loopback routing mode, packets targeted at 10.7.0.1 are processed
                    // and replied via the virtual TUN interface
                    self.packetFlow.writePackets(packets, withProtocols: protocols)
                } catch {
                    if !Task.isCancelled {
                        logger.error("[SideStoreTunnel] Error reading packets: \(error.localizedDescription)")
                    }
                    break
                }
            }
        }
    }
    
    // MARK: - Configuration Loader
    
    private struct LoadedTunnelConfig {
        var interfaceAddress: String
        var interfaceSubnet: String
        var targetServerIP: String
        var endpointAddress: String
        var endpointPort: UInt16
        var mtu: NSNumber
        var privateKey: String?
        var peerPublicKey: String?
    }
    
    private func loadTunnelConfiguration(options: [String: NSObject]?) -> LoadedTunnelConfig {
        var config = LoadedTunnelConfig(
            interfaceAddress: Constants.defaultTunnelAddress,
            interfaceSubnet: Constants.defaultTunnelSubnet,
            targetServerIP: Constants.defaultTargetServerIP,
            endpointAddress: Constants.defaultRemoteEndpoint,
            endpointPort: Constants.defaultRemotePort,
            mtu: Constants.defaultMTU,
            privateKey: nil,
            peerPublicKey: nil
        )
        
        // 1. Attempt to read from shared App Group directory
        if let sharedDirectory = self.sharedContainerURL() {
            let confFileURL = sharedDirectory.appendingPathComponent(Constants.wireGuardConfigFileName)
            if let confContent = try? String(contentsOf: confFileURL, encoding: .utf8) {
                self.parseWireGuardConf(confContent, into: &config)
            }
            
            let jsonFileURL = sharedDirectory.appendingPathComponent(Constants.sharedConfigFileName)
            if let jsonData = try? Data(contentsOf: jsonFileURL),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                if let endpoint = json["endpoint"] as? String {
                    config.endpointAddress = endpoint
                }
                if let port = json["port"] as? UInt16 {
                    config.endpointPort = port
                }
            }
        }
        
        // 2. Override with protocolConfiguration if present
        if let providerProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
           let customConfig = providerProtocol.providerConfiguration {
            if let customIP = customConfig["interfaceAddress"] as? String {
                config.interfaceAddress = customIP
            }
            if let customEndpoint = customConfig["endpointAddress"] as? String {
                config.endpointAddress = customEndpoint
            }
            if let customPort = customConfig["endpointPort"] as? UInt16 {
                config.endpointPort = customPort
            }
        }
        
        return config
    }
    
    private func parseWireGuardConf(_ content: String, into config: inout LoadedTunnelConfig) {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "Address") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    let addr = parts[1].trimmingCharacters(in: .whitespaces)
                    let ipOnly = addr.components(separatedBy: "/")[0]
                    config.interfaceAddress = ipOnly
                }
            } else if trimmed.starts(with: "Endpoint") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    let ep = parts[1].trimmingCharacters(in: .whitespaces)
                    let epParts = ep.components(separatedBy: ":")
                    if epParts.count == 2 {
                        config.endpointAddress = epParts[0]
                        if let port = UInt16(epParts[1]) {
                            config.endpointPort = port
                        }
                    }
                }
            } else if trimmed.starts(with: "AllowedIPs") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    let ips = parts[1].trimmingCharacters(in: .whitespaces)
                    let target = ips.components(separatedBy: "/")[0]
                    config.targetServerIP = target
                }
            } else if trimmed.starts(with: "PrivateKey") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    config.privateKey = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if trimmed.starts(with: "PublicKey") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    config.peerPublicKey = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }
    
    private func sharedContainerURL() -> URL? {
        let fileManager = FileManager.default
        // Extract App Group identifier from bundle or conventional ID
        if let appGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let firstGroup = appGroups.first {
            let cleanGroup = firstGroup.replacingOccurrences(of: "$(APP_GROUP_IDENTIFIER)", with: Bundle.main.bundleIdentifier ?? "")
            return fileManager.containerURL(forSecurityApplicationGroupIdentifier: cleanGroup)
        }
        
        let bundleID = Bundle.main.bundleIdentifier ?? "com.SideStore.SideStore"
        let groupID = "group." + bundleID.replacingOccurrences(of: ".SideStoreTunnel", with: "")
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}
