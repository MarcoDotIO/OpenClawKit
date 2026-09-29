import Foundation
import Testing
@testable import OpenClawKit

/// Keeps the deprecated A2UI helpers working until they are removed in the next breaking release.
struct CanvasLegacyDeprecationTests {
    @available(*, deprecated, message: "Exercises deprecated A2UI helpers")
    @Test func `deprecated A2UI JSONL validation still rejects v0.9 messages`() throws {
        let valid = """
        {"beginRendering":{"surfaceId":"surface-1"}}
        {"surfaceUpdate":{"surfaceId":"surface-1","html":"<p>Hello</p>"}}
        """

        let messages = try OpenClawCanvasA2UIJSONL.decodeMessagesFromJSONL(valid)
        let encoded = try OpenClawCanvasA2UIJSONL.encodeMessagesJSONArray(messages)

        #expect(messages.count == 2)
        #expect(encoded.contains("beginRendering"))
        #expect(encoded.contains("surfaceUpdate"))

        do {
            _ = try OpenClawCanvasA2UIJSONL.decodeMessagesFromJSONL(#"{"createSurface":{"id":"surface-2"}}"#)
            Issue.record("Expected A2UI v0.9 payload to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("createSurface"))
        }
    }

    @available(*, deprecated, message: "Exercises deprecated canvas resources")
    @Test func `deprecated scaffold accessor still finds the bundled page`() {
        #expect(OpenClawKitResources.canvasScaffoldURL?.lastPathComponent == "scaffold.html")
    }

    @Test func `presenter commands exclude retired canvas commands`() {
        #expect(OpenClawCanvasCommand.presenterCommands.map(\.rawValue) == [
            "canvas.present",
            "canvas.hide",
            "canvas.navigate",
        ])
    }
}
