import Foundation

func runWebSocketLimitsTests() {
    expect(WebSocketLimits.maximumMessageSize == 33_554_432, "websocket limits: constant is 32 MiB")
    let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:1/ws")!)
    WebSocketLimits.configure(task)
    expect(task.maximumMessageSize == 33_554_432, "websocket limits: configure sets task maximumMessageSize")
    task.cancel()
}
