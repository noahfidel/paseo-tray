import AppKit
import Foundation

/// Client for the paseo-bots tray API (see paseo-bots docs/tray-api.md).
/// The relay is optional: everything here degrades to "not installed" or
/// "unreachable" instead of failing loudly. Never log the token, and never
/// set an Origin header (the relay refuses any request that carries one).

struct TrayBotsFile {
    let port: Int
    let token: String
    let url: URL

    static var fileURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PASEOTRAY_BOTS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let raw = env["PASEO_HOME"] ?? "~/.paseo"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("plugin-data/paseo-bots/tray.json")
    }

    /// Reads the file fresh each call (port and token change on plugin restart).
    /// Returns nil when the file is absent, unparsable or not version 1.
    static func load() -> TrayBotsFile? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == 1,
              let port = object["port"] as? Int, (1...65_535).contains(port),
              let token = object["token"] as? String, !token.isEmpty,
              // Always loopback: ignore the file's `url` so the token never leaves this host.
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            return nil
        }
        return TrayBotsFile(port: port, token: token, url: url)
    }
}

struct TrayBot: Decodable {
    struct Team: Decodable {
        let id: String
        let name: String
    }

    struct Avatar: Decodable {
        let background: String
        let body: String
        let shape: String
        let svg: String?
        let imageUrl: String?
    }

    let id: String
    let name: String
    let title: String
    let team: Team?
    let avatar: Avatar
    let lastChatAgentId: String?
}

struct TrayChat: Decodable {
    let agentId: String
    let started: Bool
}

enum BotsResult {
    case notInstalled
    case unreachable
    case failed(String)
    case loaded([TrayBot])
}

enum BotsError: Error {
    case notInstalled
    case unreachable
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled: return L("paseo-bots isn't installed", "未安装 paseo-bots")
        case .unreachable: return L("paseo-bots isn't answering", "paseo-bots 没有响应")
        case .failed(let message): return message
        }
    }
}

final class BotsClient {
    /// Called on the main queue when a remote avatar image finished loading.
    var onImageLoaded: (() -> Void)?

    private let session: URLSession
    private var avatarCache: [String: NSImage] = [:]
    private var remoteImages: [String: NSImage] = [:]
    private var remoteInFlight: Set<String> = []
    private static let avatarSize = NSSize(width: 18, height: 18)

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    // MARK: - Requests

    func fetchBots(completion: @escaping (BotsResult) -> Void) {
        guard let file = TrayBotsFile.load() else {
            DispatchQueue.main.async { completion(.notInstalled) }
            return
        }
        var request = URLRequest(url: file.url.appendingPathComponent("tray/bots"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Bearer \(file.token)", forHTTPHeaderField: "Authorization")
        perform(request) { outcome in
            switch outcome {
            case .unreachable:
                completion(.unreachable)
            case .failed(let message):
                completion(.failed(message))
            case .success(let data):
                struct Payload: Decodable { let bots: [TrayBot] }
                do {
                    completion(.loaded(try JSONDecoder().decode(Payload.self, from: data).bots))
                } catch {
                    completion(.failed(L("Unexpected response from paseo-bots", "paseo-bots 返回了无法识别的数据")))
                }
            }
        }
    }

    func startChat(botId: String, completion: @escaping (Result<String, BotsError>) -> Void) {
        guard let file = TrayBotsFile.load() else {
            DispatchQueue.main.async { completion(.failure(.notInstalled)) }
            return
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = botId.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: file.url.absoluteString + "/tray/bots/\(encoded)/chat") else {
            DispatchQueue.main.async { completion(.failure(.failed("Invalid bot id"))) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(file.token)", forHTTPHeaderField: "Authorization")
        perform(request) { outcome in
            switch outcome {
            case .unreachable:
                completion(.failure(.unreachable))
            case .failed(let message):
                completion(.failure(.failed(message)))
            case .success(let data):
                if let chat = try? JSONDecoder().decode(TrayChat.self, from: data) {
                    completion(.success(chat.agentId))
                } else {
                    completion(.failure(.failed(L("Unexpected response from paseo-bots", "paseo-bots 返回了无法识别的数据"))))
                }
            }
        }
    }

    private enum Outcome {
        case success(Data)
        case unreachable
        case failed(String)
    }

    private func perform(_ request: URLRequest, completion: @escaping (Outcome) -> Void) {
        let task = session.dataTask(with: request) { data, response, error in
            let outcome: Outcome
            if error != nil {
                outcome = .unreachable
            } else if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    outcome = .success(data ?? Data())
                } else {
                    outcome = .failed(Self.describe(status: http.statusCode, data: data))
                }
            } else {
                outcome = .unreachable
            }
            DispatchQueue.main.async { completion(outcome) }
        }
        task.resume()
    }

    private static func describe(status: Int, data: Data?) -> String {
        var serverMessage: String?
        if let data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            serverMessage = message
        }
        switch status {
        case 401:
            return join(L("paseo-bots rejected the tray's token", "paseo-bots 拒绝了托盘的令牌"), serverMessage)
        case 409:
            return join(L("bot runs on another host", "该机器人运行在其他主机上"), serverMessage)
        case 503:
            return join(
                L("Paseo hasn't connected to paseo-bots yet — open the Bots screen once",
                  "Paseo 尚未连接 paseo-bots —— 请先打开一次机器人页面"),
                serverMessage
            )
        default:
            return "HTTP \(status): \(serverMessage ?? "unknown error")"
        }
    }

    private static func join(_ prefix: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return prefix }
        return "\(prefix) (\(detail))"
    }

    // MARK: - Avatars

    func avatarImage(for bot: TrayBot) -> NSImage {
        let avatar = bot.avatar
        var hasher = Hasher()
        hasher.combine(avatar.background)
        hasher.combine(avatar.body)
        hasher.combine(avatar.shape)
        hasher.combine(avatar.svg)
        hasher.combine(avatar.imageUrl)
        let key = "\(bot.id)#\(hasher.finalize())"

        if let cached = avatarCache[key] { return cached }

        if let urlString = avatar.imageUrl {
            if urlString.hasPrefix("data:image/") {
                if let image = Self.decodeDataURL(urlString) {
                    let result = Self.clipped(image, shape: avatar.shape)
                    avatarCache[key] = result
                    return result
                }
            } else if let remote = remoteImages[urlString] {
                let result = Self.clipped(remote, shape: avatar.shape)
                avatarCache[key] = result
                return result
            } else if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                loadRemote(urlString)
                // Placeholder until the download lands (not cached).
                return Self.drawn(avatar)
            }
        }

        if let svg = avatar.svg, let data = svg.data(using: .utf8),
           let image = NSImage(data: data), image.isValid,
           image.size.width > 0, image.size.height > 0 {
            let result = Self.clipped(image, shape: avatar.shape)
            avatarCache[key] = result
            return result
        }

        let result = Self.drawn(avatar)
        avatarCache[key] = result
        return result
    }

    private func loadRemote(_ urlString: String) {
        guard !remoteInFlight.contains(urlString), let url = URL(string: urlString) else { return }
        remoteInFlight.insert(urlString)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        session.dataTask(with: request) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteInFlight.remove(urlString)
                if let image, image.isValid {
                    self.remoteImages[urlString] = image
                    self.onImageLoaded?()
                }
            }
        }.resume()
    }

    private static func decodeDataURL(_ urlString: String) -> NSImage? {
        guard let comma = urlString.firstIndex(of: ",") else { return nil }
        let header = urlString[..<comma]
        guard header.contains(";base64") else { return nil }
        let payload = String(urlString[urlString.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    private static func shapePath(_ shape: String, in rect: NSRect) -> NSBezierPath {
        switch shape {
        case "circle": return NSBezierPath(ovalIn: rect)
        case "square": return NSBezierPath(rect: rect)
        default: return NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.25, yRadius: rect.height * 0.25)
        }
    }

    private static func clipped(_ source: NSImage, shape: String) -> NSImage {
        let size = avatarSize
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            shapePath(shape, in: rect).addClip()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return image
    }

    private static func drawn(_ avatar: TrayBot.Avatar) -> NSImage {
        let background = parseHex(avatar.background) ?? NSColor.systemGray
        let body = parseHex(avatar.body) ?? NSColor.white
        let shape = avatar.shape
        return NSImage(size: avatarSize, flipped: false) { rect in
            background.setFill()
            shapePath(shape, in: rect).fill()
            let dot = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
            body.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    private static func parseHex(_ string: String) -> NSColor? {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

// MARK: - CLI helpers (headless verification)

enum BotsCLI {
    private static func waitForMain(_ start: (@escaping () -> Void) -> Void) {
        var done = false
        start { done = true }
        while !done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func list() {
        let client = BotsClient()
        waitForMain { finish in
            client.fetchBots { result in
                switch result {
                case .notInstalled: print("not installed")
                case .unreachable: print("unreachable")
                case .failed(let message): print("error: \(message)")
                case .loaded(let bots):
                    for bot in bots {
                        let kind: String
                        if bot.avatar.imageUrl != nil {
                            kind = "image"
                        } else if bot.avatar.svg != nil {
                            kind = "svg"
                        } else {
                            kind = "none"
                        }
                        print("\(bot.id)\t\(bot.name)\t\(bot.team?.name ?? "")\t\(bot.lastChatAgentId ?? "")\tavatar=\(kind)")
                    }
                }
                finish()
            }
        }
    }

    static func chat(botId: String) -> Int32 {
        let client = BotsClient()
        var code: Int32 = 0
        waitForMain { finish in
            client.startChat(botId: botId) { result in
                switch result {
                case .success(let agentId): print("agentId=\(agentId)")
                case .failure(let error):
                    print("error: \(error.message)")
                    code = 1
                }
                finish()
            }
        }
        return code
    }
}
