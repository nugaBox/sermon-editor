import Foundation

/// AI 호출 추상화 (SPEC §3.2)
public protocol AIProvider: Sendable {
    var displayName: String { get }
    var model: String { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> AICompletion
}

public struct AICompletion: Sendable {
    public var text: String
    public var promptTokens: Int
    public var completionTokens: Int
}

public enum AIProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, deepseek, openAICompatible = "openai-compatible"
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .openAICompatible: return "OpenAI 호환"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-5"
        case .deepseek: return "deepseek-v4-pro"
        case .openAICompatible: return ""
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .deepseek: return "https://api.deepseek.com"
        case .openAICompatible: return "http://localhost:11434/v1"
        }
    }

    /// Keychain account (SPEC §3.1)
    public var keychainAccount: String { rawValue }
}

public struct AIConfig: Codable, Equatable, Sendable {
    public var kind: AIProviderKind
    public var model: String
    public var baseURL: String

    public init(kind: AIProviderKind, model: String? = nil, baseURL: String? = nil) {
        self.kind = kind
        self.model = (model?.isEmpty == false ? model : nil) ?? kind.defaultModel
        self.baseURL = (baseURL?.isEmpty == false ? baseURL : nil) ?? kind.defaultBaseURL
    }

    public static let `default` = AIConfig(kind: .deepseek)

    /// 키: 환경변수 SERMONCUT_API_KEY(개발용) → Keychain
    public func resolveAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["SERMONCUT_API_KEY"], !env.isEmpty { return env }
        return KeychainStore.read(account: kind.keychainAccount)
    }

    public func makeProvider() throws -> AIProvider {
        let key = resolveAPIKey()
        switch kind {
        case .claude:
            guard let key else { throw AIError.missingAPIKey(kind.displayName) }
            return ClaudeProvider(apiKey: key, model: model, baseURL: baseURL)
        case .deepseek:
            guard let key else { throw AIError.missingAPIKey(kind.displayName) }
            return OpenAICompatibleProvider(name: "DeepSeek", apiKey: key, model: model, baseURL: baseURL, jsonMode: true)
        case .openAICompatible:
            // 로컬 서버(Ollama 등)는 키가 없어도 된다
            return OpenAICompatibleProvider(name: "OpenAI 호환", apiKey: key, model: model, baseURL: baseURL, jsonMode: true)
        }
    }
}

public enum AIError: LocalizedError, Equatable {
    case missingAPIKey(String)
    case http(status: Int, message: String)
    case emptyResponse
    case invalidJSON(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): return "\(p) API 키가 없습니다. 설정(⌘,)에서 키를 입력해 주세요."
        case .http(let s, let m):
            switch s {
            case 401, 403: return "API 키가 올바르지 않습니다 (HTTP \(s))."
            case 402: return "API 잔액이 부족합니다 (HTTP 402)."
            case 429: return "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요 (HTTP 429)."
            default: return "AI 서버 오류 (HTTP \(s)): \(m.prefix(200))"
            }
        case .emptyResponse: return "AI 응답이 비어 있습니다."
        case .invalidJSON(let t): return "AI 응답을 JSON으로 읽지 못했습니다: \(t.prefix(120))"
        case .network(let m): return "네트워크 오류: \(m)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .http(let s, _): return s == 429 || s >= 500
        case .emptyResponse, .invalidJSON, .network: return true
        case .missingAPIKey: return false
        }
    }
}

// MARK: - 구현

/// OpenAI 호환 chat/completions (DeepSeek, Ollama, vLLM …)
public struct OpenAICompatibleProvider: AIProvider {
    public let displayName: String
    let apiKey: String?
    public let model: String
    let baseURL: String
    let jsonMode: Bool

    public init(name: String, apiKey: String?, model: String, baseURL: String, jsonMode: Bool) {
        self.displayName = name
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.jsonMode = jsonMode
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> AICompletion {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw AIError.network("잘못된 주소: \(baseURL)")
        }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_tokens": maxTokens,
            "temperature": 0,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTP.send(req)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw AIError.emptyResponse
        }
        let usage = json["usage"] as? [String: Any]
        return AICompletion(text: content, promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
                            completionTokens: usage?["completion_tokens"] as? Int ?? 0)
    }
}

/// Anthropic Messages API
public struct ClaudeProvider: AIProvider {
    public let displayName = "Claude"
    let apiKey: String
    public let model: String
    let baseURL: String

    public init(apiKey: String, model: String, baseURL: String) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> AICompletion {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages") else {
            throw AIError.network("잘못된 주소: \(baseURL)")
        }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTP.send(req)
        let text = (json["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() ?? ""
        guard !text.isEmpty else { throw AIError.emptyResponse }
        let usage = json["usage"] as? [String: Any]
        return AICompletion(text: text, promptTokens: usage?["input_tokens"] as? Int ?? 0,
                            completionTokens: usage?["output_tokens"] as? Int ?? 0)
    }
}

enum HTTP {
    static func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw SermonCutError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw SermonCutError.cancelled
        } catch {
            throw AIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidJSON(String(decoding: data, as: UTF8.self))
        }
        return json
    }
}

/// 모델 응답에서 JSON 객체만 떼어낸다 (코드펜스·앞뒤 설명 허용)
public enum JSONExtractor {
    public static func object(_ text: String) throws -> [String: Any] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
            t = String(t[start...end])
        }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidJSON(text)
        }
        return obj
    }
}
