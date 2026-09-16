import Foundation
import UIKit

@MainActor
final class JARVISShortcutClient {
    static let shared = JARVISShortcutClient()

    enum ShortcutError: LocalizedError {
        case alreadyRunning
        case invalidImage
        case couldNotBuildURL
        case couldNotOpenShortcuts
        case cancelled
        case failed(String)
        case emptyResult
        case timedOut

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "A JARVIS AI Shortcut request is already running."
            case .invalidImage:
                return "JARVIS could not prepare the captured image for Shortcuts."
            case .couldNotBuildURL:
                return "JARVIS could not build the Shortcuts launch URL."
            case .couldNotOpenShortcuts:
                return "JARVIS could not open the Shortcuts app. Make sure Shortcuts is installed."
            case .cancelled:
                return "The JARVIS AI Shortcut was cancelled."
            case .failed(let message):
                return "Shortcut error: \(message)"
            case .emptyResult:
                return "The JARVIS AI Shortcut finished without returning an answer."
            case .timedOut:
                return "The JARVIS AI Shortcut did not return an answer in time."
            }
        }
    }

    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var previousClipboardItems: [[String: Any]] = []

    private init() {}

    func canHandle(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "jarvisreader-test" &&
        ["shortcut-success", "shortcut-error", "shortcut-cancel"].contains(url.host?.lowercased() ?? "")
    }

    func ask(imageData: Data) async throws -> String {
        guard continuation == nil else {
            throw ShortcutError.alreadyRunning
        }
        guard let image = UIImage(data: imageData) else {
            throw ShortcutError.invalidImage
        }

        previousClipboardItems = UIPasteboard.general.items
        UIPasteboard.general.image = image

        guard let url = makeRunURL() else {
            restoreClipboard()
            throw ShortcutError.couldNotBuildURL
        }

        return try await withCheckedThrowingContinuation { pending in
            continuation = pending

            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ShortcutError.timedOut))
            }

            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                guard !opened else { return }
                Task { @MainActor in
                    self?.finish(.failure(ShortcutError.couldNotOpenShortcuts))
                }
            }
        }
    }

    func handleCallback(_ url: URL) {
        guard canHandle(url), let host = url.host?.lowercased() else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        switch host {
        case "shortcut-success":
            let result = components?.queryItems?
                .first(where: { $0.name == "result" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if result.isEmpty {
                finish(.failure(ShortcutError.emptyResult))
            } else {
                finish(.success(result))
            }

        case "shortcut-error":
            let message = components?.queryItems?
                .first(where: { $0.name == "errorMessage" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Shortcuts error"
            finish(.failure(ShortcutError.failed(message)))

        case "shortcut-cancel":
            finish(.failure(ShortcutError.cancelled))

        default:
            break
        }
    }

    private func makeRunURL() -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: "JARVIS AI"),
            URLQueryItem(name: "input", value: "clipboard"),
            URLQueryItem(name: "x-success", value: "jarvisreader-test://shortcut-success"),
            URLQueryItem(name: "x-error", value: "jarvisreader-test://shortcut-error"),
            URLQueryItem(name: "x-cancel", value: "jarvisreader-test://shortcut-cancel")
        ]
        return components.url
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        restoreClipboard()

        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case .success(let answer):
            continuation.resume(returning: answer)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func restoreClipboard() {
        UIPasteboard.general.items = previousClipboardItems
        previousClipboardItems = []
    }
}
