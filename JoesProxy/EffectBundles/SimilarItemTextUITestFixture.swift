import Foundation

enum SimilarItemTextUITestFixture {
    static func makeService(gate: LocalMockInferenceGate) -> LocalSimilarItemTextGenerator {
        guard UITestLaunchConfiguration.current?.fixture == .guidedMockAuthoring,
              ProcessInfo.processInfo.arguments.contains("--ui-text-suggestions") else {
            return LocalSimilarItemTextGenerator(gate: gate)
        }
        return LocalSimilarItemTextGenerator(gate: gate) { projection in
            if ProcessInfo.processInfo.arguments.contains("--ui-text-unavailable") {
                throw LocalSimilarItemTextGenerator.Failure.unavailable
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-text-slow") {
                try? await Task.sleep(for: .seconds(30))
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: String] else {
                throw LocalSimilarItemTextGenerator.Failure.invalidOutput
            }
            return object.mapValues { _ in "Synthetic coast walk" }
        }
    }
}
