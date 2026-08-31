import SwiftUI

/// Device discovery and selection sidebar.
struct DeviceListView: View {
    var compactNavigation = false
    @Environment(AppState.self) private var appState
    @State private var discovery = DeviceDiscovery()
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "80"
    @State private var editingDevice: KVMDevice?
    @State private var showRenameAlert = false
    @State private var editName = ""
    @State private var showShortcutEditor: KVMDevice?
    #if os(iOS)
    @State private var presentedDevice: KVMDevice?
    @AppStorage("hasSeenSwipeHint") private var hasSeenSwipeHint = false
    @State private var showSwipeHint = false
    #endif

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedDevice },
            set: { appState.selectedDevice = $0 }
        )) {
            Section {
                ForEach(discovery.discoveredDevices) { device in
                    Group {
                        if compactNavigation {
                            Button {
                                presentedDevice = device
                            } label: {
                                deviceRow(device)
                            }
                            .buttonStyle(.plain)
                        } else {
                            deviceRow(device)
                        }
                    }
                        .tag(device)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                discovery.removeDevice(device)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                showShortcutEditor = device
                            } label: {
                                Label("Shortcuts", systemImage: "command")
                            }
                            .tint(.purple)
                            Button {
                                startEditing(device)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                Text("Devices")
            } footer: {
                #if os(iOS)
                if showSwipeHint && !discovery.discoveredDevices.isEmpty {
                    SwipeHintView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #endif
            }
        }
        .navigationTitle("OrbitKVM")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showManualEntry = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
            }
        }
        .alert("Add Device", isPresented: $showManualEntry) {
            TextField("IP Address or Hostname", text: $manualHost)
            TextField("Port", text: $manualPort)
            Button("Add") {
                let port = Int(manualPort) ?? 80
                discovery.addManualDevice(host: manualHost, port: port)
                manualHost = ""
                manualPort = "80"
            }
            Button("Cancel", role: .cancel) {
                manualHost = ""
                manualPort = "80"
            }
        } message: {
            Text("Enter the IP address or hostname of your KVM device.")
        }
        .alert("Rename Device", isPresented: $showRenameAlert) {
            TextField("Device Name", text: $editName)
            Button("Save") {
                if let device = editingDevice, !editName.isEmpty {
                    discovery.renameDevice(device, to: editName)
                }
                editingDevice = nil
            }
            Button("Cancel", role: .cancel) {
                editingDevice = nil
            }
        } message: {
            Text("Enter a new name for this device.")
        }
        .sheet(item: $showShortcutEditor) { device in
            ShortcutEditorView(device: device, discovery: discovery) {
                showShortcutEditor = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $presentedDevice) { device in
            NavigationStack {
                KVMView(device: device) {
                    presentedDevice = nil
                }
            }
            .interactiveDismissDisabled()
        }
        #endif
        .onChange(of: showManualEntry) { _, open in
            appState.keyboardCaptureEnabled = !open
        }
        .onChange(of: editingDevice) { _, device in
            if device != nil {
                showRenameAlert = true
                appState.keyboardCaptureEnabled = false
            }
        }
        .onChange(of: showRenameAlert) { _, open in
            if !open { appState.keyboardCaptureEnabled = true }
        }
        .onChange(of: showShortcutEditor) { _, device in
            appState.keyboardCaptureEnabled = (device == nil)
        }
        .onAppear {
            discovery.startBrowsing()
            #if os(iOS)
            if !hasSeenSwipeHint {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showSwipeHint = true
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation(.easeIn(duration: 0.4)) {
                        showSwipeHint = false
                    }
                    hasSeenSwipeHint = true
                }
            }
            #endif
        }
        .onDisappear {
            discovery.stopBrowsing()
        }
    }

    private func startEditing(_ device: KVMDevice) {
        editName = device.name
        editingDevice = device
    }

    private func deviceRow(_ device: KVMDevice) -> some View {
        DeviceRow(device: device,
                  onEdit: { startEditing(device) },
                  onShortcuts: { showShortcutEditor = device },
                  onDelete: { discovery.removeDevice(device) })
    }
}

#if os(iOS)
private struct SwipeHintView: View {
    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Swipe right to edit · Swipe left to delete")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.left.chevron.left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .offset(x: arrowOffset)
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatCount(3, autoreverses: true)) {
                arrowOffset = -6
            }
        }
    }
}
#endif

private struct DeviceRow: View {
    let device: KVMDevice
    var onEdit: () -> Void
    var onShortcuts: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("\(device.host):\(device.port)")
                    if !device.shortcuts.isEmpty {
                        Text("• \(device.shortcuts.count) shortcut\(device.shortcuts.count == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            #if os(macOS)
            Spacer()
            Button { onShortcuts() } label: {
                Image(systemName: "command")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit Shortcuts")
            Button { onEdit() } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            #endif
        }
    }
}

// MARK: - Shortcut Editor

struct ShortcutEditorView: View {
    let device: KVMDevice
    let discovery: DeviceDiscovery
    let onDismiss: () -> Void

    @State private var shortcuts: [KVMShortcut] = []
    @State private var showPresets = false

    var body: some View {
        NavigationStack {
            List {
                Section("Active Shortcuts") {
                    if shortcuts.isEmpty {
                        Text("No shortcuts configured")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shortcuts) { shortcut in
                        HStack {
                            Text(shortcut.label)
                            Spacer()
                            Text(shortcut.describeCombo())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            #if os(macOS)
                            Button {
                                shortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            #endif
                        }
                    }
                    .onDelete { indexSet in
                        shortcuts.remove(atOffsets: indexSet)
                    }
                }

                Section("Add from Presets") {
                    ForEach(KVMShortcut.presets.filter { preset in
                        !shortcuts.contains(where: { $0.label == preset.label })
                    }) { preset in
                        Button {
                            shortcuts.append(preset)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.green)
                                Text(preset.label)
                                Spacer()
                                Text(preset.describeCombo())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Shortcuts — \(device.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        discovery.updateShortcuts(device, shortcuts: shortcuts)
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                #endif
            }
        }
        .onAppear {
            shortcuts = device.shortcuts
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
    }
}

extension KVMShortcut {
    func describeCombo() -> String {
        var parts: [String] = []
        if modifiers & KeyMapping.modLeftControl != 0 { parts.append("Ctrl") }
        if modifiers & KeyMapping.modLeftShift != 0 { parts.append("Shift") }
        if modifiers & KeyMapping.modLeftAlt != 0 { parts.append("Alt") }
        if modifiers & KeyMapping.modLeftGUI != 0 { parts.append("Cmd/Win") }
        if keycode != 0 { parts.append("0x\(String(keycode, radix: 16, uppercase: true))") }
        return parts.joined(separator: "+")
    }
}
