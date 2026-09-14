import AppKit
import SwiftUI

/// AppKit reuses passage views; playback changes update only affected visible items.
struct TranscriptCollectionView: NSViewRepresentable {
    let segments: [TranscriptSegment]
    let activeID: UUID?
    let highlightedIDs: Set<UUID>
    let bookmarkedIDs: Set<UUID>
    let scrollTarget: UUID?
    let followPlayback: Bool
    let onManualScroll: () -> Void
    let onSelect: (TranscriptSegment) -> Void
    let onToggleBookmark: ((TranscriptSegment) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let collection = NSCollectionView()
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        let layout = PassageLayout()
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        collection.collectionViewLayout = layout
        collection.register(PassageItem.self, forItemWithIdentifier: PassageItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        scroll.documentView = collection
        context.coordinator.collection = collection
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main,
        ) { [weak coordinator = context.coordinator] _ in
            Task { @MainActor in coordinator?.parent.onManualScroll() }
        }
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        if !coordinator.hasLoaded {
            coordinator.hasLoaded = true
            collection.reloadData()
        } else if previous.segments != segments {
            // Committed chunks append passages; insert only the new rows so the
            // reader's scroll position and existing item views are preserved.
            let appended = segments.count > previous.segments.count
                && zip(previous.segments, segments).allSatisfy { $0.id == $1.id }
            if appended {
                let paths = Set((previous.segments.count ..< segments.count).map { IndexPath(item: $0, section: 0) })
                collection.animator().insertItems(at: paths)
            } else {
                collection.reloadData()
            }
        } else if previous.activeID != activeID || previous.highlightedIDs != highlightedIDs
            || previous.bookmarkedIDs != bookmarkedIDs
        {
            for item in collection.visibleItems() {
                guard let passage = item as? PassageItem, let index = collection.indexPath(for: item)?.item,
                      segments.indices.contains(index) else { continue }
                coordinator.configure(passage, at: index)
            }
        }
        let requested = previous.scrollTarget != scrollTarget ? scrollTarget : nil
        let following = followPlayback && (previous.activeID != activeID || !previous.followPlayback) ? activeID : nil
        if let target = requested ?? following, let index = segments.firstIndex(where: { $0.id == target }) {
            collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.scrollObserver = nil
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: TranscriptCollectionView
        weak var collection: NSCollectionView?
        var scrollObserver: NSObjectProtocol?
        var hasLoaded = false
        init(_ parent: TranscriptCollectionView) {
            self.parent = parent
        }

        func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
            parent.segments.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PassageItem.identifier, for: indexPath) as! PassageItem
            configure(item, at: indexPath.item)
            return item
        }

        fileprivate func configure(_ item: PassageItem, at index: Int) {
            let segment = parent.segments[index]
            item.configure(segment: segment, active: segment.id == parent.activeID,
                           matched: parent.highlightedIDs.contains(segment.id),
                           bookmarked: parent.bookmarkedIDs.contains(segment.id),
                           onPin: parent.onToggleBookmark.map { toggle in
                               { toggle(segment) }
                           })
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            if let index = indexPaths.first?.item {
                parent.onSelect(parent.segments[index])
            }
            collectionView.deselectAll(nil)
        }

        func collectionView(_ collectionView: NSCollectionView, layout _: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize
        {
            let width = max(200, (collectionView.enclosingScrollView?.contentSize.width ?? 600) - 40)
            let textWidth = max(120, width - 32)
            let text = parent.segments[indexPath.item].text as NSString
            let rect = text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: NSFont.systemFont(ofSize: 16)])
            return NSSize(width: width, height: ceil(rect.height) + 58)
        }
    }
}

@MainActor private final class PassageLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

@MainActor private final class PassageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("Passage")
    private let timestamp = NSTextField(labelWithString: "")
    private let pin = NSButton()
    private let passage = NSTextField(wrappingLabelWithString: "")
    private var onPin: (() -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        timestamp.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timestamp.textColor = .secondaryLabelColor
        pin.bezelStyle = .inline
        pin.isBordered = false
        pin.imagePosition = .imageOnly
        pin.imageScaling = .scaleProportionallyDown
        pin.target = self
        pin.action = #selector(pinClicked)
        pin.setButtonType(.momentaryPushIn)
        pin.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pin.widthAnchor.constraint(equalToConstant: 18),
            pin.heightAnchor.constraint(equalToConstant: 18),
        ])
        passage.font = .systemFont(ofSize: 16)
        passage.isSelectable = true
        passage.maximumNumberOfLines = 0
        let header = NSStackView(views: [timestamp, pin])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let stack = NSStackView(views: [header, passage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            passage.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func configure(segment: TranscriptSegment, active: Bool, matched: Bool, bookmarked: Bool, onPin: (() -> Void)?) {
        timestamp.stringValue = playbackTime(segment.start)
        passage.stringValue = segment.text
        self.onPin = onPin
        pin.isHidden = onPin == nil
        pin.image = NSImage(systemSymbolName: bookmarked ? "pin.fill" : "pin",
                            accessibilityDescription: bookmarked ? "Remove bookmark" : "Bookmark this passage")
        pin.contentTintColor = bookmarked ? .controlAccentColor : .tertiaryLabelColor
        pin.toolTip = bookmarked ? "Remove pin" : "Pin this passage"
        view.layer?.backgroundColor = (active ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : matched ? NSColor.systemYellow.withAlphaComponent(0.12) : NSColor.clear).cgColor
        view.setAccessibilityLabel("\(timestamp.stringValue). \(segment.text)")
    }

    @objc private func pinClicked() {
        onPin?()
    }
}
