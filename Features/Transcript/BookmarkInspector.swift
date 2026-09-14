import SwiftUI

/// Right-hand pin list for the open recording. Hidden when that recording has
/// no bookmarks; collapses to a narrow rail so the transcript keeps its width.
struct BookmarkInspector: View {
    let library: LibraryModel
    @Binding var collapsed: Bool

    var body: some View {
        Group {
            if collapsed {
                collapsedRail
            } else {
                expandedList
            }
        }
        .animation(.easeInOut(duration: 0.18), value: collapsed)
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
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
