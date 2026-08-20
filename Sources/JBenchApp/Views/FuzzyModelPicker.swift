import SwiftUI
import JBenchCore

public struct FuzzyModelPicker: View {
    let harness: HarnessKind
    @Binding var selectedModel: String
    let availableModels: [String]
    var catalogEntries: [ModelCatalogEntry] = []

    @State private var isShowingPopover = false
    @State private var searchQuery = ""
    @State private var highlightedIndex: Int = 0
    @State private var hoveredModel: String?
    @FocusState private var isSearchFocused: Bool

    public init(
        harness: HarnessKind,
        selectedModel: Binding<String>,
        availableModels: [String],
        catalogEntries: [ModelCatalogEntry] = []
    ) {
        self.harness = harness
        self._selectedModel = selectedModel
        self.availableModels = availableModels
        self.catalogEntries = catalogEntries
    }

    private var filteredResults: [FuzzyMatchResult<String>] {
        FuzzyMatcher.filter(query: searchQuery, candidates: availableModels)
    }

    private var harnessName: String {
        switch harness {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .agy: "Antigravity"
        case .fake: "Demo"
        }
    }

    public var body: some View {
        Button {
            searchQuery = ""
            highlightedIndex = availableModels.firstIndex(of: selectedModel) ?? 0
            isShowingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedModel.isEmpty ? "Select model…" : selectedModel)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel.isEmpty ? "None" : selectedModel)
        .help(selectedModel)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Search \(harnessName) models…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        selectHighlighted()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        isShowingPopover = false
                        return .handled
                    }
                    .onChange(of: searchQuery) { _, _ in
                        highlightedIndex = 0
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        highlightedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            }

            // Results count header
            HStack {
                Text("\(filteredResults.count) of \(availableModels.count) models")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !searchQuery.isEmpty {
                    Text("Fuzzy match")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)

            Divider()

            // Results list
            if filteredResults.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No matching models")
                        .font(.headline)
                    Text("No model matches \"\(searchQuery)\" for \(harnessName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Clear search") {
                        searchQuery = ""
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredResults.enumerated()), id: \.element.item) { index, match in
                                let isSelected = match.item == selectedModel
                                let isHighlighted = index == highlightedIndex
                                let isHovered = hoveredModel == match.item
                                let isCustom = catalogEntries.first(where: { $0.nativeModelID == match.item })?.availability == .customNotVerified

                                Button {
                                    select(model: match.item)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.accentColor)
                                            .opacity(isSelected ? 1 : 0)
                                            .frame(width: 14)

                                        HighlightedModelText(
                                            fullText: match.item,
                                            matchedRanges: match.matchedRanges
                                        )

                                        Spacer()

                                        if isCustom {
                                            Text("Custom")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                    .background(
                                        isHighlighted
                                            ? Color.accentColor.opacity(0.18)
                                            : (isHovered
                                                ? Color.primary.opacity(0.06)
                                                : (isSelected ? Color.accentColor.opacity(0.08) : Color.clear)),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredModel = match.item
                                    } else if hoveredModel == match.item {
                                        hoveredModel = nil
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: highlightedIndex) { _, newIndex in
                        if filteredResults.indices.contains(newIndex) {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(filteredResults[newIndex].item, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        if filteredResults.indices.contains(highlightedIndex) {
                            proxy.scrollTo(filteredResults[highlightedIndex].item, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 360, height: 300)
        .onAppear {
            isSearchFocused = true
            if let idx = availableModels.firstIndex(of: selectedModel) {
                highlightedIndex = idx
            }
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !filteredResults.isEmpty else { return }
        let count = filteredResults.count
        var next = highlightedIndex + delta
        if next < 0 { next = count - 1 }
        if next >= count { next = 0 }
        highlightedIndex = next
    }

    private func selectHighlighted() {
        guard !filteredResults.isEmpty, filteredResults.indices.contains(highlightedIndex) else { return }
        select(model: filteredResults[highlightedIndex].item)
    }

    private func select(model: String) {
        selectedModel = model
        isShowingPopover = false
    }
}

private struct HighlightedModelText: View {
    let fullText: String
    let matchedRanges: [Range<String.Index>]

    var body: some View {
        Text(attributedText)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var attributedText: AttributedString {
        var attributed = AttributedString(fullText)
        for range in matchedRanges {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .accentColor
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return attributed
    }
}
