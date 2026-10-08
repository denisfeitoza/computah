import Foundation
import Testing
@testable import ComputahCore

struct OpenRouterChoiceTests {
    private func reply(_ content: [String: Any]) -> Data {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: content), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: [
            "model": "test/model", "usage": ["prompt_tokens": 42],
            "choices": [["message": ["content": text]]]])
    }

    private let questions: [String: Any] = [
        "action": ["type": "choice", "instructions": "x",
                   "criteria": ["a": "A", "b": "B", "c": "C", "d": "D", "none_here": "none"]]]

    private func answer(_ data: Data) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (object["answers"] as! [String: Any])["action"] as! [String: Any]
    }

    @Test func reshapedProbabilitiesSumToOneAndLead() throws {
        let shaped = try #require(OpenRouterChoice.jevShaped(
            reply(["action": ["choice": "b", "confidence": 0.62, "runner_up": ["c", "b", "zzz"]]]), questions: questions))
        let probabilities = answer(shaped.0)["probabilities"] as! [String: Double]
        #expect(Set(probabilities.keys) == ["a", "b", "c", "d", "none_here"])
        #expect(abs(probabilities.values.reduce(0, +) - 1) < 1e-9)
        #expect(probabilities["b"]! >= probabilities.values.max()! - 1e-9)
        #expect(probabilities["c"]! > probabilities["a"]!)
        #expect(shaped.1 == 42)
    }

    @Test func lowConfidenceStillLeads() throws {
        let shaped = try #require(OpenRouterChoice.jevShaped(
            reply(["action": ["choice": "a", "confidence": 0.01, "runner_up": []]]), questions: questions))
        let probabilities = answer(shaped.0)["probabilities"] as! [String: Double]
        #expect(probabilities["a"]! >= probabilities.values.max()! - 1e-9)
        #expect(abs(probabilities.values.reduce(0, +) - 1) < 1e-9)
    }

    @Test func unknownChoiceIsRejected() {
        #expect(OpenRouterChoice.jevShaped(
            reply(["action": ["choice": "evil", "confidence": 1, "runner_up": []]]), questions: questions) == nil)
    }

    @Test func missingQuestionIsRejected() {
        #expect(OpenRouterChoice.jevShaped(reply([:]), questions: questions) == nil)
    }

    @Test func schemaRestrictsChoiceToOfferedIDs() throws {
        let body = OpenRouterChoice.body(model: "m", state: ["k": "v"], questions: questions)
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        let action = try #require((schema["properties"] as? [String: Any])?["action"] as? [String: Any])
        let choice = try #require((action["properties"] as? [String: Any])?["choice"] as? [String: Any])
        #expect(Set(choice["enum"] as! [String]) == ["a", "b", "c", "d", "none_here"])
    }
}

struct TextModelTests {
    @Test func stripsMarkdownFence() {
        #expect(TextModel.stripFence("```json\n{\"text\": \"oi\"}\n```") == "{\"text\": \"oi\"}")
        #expect(TextModel.stripFence(" {\"text\": null} ") == "{\"text\": null}")
    }
}
