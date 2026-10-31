import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var connected = ClaudeCode.isConnected
    @State private var connecting = false
    @State private var connectError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") {
                    if connected {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(connecting ? "Connecting…" : "Connect") {
                            connecting = true
                            Task {
                                connectError = await ClaudeCode.connect(server: ClaudeCode.helper)
                                connecting = false
                                connected = ClaudeCode.isConnected
                            }
                        }
                        .disabled(connecting)
                    }
                }
                if let connectError { Text(connectError).foregroundStyle(.red).font(.callout) }
            }
            Section {
                LabeledContent("Version", value: model.updater.current)
                LabeledContent {
                    Button("Check Now") { Task { await model.updater.check(interactive: true) } }
                        .disabled(!model.updater.enabled)
                } label: {
                    Text("Updates")
                    Text(updateText)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connected = ClaudeCode.isConnected
        }
    }

    private var updateText: String {
        guard model.updater.enabled else { return "Off in development builds" }
        if let v = model.updater.ready { return "\(v) installs when Cutline quits" }
        return "Install automatically"
    }
}
