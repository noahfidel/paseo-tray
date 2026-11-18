import Foundation

/// Largest WebSocket frame the tray accepts. URLSessionWebSocketTask defaults to 1 MiB, but the
/// daemon's agent lists can exceed that (agents carry their full system prompts); the server allows 100 MiB.
enum WebSocketLimits {
    static let maximumMessageSize = 32 * 1024 * 1024

    /// Apply the limits to a task; call before resume().
    static func configure(_ task: URLSessionWebSocketTask) {
        task.maximumMessageSize = maximumMessageSize
    }
}
