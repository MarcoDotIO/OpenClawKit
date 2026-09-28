import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

@Suite("Provider budgets, pricing and media limits")
struct ProviderBudgetPricingTests {
    @Test
    func effectiveContextBudgetPrefersSelectedWindowThenRuntimeCap() {
        let gpt6 = ModelDefinitionConfig(id: "gpt-6-astra", contextWindow: 1_050_000, contextTokens: 272_000)
        #expect(ModelContextBudget.effectiveContextBudget(model: gpt6) == 272_000)
        let claude = ModelDefinitionConfig(id: "claude-opus-5", contextWindow: 1_000_000)
        let options = ["200k": 200_000, "1m": 1_000_000]
        #expect(ModelContextBudget.effectiveContextBudget(model: claude, contextWindowOptions: options, selectedContextWindowID: "200k") == 200_000)
        #expect(ModelContextBudget.effectiveContextBudget(model: claude, contextWindowOptions: options, contextWindowDefault: "1m") == 1_000_000)
        #expect(ModelContextBudget.effectiveContextBudget(model: ModelDefinitionConfig(id: "x")) == nil)
    }

    @Test
    func tieredPricingSelectsTierByPromptTokens() {
        let astra = ModelDefinitionConfig(
            id: "gpt-6-astra",
            cost: ModelCostConfig(
                input: 10,
                output: 50,
                cacheRead: 1,
                cacheWrite: 12.5,
                tieredPricing: [
                    ModelTieredPricing(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, range: [0, 272_001]),
                    ModelTieredPricing(input: 20, output: 75, cacheRead: 2, cacheWrite: 25, range: [272_001]),
                ]
            )
        )
        let small = ModelUsage(inputTokens: 100_000, outputTokens: 10_000, cacheReadTokens: 100_000)
        #expect(abs(ModelCostCalculator.cost(usage: small, model: astra) - (1.0 + 0.5 + 0.1)) < 0.000_001)
        let large = ModelUsage(inputTokens: 300_000, outputTokens: 1_000)
        #expect(abs(ModelCostCalculator.cost(usage: large, model: astra) - (6.0 + 0.075)) < 0.000_001)
        #expect(abs(ModelCostCalculator.cost(usage: large, model: astra, multiplier: 2) - 12.15) < 0.000_001)
        let flat = ModelDefinitionConfig(id: "m", cost: ModelCostConfig(input: 3, output: 15))
        #expect(abs(ModelCostCalculator.cost(usage: ModelUsage(inputTokens: 1_000_000, outputTokens: 1_000_000), model: flat) - 18) < 0.000_001)
    }

    @Test
    func imageTargetSideRespectsPreferredMaxAndPixelLimits() {
        let limits = ModelImageInputLimits(maxSidePx: 2_576, preferredSidePx: 2_048)
        #expect(MultimodalAttachmentUtilities.targetLongestSide(width: 4_000, height: 3_000, limits: limits) == 2_048)
        #expect(MultimodalAttachmentUtilities.targetLongestSide(width: 1_000, height: 800, limits: limits) == nil)
        let pixelCapped = ModelImageInputLimits(maxPixels: 1_000_000)
        let side = MultimodalAttachmentUtilities.targetLongestSide(width: 2_000, height: 2_000, limits: pixelCapped)
        #expect(side == 1_000)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    @Test
    func imagesAreResizedBeforeEncoding() async throws {
        let png = try Self.makePNG(width: 400, height: 200)
        let attachment = MediaAttachment(mimeType: "image/png", data: png, fileName: "wide.png")
        let resized = MultimodalAttachmentUtilities.prepareImage(attachment, limits: ModelImageInputLimits(maxSidePx: 100))
        let source = try #require(CGImageSourceCreateWithData(resized.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 100)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 50)
        #expect(resized.id == attachment.id)

        let transport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://llm.example/v1",
            apiKey: "k",
            models: [
                ModelDefinitionConfig(
                    id: "vision",
                    input: [.text, .image],
                    mediaInput: ModelMediaInputConfig(image: ModelImageInputLimits(maxSidePx: 64))
                ),
            ]
        )
        let provider = ProviderServiceOpenAIModelProvider(
            id: "custom",
            configuration: config.legacyServiceConfig(providerID: "custom"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
        )
        let request = ModelGenerationRequest(sessionKey: "s", prompt: "", messages: [.user(content: [.text("see"), .image(attachment)])])
        _ = try await provider.generate(request)
        let body = try #require(await transport.lastRequest()?.httpBody)
        #expect(body.count < png.count * 2)
        #expect(!String(decoding: body, as: UTF8.self).contains(png.base64EncodedString()))
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    #endif

    @Test
    func oauthDescriptorsCoverUpstreamProviders() {
        let openai = InteractiveAuthFlowCatalog.descriptors(forProvider: "openai-codex")
        #expect(openai.map(\.kind) == [.browserOAuth, .deviceCode])
        #expect(openai.allSatisfy { $0.providerID == "openai" })
        #expect(openai.last?.deviceAuthorizationURL?.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/usercode")
        let xai = InteractiveAuthFlowCatalog.descriptors(forProvider: "grok")
        #expect(xai.map(\.kind) == [.browserOAuth, .deviceCode])
        #expect(xai.first?.clientID == XAIOAuthConfiguration.clientID)
        #expect(InteractiveAuthFlowCatalog.descriptors(forProvider: "chutes").first?.authorizationURL == nil)
        #expect(InteractiveAuthFlowCatalog.descriptors(forProvider: "github-copilot").first?.kind == .deviceCode)
        #expect(InteractiveAuthFlowCatalog.deprecatedProviders["qwen-portal"] != nil)
    }
}
