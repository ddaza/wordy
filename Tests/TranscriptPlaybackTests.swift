#if !SWIFT_PACKAGE
    import AppKit
    import AVFoundation
    import SwiftUI
    import Testing

    /// These tests exercise the actual AppKit presentation, beyond the core
    /// interval lookup tests. No lecture or installed speech model is needed.
    @Suite(.serialized) @MainActor
    struct TranscriptPlaybackTests {
        private func presentation(_ segments: [TranscriptSegment], active: UUID?, follow: Bool = false) -> TranscriptCollectionView {
            TranscriptCollectionView(segments: segments, activeID: active, highlightedIDs: [], bookmarkedIDs: [],
                                     scrollTarget: nil, followPlayback: follow, onManualScroll: {}, onSelect: { _ in },
                                     onToggleBookmark: nil)
        }

        @Test func `a committed chunk and playback transition refresh existing visible highlights together`() throws {
            _ = NSApplication.shared
            let first = TranscriptSegment(start: 0, end: 5, text: "First passage")
            let second = TranscriptSegment(start: 5, end: 10, text: "Second passage")
            let appended = TranscriptSegment(start: 10, end: 15, text: "Newly committed passage")
            let initial = presentation([first, second], active: first.id)
            let coordinator = initial.makeCoordinator()
            let scroll = initial.makeScrollView(coordinator: coordinator)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            defer {
                TranscriptCollectionView.dismantleNSView(scroll, coordinator: coordinator)
                window.contentView = nil
            }
            initial.update(coordinator: coordinator)
            scroll.layoutSubtreeIfNeeded()
            let collection = try #require(coordinator.collection)
            collection.layoutSubtreeIfNeeded()
            let firstItem = try #require(collection.item(at: IndexPath(item: 0, section: 0)))
            let secondItem = try #require(collection.item(at: IndexPath(item: 1, section: 0)))
            let activeColor = try #require(firstItem.view.layer?.backgroundColor)
            #expect(secondItem.view.layer?.backgroundColor != activeColor)

            // A media tick and an incremental transcript commit can be coalesced
            // into one SwiftUI update. Both visible rows must be refreshed.
            presentation([first, second, appended], active: second.id).update(coordinator: coordinator)
            collection.layoutSubtreeIfNeeded()
            #expect(secondItem.view.layer?.backgroundColor == activeColor)
            #expect(firstItem.view.layer?.backgroundColor != activeColor)
        }

        @Test func `replacement transcript can follow immediately and reveal the same bookmark twice`() throws {
            _ = NSApplication.shared
            let old: [TranscriptSegment] = (0 ..< 80).map { (index: Int) in
                let start = Double(index) * 10
                return TranscriptSegment(start: start, end: start + 10, text: "Old passage \(index)")
            }
            let replacement: [TranscriptSegment] = (0 ..< 80).map { (index: Int) in
                let start = Double(index) * 10
                return TranscriptSegment(start: start, end: start + 10, text: "Replacement passage \(index)")
            }
            let initial = presentation(old, active: old[0].id)
            let coordinator = initial.makeCoordinator()
            let scroll = initial.makeScrollView(coordinator: coordinator)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            defer {
                TranscriptCollectionView.dismantleNSView(scroll, coordinator: coordinator)
                window.contentView = nil
            }
            initial.update(coordinator: coordinator)
            let collection = try #require(coordinator.collection)

            // Re-transcription keeps the audio but replaces all segment IDs.
            let replaced = presentation(replacement, active: replacement[40].id, follow: true)
            replaced.update(coordinator: coordinator)
            collection.layoutSubtreeIfNeeded()
            #expect(collection.indexPathsForVisibleItems().contains(IndexPath(item: 40, section: 0)))
            let activeItem = try #require(collection.item(at: IndexPath(item: 40, section: 0)))
            #expect(activeItem.view.layer?.backgroundColor?.alpha == 0.14)

            /// Manual scrolling disables following; reopening an identical pin
            /// is still a new reveal event, even if no playback time changed.
            func revealBookmark() -> TranscriptCollectionView {
                TranscriptCollectionView(segments: replacement, activeID: replacement[40].id,
                                         highlightedIDs: [], bookmarkedIDs: [],
                                         scrollTarget: TranscriptScrollRequest(segmentID: replacement[40].id),
                                         followPlayback: false, onManualScroll: {}, onSelect: { _ in }, onToggleBookmark: nil)
            }
            revealBookmark().update(coordinator: coordinator)
            collection.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
            collection.layoutSubtreeIfNeeded()
            #expect(!collection.indexPathsForVisibleItems().contains(IndexPath(item: 40, section: 0)))
            revealBookmark().update(coordinator: coordinator)
            collection.layoutSubtreeIfNeeded()
            #expect(collection.indexPathsForVisibleItems().contains(IndexPath(item: 40, section: 0)))

            // Follow must also work when an empty transcript was replaced by a
            // freshly created AppKit view with the active ID already set.
            TranscriptCollectionView.dismantleNSView(scroll, coordinator: coordinator)
            let recreated = replaced.makeScrollView(coordinator: coordinator)
            window.contentView = recreated
            replaced.update(coordinator: coordinator)
            let newCollection = try #require(coordinator.collection)
            newCollection.layoutSubtreeIfNeeded()
            #expect(newCollection.indexPathsForVisibleItems().contains(IndexPath(item: 40, section: 0)))
        }

        @Test func `resizing the transcript keeps every passage in a single full width column`() throws {
            _ = NSApplication.shared
            let segments: [TranscriptSegment] = (0 ..< 30).map { (index: Int) in
                let start = Double(index) * 10
                return TranscriptSegment(start: start, end: start + 10,
                                         text: String(repeating: "A passage that wraps across several lines. ", count: 10))
            }
            let initial = presentation(segments, active: nil)
            let coordinator = initial.makeCoordinator()
            let scroll = initial.makeScrollView(coordinator: coordinator)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = scroll
            defer {
                TranscriptCollectionView.dismantleNSView(scroll, coordinator: coordinator)
                window.contentView = nil
            }
            initial.update(coordinator: coordinator)
            let collection = try #require(coordinator.collection)
            let layout = try #require(collection.collectionViewLayout)
            for width in [600.0, 1800.0, 900.0, 2200.0, 500.0] {
                window.setContentSize(NSSize(width: width, height: 600))
                scroll.layoutSubtreeIfNeeded()
                collection.layoutSubtreeIfNeeded()
                var previous: NSRect?
                for index in segments.indices {
                    let frame = try #require(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
                    #expect(abs(frame.width - (scroll.contentSize.width - 40)) < 1)
                    #expect(abs(frame.minX - 20) < 1)
                    if let previous {
                        #expect(frame.minY >= previous.maxY)
                    }
                    previous = frame
                }
            }

            let firstPath = IndexPath(item: 0, section: 0)
            let smallHeight = try #require(layout.layoutAttributesForItem(at: firstPath)).frame.height
            collection.scrollToItems(at: [IndexPath(item: 10, section: 0)], scrollPosition: .top)
            collection.layoutSubtreeIfNeeded()
            let readingAnchor = try #require(collection.indexPathsForVisibleItems().min())
            var larger = initial
            larger.fontSize = 28
            larger.update(coordinator: coordinator)
            collection.layoutSubtreeIfNeeded()
            #expect(try #require(layout.layoutAttributesForItem(at: firstPath)).frame.height > smallHeight)
            #expect(collection.indexPathsForVisibleItems().contains(readingAnchor))

            func textFields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
            }
            let visible = try #require(collection.visibleItems().first)
            let passage = try #require(textFields(in: visible.view).first(where: { $0.stringValue == segments[0].text }))
            #expect(passage.font?.pointSize == 28)
            // Measurement must use the same font and width as the rendered text.
            let measured = (passage.stringValue as NSString).boundingRect(
                with: NSSize(width: visible.view.frame.width - 32, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 28)],
            )
            #expect(visible.view.frame.height >= ceil(measured.height) + 58)
            initial.update(coordinator: coordinator)
            collection.layoutSubtreeIfNeeded()
            #expect(try #require(layout.layoutAttributesForItem(at: firstPath)).frame.height == smallHeight)
        }

        @Test func `bookmark seek after retranscription tracks new passages silence and resumed playback`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("silence.wav")
            try writeSilence(to: url)
            let old = try TranscriptTimeline(segments: [
                .init(start: 0, end: 1, text: "Old wording"), .init(start: 1, end: 4, text: "Old next passage"),
            ])
            let new = try TranscriptTimeline(segments: [
                .init(start: 0.2, end: 0.8, text: "New wording"),
                .init(start: 1.0, end: 2.0, text: "New next passage"),
                .init(start: 2.5, end: 4.0, text: "New final passage"),
            ])
            let playback = PlaybackController()
            playback.volume = 0
            defer { playback.shutdown() }
            playback.load(url: url, duration: 4, timeline: old)
            try playback.updateTimeline(TranscriptTimeline(segments: []))
            playback.updateTimeline(new)

            // The bookmark still stores an audio time, not an old segment ID.
            playback.seek(to: 0.4)
            try await eventually { playback.activeSegmentID == new.segments[0].id && abs(playback.time - 0.4) < 0.1 }
            #expect(!playback.isPlaying)
            playback.togglePlayback()
            try await eventually { playback.time > 1.1 && playback.activeSegmentID == new.segments[1].id }
            #expect(playback.isPlaying)

            // A silence gap clears the cue but must not prevent the next cue.
            playback.seek(to: 2.2)
            try await eventually { playback.time >= 2.2 && playback.time < 2.5 && playback.activeSegmentID == nil }
            try await eventually { playback.time > 2.6 && playback.activeSegmentID == new.segments[2].id }
            #expect(playback.isPlaying)

            // A superseded seek cannot restore an earlier passage afterward.
            playback.togglePlayback()
            playback.seek(to: 0.4)
            playback.seek(to: 1.3)
            try await eventually { abs(playback.time - 1.3) < 0.1 && playback.activeSegmentID == new.segments[1].id }
        }

        private func eventually(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(condition())
        }

        private func writeSilence(to url: URL) throws {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            samples.update(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }
#endif
