import AVFoundation
import Foundation

struct ImportedAudio: Sendable {
    let url: URL
    let title: String
    let duration: TimeInterval
}

actor AudioImporter {
    enum ImportError: LocalizedError {
        case unsupported
        var errorDescription: String? {
            "This file does not contain supported, playable audio."
        }
    }

    func inspect(_ url: URL) async throws -> ImportedAudio {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else { throw ImportError.unsupported }
        return ImportedAudio(url: url, title: url.deletingPathExtension().lastPathComponent, duration: duration)
    }
}
