import SwiftUI
import JBenchCore

struct ContentView: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 400)
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
        .frame(minWidth: 1_040, minHeight: 680)
    }
}

private struct SidebarView: View {
    @Bindable var store: JBenchAppStore
    @State private var search = ""
    @State private var directoryFilter = ""
    @State private var modelFilter = ""
    @State private var harnessFilter: HarnessKind?
    @State private var verdictOnly = false
    @State private var useDateRange = false
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var toDate = Date.now
    @State private var filtersExpanded = false

    private var filteredHistory: [HistoryPresentation] {
        store.history.filter { item in
            let textMatches = search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.prompt.localizedCaseInsensitiveContains(search) || item.directory.localizedCaseInsensitiveContains(search)
            let directoryMatches = directoryFilter.isEmpty || item.directory.localizedCaseInsensitiveContains(directoryFilter)
            let harnessMatches = harnessFilter == nil || item.lanes.contains { $0.configuration.harness == harnessFilter }
            let modelMatches = modelFilter.isEmpty || item.lanes.contains { $0.configuration.model.localizedCaseInsensitiveContains(modelFilter) }
            let verdictMatches = !verdictOnly || store.hasVerdict(for: item.id)
            let endDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: toDate) ?? toDate
            let dateMatches = !useDateRange || (item.date >= Calendar.current.startOfDay(for: fromDate) && item.date <= endDate)
            return textMatches && directoryMatches && harnessMatches && modelMatches && verdictMatches && dateMatches
        }
    }

    var body: some View {
        List(selection: $store.section) {
            Section {
                Label(AppSection.newRun.title, systemImage: AppSection.newRun.systemImage)
                    .tag(AppSection.newRun)
            }

            Section("RUNS") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search runs", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 5, trailing: 0))
                .listRowBackground(Color.clear)

                ForEach(filteredHistory) { item in
                    Button {
                        store.section = .history
                        store.selectedHistoryID = item.id
                        store.loadVerdictForSelectedHistory()
                    } label: {
                        SidebarRunRow(item: item, isSelected: store.section == .history && store.selectedHistoryID == item.id, hasVerdict: store.hasVerdict(for: item.id))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if filteredHistory.isEmpty {
                    Text(search.isEmpty ? "No runs yet" : "No matching runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                }

                DisclosureGroup("Filters", isExpanded: $filtersExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Directory", text: $directoryFilter)
                        TextField("Model", text: $modelFilter)
                        Picker("Harness", selection: $harnessFilter) {
                            Text("Any harness").tag(HarnessKind?.none)
                            Text("Codex").tag(HarnessKind?.some(.codex))
                            Text("OpenCode").tag(HarnessKind?.some(.openCode))
                            Text("Antigravity (agy)").tag(HarnessKind?.some(.agy))
                        }
                        Toggle("Has verdict", isOn: $verdictOnly)
                        Toggle("Date range", isOn: $useDateRange)
                        if useDateRange {
                            DatePicker("From", selection: $fromDate, displayedComponents: .date)
                            DatePicker("To", selection: $toDate, displayedComponents: .date)
                        }
                        Button("Delete All History", role: .destructive) { store.prepareDeleteAllHistory() }
                            .disabled(store.history.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
                }
                .listRowBackground(Color.clear)
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
        .onAppear { reconcileHistorySelection() }
        .onChange(of: store.history) { _, _ in reconcileHistorySelection() }
        .onChange(of: store.section) { _, _ in reconcileHistorySelection() }
        .onChange(of: search) { _, _ in reconcileHistorySelection() }
        .onChange(of: directoryFilter) { _, _ in reconcileHistorySelection() }
        .onChange(of: modelFilter) { _, _ in reconcileHistorySelection() }
        .onChange(of: harnessFilter) { _, _ in reconcileHistorySelection() }
        .onChange(of: verdictOnly) { _, _ in reconcileHistorySelection() }
        .onChange(of: useDateRange) { _, _ in reconcileHistorySelection() }
        .onChange(of: fromDate) { _, _ in reconcileHistorySelection() }
        .onChange(of: toDate) { _, _ in reconcileHistorySelection() }
    }

    private func reconcileHistorySelection() {
        guard store.section == .history else { return }
        guard let selectedID = store.selectedHistoryID, filteredHistory.contains(where: { $0.id == selectedID }) else {
            store.selectedHistoryID = filteredHistory.first?.id
            store.loadVerdictForSelectedHistory()
            return
        }
    }
}

private struct SidebarRunRow: View {
    let item: HistoryPresentation
    let isSelected: Bool
    let hasVerdict: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                StateBadge(state: item.state)
                Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.84) : .secondary)
            }
            HStack(spacing: 5) {
                Text(URL(fileURLWithPath: item.directory).lastPathComponent)
                    .lineLimit(1)
                Text("· \(item.lanes.count) agents")
                if hasVerdict {
                    Image(systemName: "star.fill")
                        .foregroundStyle(isSelected ? .yellow : .orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
