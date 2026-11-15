import Foundation

/// Session changes can wait for the audio server. Keep them off main, in order, including WebRTC's
/// matching activation/deactivation calls, so a delayed stop cannot deactivate the next start.
enum AudioSessionWork {
    private static let queue = DispatchQueue(label: "poki.audio-session")

    @MainActor
    static func perform(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}
