import Foundation

/// The models each account offers the text chat: a few fast defaults per type (no-thinking models such
/// as GPT-6.1 Terra and Claude Haiku first), plus whatever the provider's own model list returns for
/// the owner's key, which start switched off. The owner switches models on and off in Accounts ›
/// the account › Text Chat; the chat's model menu offers only the ones switched on.
enum ModelCatalog {
    /// The defaults, switched on until the owner turns them off.
    static func defaults(_ provider: ModelProvider) -> Set<String> {
        switch provider {
        case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .openai: ["gpt-6.1-terra"]
        case .chatgpt: Set(listed(.chatgpt).prefix(1).map(\.id))
        case .deepseek: ["deepseek-flash"]
        case .gemini: ["gemini-3.8-flash"]
        case .openrouter: ["anthropic/claude-sonnet-5.5", "google/gemini-3.8-flash"]
        case .custom: Set(provider.models.map(\.id))
        }
    }

    /// The account's models: the built-in ones, fast first, then the listed ones.
    static func all(_ provider: ModelProvider) -> [ChatModelChoice] {
        if provider == .chatgpt { return listed(provider) }
        let builtIn = provider.models.sorted { fast($0.id) && !fast($1.id) }
        let known = Set(builtIn.map(\.id))
        return builtIn + listed(provider).filter { !known.contains($0.id) }
    }

    static func available(_ provider: ModelProvider) -> [ChatModelChoice] {
        let on = enabled(provider)
        return all(provider).filter { on.contains($0.id) }
    }

    static func enabled(_ provider: ModelProvider) -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: enabledStorageKey(provider)) { return Set(saved) }
        return defaults(provider)
    }

    static func set(_ id: String, on: Bool, for provider: ModelProvider) {
        var ids = enabled(provider)
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: enabledStorageKey(provider))
        // The chat's model is always one that is switched on.
        if ModelKeys.selectedProvider == provider, !ids.contains(ModelKeys.selectedModel), let first = available(provider).first {
            ModelKeys.selectedModel = first.id
        }
        ModelKeys.saved += 1
    }

    static func listed(_ provider: ModelProvider) -> [ChatModelChoice] {
        if provider == .chatgpt {
            guard let clientId = ChatGPTAccount.currentAccount()?.clientId,
                  let data = UserDefaults.standard.data(forKey: chatGPTListKey(clientId)) else { return [] }
            return (try? JSONDecoder().decode([ChatModelChoice].self, from: data)) ?? []
        }
        return (UserDefaults.standard.stringArray(forKey: "models.listed.\(provider.rawValue)") ?? []).map { ChatModelChoice(id: $0, name: $0) }
    }

    static func needsRefresh(_ provider: ModelProvider) -> Bool {
        if provider == .chatgpt {
            guard let clientId = ChatGPTAccount.currentAccount()?.clientId else { return false }
            return UserDefaults.standard.data(forKey: chatGPTListKey(clientId)) == nil
        }
        return listed(provider).isEmpty
    }

    private static func chatGPTListKey(_ clientId: String) -> String { "models.listed.chatgpt.\(clientId)" }

    private static func enabledStorageKey(_ provider: ModelProvider) -> String {
        if provider == .chatgpt, let clientId = ChatGPTAccount.currentAccount()?.clientId {
            return "models.enabled.chatgpt.\(clientId)"
        }
        return "models.enabled.\(provider.rawValue)"
    }

    static func supportsReasoning(_ id: String, for provider: ModelProvider) -> Bool {
        guard provider == .openrouter else { return false }
        return (UserDefaults.standard.stringArray(forKey: "models.reasoning.openrouter") ?? []).contains(id)
    }

    /// No-thinking, fast models first: Terra, Haiku, Flash.
    static func fast(_ id: String) -> Bool {
        ["terra", "haiku", "flash", "mini"].contains { id.lowercased().contains($0) }
    }

    /// Reads the provider's model list with the owner's key (sent only to that provider).
    static func refresh(_ provider: ModelProvider) async throws -> Int {
        let chatGPTClientId: String?
        var modelListRequest: URLRequest
        if provider == .chatgpt {
            guard let clientId = ChatGPTAccount.currentAccount()?.clientId,
                  let token = await ChatGPTAccount.accessToken() else { throw URLError(.userAuthenticationRequired) }
            guard ChatGPTAccount.currentAccount()?.clientId == clientId else { throw URLError(.cancelled) }
            chatGPTClientId = clientId
            modelListRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            modelListRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            guard let providerRequest = request(provider) else { return 0 }
            chatGPTClientId = nil
            modelListRequest = providerRequest
        }
        modelListRequest.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: modelListRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if let chatGPTClientId {
            let items = (json?["models"] as? [[String: Any]]) ?? []
            let choices = items.compactMap { item -> ChatModelChoice? in
                guard item["visibility"] as? String == "list",
                      let slug = item["slug"] as? String, !slug.isEmpty else { return nil }
                let name = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatModelChoice(id: slug, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? slug)
            }
            let choiceData = try JSONEncoder().encode(choices)
            UserDefaults.standard.set(choiceData, forKey: chatGPTListKey(chatGPTClientId))
            let availableIDs = Set(choices.map(\.id))
            let enabledKey = "models.enabled.chatgpt.\(chatGPTClientId)"
            if let saved = UserDefaults.standard.stringArray(forKey: enabledKey) {
                let valid = saved.filter(availableIDs.contains)
                if !saved.isEmpty, valid.isEmpty, let first = choices.first?.id {
                    UserDefaults.standard.set([first], forKey: enabledKey)
                } else {
                    UserDefaults.standard.set(valid, forKey: enabledKey)
                }
            } else if let first = choices.first?.id {
                UserDefaults.standard.set([first], forKey: enabledKey)
            }
            ModelKeys.saved += 1
            return choices.count
        }

        let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        var ids = items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { usable($0, provider) }
        if provider == .openai {
            let voice = items.compactMap { $0["id"] as? String }.filter { $0.contains("realtime") && !$0.contains("transcribe") }.sorted()
            UserDefaults.standard.set(voice, forKey: "models.listed.voice")
        }
        if provider == .openrouter {
            let reasoning = items.compactMap { item -> String? in
                guard let id = item["id"] as? String, usable(id, provider),
                      let parameters = item["supported_parameters"] as? [String],
                      parameters.contains("reasoning") || parameters.contains("reasoning_effort") else { return nil }
                return id
            }
            UserDefaults.standard.set(Array(Set(reasoning)).sorted(), forKey: "models.reasoning.openrouter")
        }
        ids = Array(Set(ids)).sorted { fast($0) == fast($1) ? $0 < $1 : fast($0) }
        UserDefaults.standard.set(ids, forKey: "models.listed.\(provider.rawValue)")
        ModelKeys.saved += 1
        return ids.count
    }

    /// Chat models only: no embeddings, speech, images or moderation.
    private static func usable(_ id: String, _ provider: ModelProvider) -> Bool {
        let lower = id.lowercased()
        let skip = ["embed", "audio", "realtime", "transcribe", "tts", "whisper", "image", "dall-e", "moderation", "search", "aqa", "imagen", "veo"]
        if skip.contains(where: lower.contains) { return false }
        switch provider {
        case .openai: return lower.hasPrefix("gpt-") || lower.hasPrefix("o")
        case .anthropic: return lower.hasPrefix("claude")
        case .gemini: return lower.hasPrefix("gemini")
        default: return true
        }
    }

    private static func request(_ provider: ModelProvider) -> URLRequest? {
        let key = ModelKeys.key(provider)
        var request: URLRequest
        switch provider {
        case .openai:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepseek:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            guard let key, var parts = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return nil }
            parts.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "200")]
            request = URLRequest(url: parts.url!)
        case .openrouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .custom:
            let base = ModelKeys.customURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base)?.appending(path: "models") else { return nil }
            request = URLRequest(url: url)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .chatgpt:
            // ChatGPT plan model listing uses the selected account's OAuth token in refresh(_:).
            return nil
        }
        request.timeoutInterval = 15
        return request
    }

    // MARK: Voice

    /// Live voice models (OpenAI Realtime): the built-in one and any the key's list adds, off at first.
    static let voiceDefault = "gpt-realtime-2.1"

    static var voiceAll: [ChatModelChoice] {
        let listed = (UserDefaults.standard.stringArray(forKey: "models.listed.voice") ?? []).filter { $0 != voiceDefault }
        return [ChatModelChoice(id: voiceDefault, name: "GPT Realtime 2.1")] + listed.map { ChatModelChoice(id: $0, name: $0) }
    }

    static var voiceEnabled: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "models.enabled.voice") ?? [voiceDefault])
    }

    static func setVoice(_ id: String, on: Bool) {
        var ids = voiceEnabled
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: "models.enabled.voice")
        if !ids.contains(voiceModel) { voiceModel = voiceAll.first { ids.contains($0.id) }?.id ?? voiceDefault }
        ModelKeys.saved += 1
    }

    static var voiceAvailable: [ChatModelChoice] { voiceAll.filter { voiceEnabled.contains($0.id) } }

    /// The live voice model.
    static var voiceModel: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "voice.model") ?? voiceDefault
            return voiceEnabled.contains(saved) ? saved : voiceAvailable.first?.id ?? voiceDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: "voice.model"); ModelKeys.saved += 1 }
    }
}
