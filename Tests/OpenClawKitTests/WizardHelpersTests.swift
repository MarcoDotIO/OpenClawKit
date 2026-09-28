import Foundation
import OpenClawProtocol
import Testing

@Suite("Wizard helpers")
struct WizardHelpersTests {
    @Test
    func parsesDeviceCodesWithinAllowedExpiryRange() {
        let presentation = parseWizardDeviceCode([
            "code": AnyCodable("ABCD-EFGH"),
            "expiresInMinutes": AnyCodable(15),
            "message": AnyCodable("Enter the code on github.com/login/device"),
        ])
        #expect(presentation?.code == "ABCD-EFGH")
        #expect(presentation?.expiresInMinutes == 15)
        #expect(presentation?.message == "Enter the code on github.com/login/device")

        #expect(parseWizardDeviceCode(["code": AnyCodable("X"), "expiresInMinutes": AnyCodable(10.0)])?.expiresInMinutes == 10)
        #expect(parseWizardDeviceCode(["code": AnyCodable("X"), "expiresInMinutes": AnyCodable(2.5)])?.expiresInMinutes == nil)
        #expect(parseWizardDeviceCode(["code": AnyCodable("X"), "expiresInMinutes": AnyCodable(0)])?.expiresInMinutes == nil)
        #expect(parseWizardDeviceCode(["code": AnyCodable("X"), "expiresInMinutes": AnyCodable(1441)])?.expiresInMinutes == nil)
        #expect(parseWizardDeviceCode(["code": AnyCodable("")]) == nil)
        #expect(parseWizardDeviceCode(["code": AnyCodable(12)]) == nil)
        #expect(parseWizardDeviceCode(nil) == nil)
    }

    @Test
    func parsesOptionsAndStepMetadata() throws {
        let options = parseWizardOptions([
            ["value": AnyCodable("openai"), "label": AnyCodable("OpenAI"), "hint": AnyCodable("API key")],
            ["value": AnyCodable(2)],
        ])
        #expect(options.count == 2)
        #expect(options[0].value == AnyCodable("openai"))
        #expect(options[0].label == "OpenAI")
        #expect(options[0].hint == "API key")
        #expect(options[1].label == "")
        #expect(options[1].hint == nil)
        #expect(parseWizardOptions(nil).isEmpty)

        let step = try JSONDecoder().decode(
            WizardStep.self,
            from: Data(#"{"id":"s1","type":"progress","executor":"gateway","title":"Installing"}"#.utf8)
        )
        #expect(wizardStepType(step) == "progress")
        #expect(wizardStepExecutor(step) == "gateway")
        #expect(wizardStatusString(AnyCodable("  Running ")) == "running")
        #expect(wizardStatusString(AnyCodable(1)) == nil)
    }

    @Test
    func scalarHelpersMatchUpstreamSemantics() {
        #expect(anyCodableString(AnyCodable("a")) == "a")
        #expect(anyCodableString(AnyCodable(3)) == "3")
        #expect(anyCodableString(AnyCodable(1.5)) == "1.5")
        #expect(anyCodableString(AnyCodable(true)) == "true")
        #expect(anyCodableString(AnyCodable.nullValue) == "")
        #expect(anyCodableString(nil) == "")

        #expect(anyCodableBool(AnyCodable(true)))
        #expect(anyCodableBool(AnyCodable(1)))
        #expect(anyCodableBool(AnyCodable(0.0)) == false)
        #expect(anyCodableBool(AnyCodable(" YES ")))
        #expect(anyCodableBool(AnyCodable("1")))
        #expect(anyCodableBool(AnyCodable("no")) == false)
        #expect(anyCodableBool(nil) == false)

        #expect(anyCodableArray(AnyCodable([AnyCodable(1), AnyCodable("x")])).count == 2)
        #expect(anyCodableArray(AnyCodable("x")).isEmpty)

        #expect(anyCodableEqual(AnyCodable("2"), AnyCodable(2)))
        #expect(anyCodableEqual(AnyCodable(2), AnyCodable("2")))
        #expect(anyCodableEqual(AnyCodable("1.5"), AnyCodable(1.5)))
        #expect(anyCodableEqual(AnyCodable(true), AnyCodable(true)))
        #expect(anyCodableEqual(AnyCodable(true), AnyCodable(1)) == false)
        #expect(anyCodableEqual(nil, nil) == false)
    }
}
