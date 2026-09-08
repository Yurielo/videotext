import Foundation

struct OllamaMemoryManager {
    private let baseURL: URL
    private let session: URLSession
    private let videoTextModelPrefixes = ["embeddinggemma", "qwen2.5", "qwen3", "gemma3"]

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func unloadVideoTextModels() async -> [String] {
        guard let loaded = await loadedModelNames() else { return [] }
        let targets = loaded.filter { name in
            videoTextModelPrefixes.contains { prefix in
                name == prefix || name.hasPrefix(prefix + ":")
            }
        }
        let unloaded = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for model in targets {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    var request = URLRequest(
                        url: baseURL.appendingPathComponent("api/generate"),
                        timeoutInterval: 4
                    )
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONEncoder().encode(
                        UnloadRequest(model: model, stream: false, keepAlive: 0)
                    )
                    guard let (_, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return model
                }
            }
            var completed: [String] = []
            for await model in group {
                if let model { completed.append(model) }
            }
            return completed.sorted()
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

    func unloadTopicModels() async -> [String] {
        await unloadVideoTextModels()
    }

    private func loadedModelNames() async -> [String]? {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/ps"), timeoutInterval: 1)
        guard let (data, response) = try? await session.data(for: request),
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
