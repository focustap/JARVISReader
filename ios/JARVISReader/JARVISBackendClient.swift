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
                return "Gemini returned an empty answer."
            }
        }
    }

    private struct ResponseBody: Decodable {
        let ok: Bool?
        let answer: String?
        let error: String?
    }

    let endpoint: URL

    init(endpoint: URL = Self.defaultEndpoint) {
        self.endpoint = endpoint
    }

    // Experimental test build route: captured images are handed to the iOS
    // Shortcut named "JARVIS AI", which returns ChatGPT's textual answer via
    // x-callback-url. The existing Gemini implementation remains below as a
    // fallback we can re-enable without touching the stable native-ios branch.
    func ask(imageData: Data, token: String = "") async throws -> String {
        try await JARVISShortcutClient.shared.ask(imageData: imageData)
    }

    func askGemini(imageData: Data, token: String = "") async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = imageData
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("native", forHTTPHeaderField: "X-JARVIS-Mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue(trimmedToken, forHTTPHeaderField: "X-JARVIS-Token")
        }

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
