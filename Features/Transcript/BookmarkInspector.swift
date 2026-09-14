import SwiftUI

/// Right-hand pin list for the open recording. Hidden when that recording has
/// no bookmarks; collapses to a narrow rail so the transcript keeps its width.
struct BookmarkInspector: View {
    let library: LibraryModel
    @Binding var collapsed: Bool
    @State private var editingBookmark: Bookmark?

    var body: some View {
        Group {
            if collapsed {
                collapsedRail
            } else {
                expandedList
            }
        }
        .animation(.easeInOut(duration: 0.18), value: collapsed)
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkTextEditor(bookmark: bookmark, controller: library.bookmarks)
        }
    }

    private var collapsedRail: some View {
        Button {
            collapsed = false
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "pin.fill")
                Text("\(library.bookmarks.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
            .frame(width: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show bookmarks")
        .help("Show bookmarks")
    }

    private var expandedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Bookmarks", systemImage: "pin.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Button {
                    collapsed = true
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .help("Hide bookmarks")
                .accessibilityLabel("Hide bookmarks")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(library.bookmarks.items) { bookmark in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                library.openBookmark(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playbackTime(bookmark.time))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(bookmark.label ?? "Pinned passage")
                                        .font(.callout)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            Button {
                                editingBookmark = bookmark
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .help("Edit bookmark text")
                            .accessibilityLabel("Edit bookmark at \(playbackTime(bookmark.time))")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit Text…") {
                                editingBookmark = bookmark
                            }
                            Button("Remove Pin", role: .destructive) {
                                library.bookmarks.remove(bookmark)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 240)
    }
}

private struct BookmarkTextEditor: View {
    let bookmark: Bookmark
    let controller: BookmarkController
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var saveFailed = false
    @FocusState private var textFocused: Bool

    init(bookmark: Bookmark, controller: BookmarkController) {
        self.bookmark = bookmark
        self.controller = controller
        _text = State(initialValue: bookmark.label ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Bookmark Text").font(.headline)
            Text("Saved at \(playbackTime(bookmark.time)) · timestamp stays unchanged")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Bookmark text", text: $text, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .disabled(saving)
                .onChange(of: text) { _, value in
                    if value.count > 80 {
                        text = String(value.prefix(80))
                    }
                }
            Text("\(text.count)/80 characters. Leave empty to use “Pinned passage”.")
                .font(.caption).foregroundStyle(.secondary)
            if saveFailed {
                Text("Couldn’t save the bookmark. Your text is still here; please try again.")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    saveFailed = false
                    Task {
                        do {
                            try await controller.rename(bookmark, label: text)
                            dismiss()
                        } catch {
                            saveFailed = true
                            saving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(saving)
        .onAppear { textFocused = true }
    }
}
