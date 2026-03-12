import Foundation
import Testing
@testable import OpenClawKit

@Suite("Provider visible text sanitizer")
struct ProviderVisibleTextSanitizerTests {
    @Test
    func returnsEmptyStringForEmptyInputs() {
        #expect(ProviderVisibleTextSanitizer.sanitizeVisibleText("") == "")
        #expect(ProviderVisibleTextSanitizer.extractJSONPayload("") == "")
    }

    @Test
    func removesPairedReasoningBlocksAndStandaloneMarkers() {
        let raw = """
        <|channel:analysis|>
        plan quietly
        <|channel:final|>
        <thinking>scratch</thinking>
        Visible answer
        """

        let sanitized = ProviderVisibleTextSanitizer.sanitizeVisibleText(raw)

        #expect(sanitized == "Visible answer")
    }

    @Test
    func removesOpenEndedHiddenThinkingBlock() {
        let raw = """
        Before
        <reasoning>
        never show this
        """

        let sanitized = ProviderVisibleTextSanitizer.sanitizeVisibleText(raw)

        #expect(sanitized == "Before")
    }

    @Test
    func extractsFirstJSONFenceAfterSanitization() {
        let raw = """
        <thinking>hidden</thinking>
        Here you go:
        ```json
        {"value":true}
        ```
        """

        let payload = ProviderVisibleTextSanitizer.extractJSONPayload(raw)

        #expect(payload == #"{"value":true}"#)
    }

    @Test
    func returnsEmptyPayloadWhenAllVisibleTextIsHidden() {
        let raw = """
        <thinking>
        hidden only
        </thinking>
        """

        let payload = ProviderVisibleTextSanitizer.extractJSONPayload(raw)

        #expect(payload == "")
    }
}
