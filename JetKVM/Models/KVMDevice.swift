import Foundation

struct KVMShortcut: Identifiable, Codable, Hashable {
    let id: String
    var label: String
    var modifiers: UInt8    // HID modifier byte
    var keycode: UInt8      // HID keycode (0 = modifier-only)

    init(id: String = UUID().uuidString, label: String, modifiers: UInt8 = 0, keycode: UInt8 = 0) {
        self.id = id
        self.label = label
        self.modifiers = modifiers
        self.keycode = keycode
    }

    /// Common presets
    static let presets: [KVMShortcut] = [
        KVMShortcut(label: "⌘ Space", modifiers: KeyMapping.modLeftGUI, keycode: 0x2C),
        KVMShortcut(label: "⌘ Tab", modifiers: KeyMapping.modLeftGUI, keycode: 0x2B),
        KVMShortcut(label: "Ctrl+Alt+Del", modifiers: KeyMapping.modLeftControl | KeyMapping.modLeftAlt, keycode: 0x4C),
        KVMShortcut(label: "Super/Win", modifiers: KeyMapping.modLeftGUI, keycode: 0),
        KVMShortcut(label: "Alt+Tab", modifiers: KeyMapping.modLeftAlt, keycode: 0x2B),
        KVMShortcut(label: "Alt+F4", modifiers: KeyMapping.modLeftAlt, keycode: 0x3D),
        KVMShortcut(label: "Ctrl+C", modifiers: KeyMapping.modLeftControl, keycode: 0x06),
        KVMShortcut(label: "Ctrl+V", modifiers: KeyMapping.modLeftControl, keycode: 0x19),
        KVMShortcut(label: "Ctrl+Z", modifiers: KeyMapping.modLeftControl, keycode: 0x1D),
        KVMShortcut(label: "Ctrl+Alt+T", modifiers: KeyMapping.modLeftControl | KeyMapping.modLeftAlt, keycode: 0x17),
    ]
}

struct KVMDevice: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var shortcuts: [KVMShortcut]

    var baseURL: URL {
        URL(string: "\(port == 443 ? "https" : "http")://\(host):\(port)")!
    }

    var webSocketURL: URL {
        URL(string: "\(port == 443 ? "wss" : "ws")://\(host):\(port)/webrtc/signaling/client")!
    }

    init(id: String = UUID().uuidString, name: String, host: String, port: Int = 80, shortcuts: [KVMShortcut] = []) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.shortcuts = shortcuts
    }
}

struct DeviceStatus: Codable {
    let isSetup: Bool
}

struct DeviceInfo: Codable {
    let authMode: String?
    let deviceId: String?
}
