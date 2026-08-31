import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            NavigationStack {
                DeviceListView(compactNavigation: true)
            }
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView {
            DeviceListView()
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                #endif
        } detail: {
            if let device = appState.selectedDevice {
                #if os(iOS)
                NavigationStack {
                    KVMView(device: device)
                }
                #else
                KVMView(device: device)
                #endif
            } else {
                ContentUnavailableView(
                    "No Device Selected",
                    systemImage: "desktopcomputer",
                    description: Text("Select a KVM device from the sidebar or add one manually.")
                )
            }
        }
    }
}
