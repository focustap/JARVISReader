import Foundation

struct JARVISBackendClient {
    static let defaultEndpoint = URL(
        string: "https://ifslruvbvudjocwqcxmg.supabase.co/functions/v1/whatsapp-gemini"
    )!

    enum BackendError: LocalizedError {
        case invalidResponse
        case server(status: Int, message: String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The JARVIS backend returned an invalid response."
            case .server(let status, let message):
                return "Backend error \(status): \(message)"
            case .emptyAnswer:
                return "OpenAI returned an empty answer."
            }
        }
    }

    private struct ResponseBody: Decodable {
        let ok: Bool?
        let answer: String?
        let error: String?
    }

    private struct ContextRequestBody: Encodable {
        let contextImage: String
        let questionImage: String

        enum CodingKeys: String, CodingKey {
            case contextImage = "context_image"
            case questionImage = "question_image"
        }
    }

    let endpoint: URL

    init(endpoint: URL = Self.defaultEndpoint) {
        self.endpoint = endpoint
    }

    func ask(imageData: Data, token: String = "") async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = imageData
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("native", forHTTPHeaderField: "X-JARVIS-Mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyToken(token, to: &request)

        return try await perform(request)
    }

    func ask(
        contextImageData: Data,
        questionImageData: Data,
        token: String = ""
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(
            ContextRequestBody(
                contextImage: contextImageData.base64EncodedString(),
                questionImage: questionImageData.base64EncodedString()
            )
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("native-context", forHTTPHeaderField: "X-JARVIS-Mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyToken(token, to: &request)

        return try await perform(request)
    }

    private func applyToken(_ token: String, to request: inout URLRequest) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue(trimmedToken, forHTTPHeaderField: "X-JARVIS-Token")
        }
    }

    private func perform(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.server(
                status: http.statusCode,
                message: decoded?.error ?? fallback.prefix(250).description
            )
        }

        guard let answer = decoded?.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else {
            throw BackendError.emptyAnswer
        }

        return answer
    }
}
