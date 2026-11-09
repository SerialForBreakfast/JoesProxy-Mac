import Foundation

enum MockIconSuggestionUITestFixture {
    static func makeService(gate: LocalMockInferenceGate = LocalMockInferenceGate()) -> MockIconSuggestionService {
        guard UITestLaunchConfiguration.current?.fixture == .guidedMockAuthoring,
              ProcessInfo.processInfo.arguments.contains("--ui-icon-suggestions") else {
            return MockIconSuggestionService(gate: gate)
        }
        return MockIconSuggestionService(gate: gate) { input in
            if input == "Slow mountain" {
                // Deliberately completes after cancellation to exercise stale-result rejection.
                try? await Task.sleep(for: .seconds(30))
                return "mountain"
            }
            if input == "Unavailable" { throw MockIconSuggestionService.Failure.unavailable }
            if input == "A mountain hiking trip" { return "mountain" }
            if input == #"{"category":"books"}"# { return "book" }
            return MockIconCatalog.sealID
        }
    }
}
