import Foundation

struct OllamaMemoryManager {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let topicModelPrefixes = ["embeddinggemma", "qwen2.5", "gemma3"]

    func unloadTopicModels() async -> [String] {
        guard let loaded = await loadedModelNames() else { return [] }
        let targets = loaded.filter { name in
            topicModelPrefixes.contains { prefix in
                name == prefix || name.hasPrefix(prefix + ":")
            }
        }
        var unloaded: [String] = []
        for model in targets {
            guard !Task.isCancelled else { break }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(UnloadRequest(model: model, stream: false, keepAlive: 0))
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            unloaded.append(model)
        }
        if !unloaded.isEmpty {
            for _ in 0..<20 {
                guard !Task.isCancelled else { break }
                let remaining = await loadedModelNames() ?? []
                if Set(remaining).isDisjoint(with: unloaded) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return unloaded
    }

    private func loadedModelNames() async -> [String]? {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/ps"), timeoutInterval: 4)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(ProcessResponse.self, from: data) else { return nil }
        return payload.models.map(\.name)
    }

    private struct ProcessResponse: Decodable {
        var models: [LoadedModel]
    }

    private struct LoadedModel: Decodable {
        var name: String
    }

    private struct UnloadRequest: Encodable {
        var model: String
        var stream: Bool
        var keepAlive: Int

        enum CodingKeys: String, CodingKey {
            case model, stream
            case keepAlive = "keep_alive"
        }
    }
}
