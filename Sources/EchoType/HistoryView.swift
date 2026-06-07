import SwiftUI
import AppKit

/// Transcription history window: pinned section on top, per-item
/// copy / pin / delete, checkbox multi-select with select-all /
/// delete-selected, and clear-all.
struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var selection = Set<UUID>()
    @State private var confirmingClear = false
    @State private var confirmingDeleteSelected = false

    private var pinned: [HistoryItem] { store.items.filter(\.pinned) }
    private var recent: [HistoryItem] { store.items.filter { !$0.pinned } }
    private var allSelected: Bool { !store.items.isEmpty && selection.count == store.items.count }

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                emptyState
            } else {
                selectionBar
                Divider()
                list
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 500)
        .onChange(of: store.items) { _, items in
            // Drop selections that no longer exist (deleted elsewhere).
            let ids = Set(items.map(\.id))
            selection = selection.intersection(ids)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No dictations yet")
                .foregroundStyle(.secondary)
            Text("Everything you dictate shows up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Always-visible selection controls: select/deselect all, delete selected.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(store.items.map(\.id))
            }
            .font(.caption)

            Spacer()

            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    confirmingDeleteSelected = true
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                        .font(.caption)
                }
                .confirmationDialog(
                    "Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?",
                    isPresented: $confirmingDeleteSelected
                ) {
                    Button("Delete", role: .destructive) {
                        store.delete(selection)
                        selection.removeAll()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var list: some View {
        List(selection: $selection) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { item in
                        row(for: item)
                    }
                }
            }
            if !recent.isEmpty {
                Section(pinned.isEmpty ? "History" : "Recent") {
                    ForEach(recent) { item in
                        row(for: item)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            confirmingDeleteSelected = true
        }
    }

    private func row(for item: HistoryItem) -> some View {
        HistoryRow(
            item: item,
            store: store,
            isSelected: selection.contains(item.id),
            toggleSelected: {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            }
        )
        .tag(item.id)
    }

    private var footer: some View {
        HStack {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear All…") { confirmingClear = true }
                .disabled(store.items.isEmpty)
                .confirmationDialog("Clear dictation history?", isPresented: $confirmingClear) {
                    Button("Clear All Except Pinned") {
                        store.clear(includingPinned: false)
                        selection.removeAll()
                    }
                    Button("Clear Everything", role: .destructive) {
                        store.clear(includingPinned: true)
                        selection.removeAll()
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
        .padding(10)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let store: HistoryStore
    let isSelected: Bool
    let toggleSelected: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Explicit checkbox: row-click selection on macOS lists is unreliable
            // when rows contain selectable text, so selection gets its own target.
            Button(action: toggleSelected) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect" : "Select")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(item.date, format: .dateTime.day().month().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    iconButton(item.pinned ? "pin.fill" : "pin", help: item.pinned ? "Unpin" : "Pin") {
                        store.togglePin(item.id)
                    }
                    iconButton("trash", help: "Delete") {
                        store.delete([item.id])
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
            Button(isSelected ? "Deselect" : "Select") { toggleSelected() }
            Divider()
            Button("Delete", role: .destructive) { store.delete([item.id]) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
