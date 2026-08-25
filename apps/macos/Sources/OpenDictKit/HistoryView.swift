import OpenDictCore
import SwiftUI

// The core's record already carries a unique row id.
extension HistoryEntry: Identifiable {}

/// Everything you have dictated, searchable, with the two operations that make
/// a history worth keeping: put it back on the clipboard, and try a different
/// mode on what you actually said.
struct HistoryTab: View {
    @ObservedObject var model: AppModel

    @State private var query = ""
    @State private var entries: [HistoryEntry] = []
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.historyEnabled {
                message(
                    "History is off",
                    detail: "Nothing is being written down. Existing entries are kept until you "
                        + "clear them.")
            } else if entries.isEmpty {
                message(
                    query.isEmpty ? "Nothing yet" : "No matches",
                    detail: query.isEmpty
                        ? "Dictations show up here as you make them."
                        : "No dictation contains “\(query)”.")
            } else {
                list
            }
        }
        .onAppear(perform: reload)
        // The two-argument form: the app targets macOS 13, where the newer
        // zero-argument closure does not exist.
        .onChange(of: query) { _ in reload() }
        .onChange(of: model.historyRevision) { _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search what you said or what was written", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 16) {
                Toggle(
                    "Record history",
                    isOn: Binding(get: { model.historyEnabled }, set: { model.historyEnabled = $0 })
                )
                Picker(
                    "Keep",
                    selection: Binding(get: { model.historyLimit }, set: { model.historyLimit = $0 })
                ) {
                    Text("100").tag(100)
                    Text("1,000").tag(1000)
                    Text("10,000").tag(10000)
                }
                .frame(width: 150)
                Spacer()
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Clear…", systemImage: "trash")
                }
                .confirmationDialog(
                    "Delete every dictation in your history?",
                    isPresented: $confirmingClear
                ) {
                    Button("Delete All", role: .destructive) {
                        model.clearHistory()
                    }
                } message: {
                    Text("This cannot be undone.")
                }
            }
            Text(
                "Dictations are stored on this Mac only — text, never audio. Modes with history "
                    + "switched off, including the Private preset, are never recorded."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry, model: model)
                    Divider()
                }
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        // An empty query is the unfiltered list — the core treats it that way,
        // so there is no separate "recent" path to keep in step with this one.
        entries = model.historySearch(query)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: AppModel

    @State private var rerunResult: DictationResult?
    @State private var rerunError: String?
    @State private var rerunning = false
    @State private var showingRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if entry.kind == .command {
                    Label("Command", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                Text(Self.timestamp(entry.createdAt))
                Text("·")
                Text(entry.modeName)
                if let app = entry.appName {
                    Text("·")
                    Text(app)
                }
                Text("·")
                Text("\(entry.totalMs) ms")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)

            Text(entry.finalText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Worth showing only when cleanup actually changed something —
            // otherwise it is the same sentence twice.
            if entry.cleanupRan, entry.rawText != entry.finalText {
                DisclosureGroup(isExpanded: $showingRaw) {
                    Text(entry.rawText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("What you said").font(.caption)
                }
            }

            if let cleanupError = entry.cleanupError {
                Label("Cleanup failed: \(cleanupError)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    copy(entry.finalText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Menu {
                    ForEach(model.modes) { mode in
                        Button(mode.name) { rerun(with: mode) }
                    }
                } label: {
                    Label("Re-run cleanup", systemImage: "arrow.clockwise")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(rerunning || entry.rawText.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    model.deleteHistoryEntry(entry.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .font(.caption)

            if rerunning {
                ProgressView().controlSize(.small)
            }
            if let rerunError {
                Label(rerunError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let rerunResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(rerunResult.modeName) · \(rerunResult.timings.cleanupMs) ms")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { copy(rerunResult.finalText) }
                            .buttonStyle(.borderless).font(.caption)
                        Button("Dismiss") { self.rerunResult = nil }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    Text(rerunResult.finalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Re-running does not touch the stored entry: it answers "what would this
    /// mode have written?", which is how you decide whether to switch to it.
    private func rerun(with mode: Mode) {
        rerunning = true
        rerunError = nil
        rerunResult = nil
        Task {
            do {
                rerunResult = try await model.rerun(entryId: entry.id, modeId: mode.id)
            } catch {
                rerunError = AppDelegate.describe(error)
            }
            rerunning = false
        }
    }

    static func timestamp(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
