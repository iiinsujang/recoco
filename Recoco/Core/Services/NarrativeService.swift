import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import Foundation

struct GeneratedNarrative: Equatable {
    let narrative: String
    let keywords: [String]
}

protocol NarrativeGenerating {
    func generate(
        meaning: String,
        capturedAt: String?,
        cityName: String?,
        locale: String,
        clues: [String]
    ) async throws -> GeneratedNarrative
}

enum NarrativeServiceError: Error {
    case firebaseNotConfigured
    case unauthenticated
    case invalidResponse
}

struct FirebaseNarrativeService: NarrativeGenerating {
    private let region = "asia-northeast3"

    func generate(
        meaning: String,
        capturedAt: String?,
        cityName: String?,
        locale: String,
        clues: [String]
    ) async throws -> GeneratedNarrative {
        guard FirebaseApp.app() != nil else {
            throw NarrativeServiceError.firebaseNotConfigured
        }
        guard Auth.auth().currentUser != nil else {
            throw NarrativeServiceError.unauthenticated
        }

        var payload: [String: Any] = [
            "meaning": meaning,
            "locale": locale,
            "clues": clues
        ]
        if let capturedAt, !capturedAt.isEmpty {
            payload["capturedAt"] = capturedAt
        }
        if let cityName, !cityName.isEmpty {
            payload["cityName"] = cityName
        }

        let result = try await Functions.functions(region: region)
            .httpsCallable("generateNarrative")
            .call(payload)

        guard
            let response = result.data as? [String: Any],
            let rawNarrative = response["narrative"] as? String
        else {
            throw NarrativeServiceError.invalidResponse
        }

        let narrative = rawNarrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narrative.isEmpty else {
            throw NarrativeServiceError.invalidResponse
        }

        return GeneratedNarrative(
            narrative: narrative,
            keywords: response["keywords"] as? [String] ?? []
        )
    }
}
