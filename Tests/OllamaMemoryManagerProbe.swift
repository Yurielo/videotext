import Foundation

enum OllamaMemoryProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

final class OllamaMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var loaded = Set(["embeddinggemma:latest", "translategemma:4b", "gemma3:4b", "unrelated:latest"])
    private static var unloadBodies: [[String: Any]] = []
    private static var paths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let data: Data
        Self.lock.lock()
        Self.paths.append(path)
        if path == "/api/ps" {
            data = try! JSONSerialization.data(withJSONObject: [
                "models": Self.loaded.sorted().map { ["name": $0] }
            ])
        } else if path == "/api/generate",
                  let body = bodyData(from: request),
                  let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let model = payload["model"] as? String {
            Self.unloadBodies.append(payload)
            Self.loaded.remove(model)
            data = Data("{}".utf8)
        } else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: OllamaMemoryProbeError.failed("неожиданный путь \(path)"))
            return
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    static func result() -> (loaded: Set<String>, bodies: [[String: Any]], paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (loaded, unloadBodies, paths)
    }
}

@main
struct OllamaMemoryManagerProbe {
    static func main() async {
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OllamaMockURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let manager = OllamaMemoryManager(
                baseURL: URL(string: "http://videotext.test")!,
                session: session
            )
            let unloaded = await manager.unloadVideoTextModels()
            let result = OllamaMockURLProtocol.result()
            let expected = Set(["embeddinggemma:latest", "translategemma:4b", "gemma3:4b"])
            guard Set(unloaded) == expected else {
                throw OllamaMemoryProbeError.failed("выгружен неверный набор моделей: \(unloaded); запросы: \(result.paths)")
            }
            guard result.loaded == ["unrelated:latest"] else {
                throw OllamaMemoryProbeError.failed("затронута посторонняя модель: \(result.loaded)")
            }
            guard result.bodies.count == expected.count,
                  result.bodies.allSatisfy({ ($0["keep_alive"] as? Int) == 0 }) else {
                throw OllamaMemoryProbeError.failed("Ollama не получила keep_alive=0 для каждой модели")
            }
            print("OLLAMA_MEMORY_MANAGER_PROBE_PASS")
        } catch {
            fputs("OLLAMA_MEMORY_MANAGER_PROBE_FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
