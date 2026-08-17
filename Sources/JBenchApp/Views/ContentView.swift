import SwiftUI
import JBenchCore

struct ContentView: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            Group {
                switch store.section {
                case .newRun: NewRunView(store: store)
                case .history: HistoryView(store: store)
                case .presets: PresetsView(store: store)
                case .settings: SettingsDetailView(store: store)
                }
            }
            .navigationTitle("JBench")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.section == .newRun {
                        Button("Run \(store.configurations.count) Agents", systemImage: "play.fill") {
                            store.start(prompt: store.prompt, directory: store.directory, mode: store.executionMode, configurations: store.configurations)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canRun)
                    }
                    Button("Settings", systemImage: "gearshape") { store.section = .settings }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_040, minHeight: 680)
    }
}

private struct SidebarView: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        List(selection: $store.section) {
            Section {
                Label(AppSection.newRun.title, systemImage: AppSection.newRun.systemImage)
                    .tag(AppSection.newRun)
                Label(AppSection.history.title, systemImage: AppSection.history.systemImage)
                    .tag(AppSection.history)
            }

            Section("PRESETS") {
                ForEach(store.presets) { preset in
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: "bookmark")
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    store.section = .presets
                } label: {
                    Label("Manage Presets", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.plain)
            }

            Section {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                    .tag(AppSection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("JBench")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: store.isBackgroundRunActive ? "bolt.fill" : "circle.fill")
                    .foregroundStyle(store.isBackgroundRunActive ? .orange : .green)
                    .font(.caption)
                Text(store.statusMessage)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }
}
