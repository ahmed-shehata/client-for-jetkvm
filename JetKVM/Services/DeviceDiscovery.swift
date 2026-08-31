import Foundation
import Network
import os

/// Discovers JetKVM devices on the local network.
///
/// JetKVM advertises via hostname-based mDNS (pion/mdns), not Bonjour service registration.
/// Discovery works by:
///   1. Resolving known JetKVM hostname patterns (e.g. jetkvm.local)
///   2. Manual IP entry with live probing via /device/status
@Observable
final class DeviceDiscovery: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.jetkvm.app", category: "Discovery")
    private let queue = DispatchQueue(label: "com.jetkvm.discovery")
    private static let savedDevicesKey = "com.jetkvm.savedDevices"
    var discoveredDevices: [KVMDevice] = []
    var isSearching = false

    /// Known JetKVM mDNS hostname patterns to try resolving
    private let knownHostnames = [
        "jetkvm.local",
        "jetkvm-kvm.local",
    ]

    func startBrowsing() {
        loadSavedDevices()
        Task { @MainActor in self.isSearching = true }

        // Re-probe saved devices to refresh names / check reachability
        for device in discoveredDevices {
            probeDevice(host: device.host, name: device.name)
        }

        // Try resolving known JetKVM hostnames via mDNS
        for hostname in knownHostnames {
            resolveHostname(hostname)
        }

        // Stop searching indicator after timeout
        Task {
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run { self.isSearching = false }
        }
    }

    func stopBrowsing() {
        Task { @MainActor in self.isSearching = false }
    }

    private func resolveHostname(_ hostname: String) {
        let host = NWEndpoint.Host(hostname)
        let port = NWEndpoint.Port(integerLiteral: 80)
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let remote = path.remoteEndpoint,
                   case .hostPort(let resolvedHost, _) = remote {
                    let ip = "\(resolvedHost)"
                    self.logger.info("Resolved \(hostname) → \(ip)")
                    self.probeDevice(host: ip, name: hostname.replacingOccurrences(of: ".local", with: ""))
                }
                connection.cancel()
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Cancel after timeout
        queue.asyncAfter(deadline: .now() + 4) {
            connection.cancel()
        }
    }

    /// Probe an IP address to check if it's a JetKVM device.
    func probeDevice(host: String, name: String? = nil) {
        Task {
            let scheme = host.hasSuffix(".ts.net") ? "https" : "http"
            let url = URL(string: "\(scheme)://\(host)/device/status")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 3

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                let _ = try JSONDecoder().decode(DeviceStatus.self, from: data)

                // Confirmed JetKVM — get a friendly name
                let deviceName = await fetchDeviceName(host: host) ?? name ?? host
                await MainActor.run {
                    if let idx = self.discoveredDevices.firstIndex(where: { $0.host == host }) {
                        self.discoveredDevices[idx].name = deviceName
                    } else {
                        self.discoveredDevices.append(KVMDevice(name: deviceName, host: host, port: 80))
                    }
                    self.saveDevices()
                    self.logger.info("Found JetKVM at \(host)")
                }
            } catch {
                // Not a JetKVM or unreachable
            }
        }
    }

    private func fetchDeviceName(host: String) async -> String? {
        let scheme = host.hasSuffix(".ts.net") ? "https" : "http"
        let url = URL(string: "\(scheme)://\(host)/device")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else {
            return nil
        }
        return info.deviceId.map { "KVM (\($0.prefix(8)))" }
    }

    /// Add a device manually by IP address. Adds immediately and probes in background.
    func addManualDevice(host: String, port: Int = 80) {
        let input = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedHost = input.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var normalizedPort = port

        // Accept either a bare hostname/IP or a complete URL pasted from a browser.
        if input.contains("://"), let url = URL(string: input), let urlHost = url.host {
            normalizedHost = urlHost
            normalizedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        } else if normalizedHost.hasSuffix(".ts.net") && port == 80 {
            normalizedPort = 443
        }

        guard !normalizedHost.isEmpty else { return }
        let deviceHost = normalizedHost
        let devicePort = normalizedPort

        // Add immediately so it appears in the list
        Task { @MainActor in
            if !self.discoveredDevices.contains(where: { $0.host == deviceHost && $0.port == devicePort }) {
                self.discoveredDevices.append(KVMDevice(name: deviceHost, host: deviceHost, port: devicePort))
                self.saveDevices()
            }
        }
        // Probe in background to update name
        probeDevice(host: deviceHost, name: deviceHost)
    }

    /// Remove a device from the saved list.
    func removeDevice(_ device: KVMDevice) {
        discoveredDevices.removeAll { $0.id == device.id }
        saveDevices()
    }

    /// Rename a device.
    func renameDevice(_ device: KVMDevice, to newName: String) {
        guard let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) else { return }
        discoveredDevices[idx].name = newName
        saveDevices()
    }

    /// Update a device's shortcuts.
    func updateShortcuts(_ device: KVMDevice, shortcuts: [KVMShortcut]) {
        guard let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) else { return }
        discoveredDevices[idx].shortcuts = shortcuts
        saveDevices()
    }

    // MARK: - Persistence

    private func saveDevices() {
        guard let data = try? JSONEncoder().encode(discoveredDevices) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedDevicesKey)
    }

    private func loadSavedDevices() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedDevicesKey) else {
            return
        }
        guard let devices = try? JSONDecoder().decode([KVMDevice].self, from: data) else { return }
        for device in devices {
            if !discoveredDevices.contains(where: { $0.host == device.host && $0.port == device.port }) {
                discoveredDevices.append(device)
            }
        }
        saveDevices()
    }
}
