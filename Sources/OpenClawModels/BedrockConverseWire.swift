import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Amazon Bedrock Converse mapping for contract v2.
///
/// Requests are sent unsigned: `aws-sdk` auth relies on a caller-provided signing proxy or gateway,
/// as before. `converse-stream` uses AWS binary event-stream framing, so streaming falls back to one
/// final chunk.
enum BedrockConverseWire {
    static func buildPayload(request: ModelGenerationRequest, modelID: String, model: ModelDefinitionConfig?, maxTokens: Int) -> [String: Any] {
        var payload: [String: Any] = ["messages": self.buildMessages(request)]
        var system = ProviderContentText.systemPrompt(for: request)
        switch request.responseFormat {
        case .text:
            break
        case .jsonObject:
            system = [system, "Respond with a single valid JSON object and no other text."].compactMap { $0 }.joined(separator: "\n\n")
        case .jsonSchema(let name, let schema, _):
            system = [system, AnthropicMessagesWire.jsonSchemaInstruction(name: name, schema: schema)].compactMap { $0 }.joined(separator: "\n\n")
        }
        if let system {
            payload["system"] = [["text": system]]
        }
        var inference: [String: Any] = ["maxTokens": maxTokens]
        if !BedrockClaudeSamplingContract.rejectsTemperature(modelID: modelID) {
            if let temperature = request.policy.temperature {
                inference["temperature"] = temperature
            }
            if let topP = request.policy.topP {
                inference["topP"] = topP
            }
        }
        payload["inferenceConfig"] = inference
        if !request.tools.isEmpty {
            var toolConfig: [String: Any] = [
                "tools": request.tools.map { tool -> [String: Any] in
                    var spec: [String: Any] = ["name": tool.name, "inputSchema": ["json": ProviderWireJSON.foundation(tool.parameters)]]
                    if !tool.description.isEmpty {
                        spec["description"] = tool.description
                    }
                    return ["toolSpec": spec]
                },
            ]
            switch request.toolChoice {
            case .auto, .none:
                break
            case .required:
                toolConfig["toolChoice"] = ["any": [String: Any]()]
            case .named(let name):
                toolConfig["toolChoice"] = ["tool": ["name": name]]
            }
            payload["toolConfig"] = toolConfig
        }
        return payload
    }

    private static func buildMessages(_ request: ModelGenerationRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        func append(role: String, content: [[String: Any]]) {
            guard !content.isEmpty else { return }
            if var last = messages.last, (last["role"] as? String) == role, var blocks = last["content"] as? [[String: Any]] {
                blocks.append(contentsOf: content)
                last["content"] = blocks
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": content])
            }
        }
        for message in request.resolvedMessages {
            switch message {
            case .system:
                continue
            case .user(let content):
                append(role: "user", content: content.compactMap(self.contentBlock))
            case .assistant(let parts):
                var blocks: [[String: Any]] = []
                for part in parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty {
                            blocks.append(["text": text])
                        }
                    case .thinking(let text, let signature):
                        if let signature, !signature.isEmpty {
                            blocks.append(["reasoningContent": ["reasoningText": ["text": text, "signature": signature]]])
                        }
                    case .toolCall(let call):
                        blocks.append([
                            "toolUse": [
                                "toolUseId": AnthropicMessagesWire.normalizeToolCallID(call.id),
                                "name": call.name,
                                "input": ProviderWireJSON.argumentsObject(call.argumentsJSON),
                            ],
                        ])
                    }
                }
                append(role: "assistant", content: blocks)
            case .toolResult(let result):
                var content: [[String: Any]] = [["text": ProviderContentText.toolResultText(result)]]
                for part in result.content {
                    if case .image = part, let block = self.contentBlock(part) {
                        content.append(block)
                    }
                }
                append(role: "user", content: [[
                    "toolResult": [
                        "toolUseId": AnthropicMessagesWire.normalizeToolCallID(result.toolCallID),
                        "content": content,
                        "status": result.isError ? "error" : "success",
                    ],
                ]])
            }
        }
        if messages.isEmpty {
            messages = [["role": "user", "content": [["text": request.prompt.isEmpty ? AnthropicMessagesWire.emptyMessagesFallbackText : request.prompt]]]]
        }
        return messages
    }

    private static func contentBlock(_ part: ModelContentPart) -> [String: Any]? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : ["text": text]
        case .image(let attachment):
            let mime = MultimodalAttachmentUtilities.normalizedMimeType(for: attachment)
            let format = mime.replacingOccurrences(of: "image/", with: "").replacingOccurrences(of: "jpg", with: "jpeg")
            guard ["png", "jpeg", "gif", "webp"].contains(format) else {
                return ["text": ProviderContentText.flatten([part])]
            }
            return ["image": ["format": format, "source": ["bytes": attachment.data.base64EncodedString()]]]
        case .attachment:
            return ["text": ProviderContentText.flatten([part])]
        }
    }

    static func parseResponse(_ data: Data, providerID: String, modelID: String) throws -> ModelGenerationResponse {
        let root = try ProviderWireJSON.decode(data)
        var text = ""
        var reasoning = ""
        var reasoningBlocks = 0
        var signature: String?
        var toolCalls: [ModelToolCall] = []
        for block in root[wireKey: "output"]?[wireKey: "message"]?[wireKey: "content"]?.arrayValue ?? [] {
            if let value = block[wireKey: "text"]?.stringValue {
                text += value
            } else if let toolUse = block[wireKey: "toolUse"], let name = toolUse.wireString("name") {
                toolCalls.append(
                    ModelToolCall(
                        id: toolUse.wireString("toolUseId") ?? ProviderToolCallIDs.synthesize(index: toolCalls.count),
                        name: name,
                        argumentsJSON: OpenAIChatCompletionsWire.argumentsString(toolUse[wireKey: "input"])
                    )
                )
            } else if let reasoningText = block[wireKey: "reasoningContent"]?[wireKey: "reasoningText"], let value = reasoningText.wireString("text") {
                reasoning += value
                reasoningBlocks += 1
                signature = reasoningText.wireString("signature")
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = root[wireKey: "usage"].flatMap { value -> ModelUsage? in
            guard value.dictionaryValue != nil else { return nil }
            let read = value.wireInt("cacheReadInputTokens") ?? 0
            let write = value.wireInt("cacheWriteInputTokens") ?? 0
            let input = value.wireInt("inputTokens") ?? 0
            let output = value.wireInt("outputTokens") ?? 0
            return ModelUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: read,
                cacheWriteTokens: write,
                totalTokens: value.wireInt("totalTokens") ?? (input + output + read + write)
            )
        }
        let stopReason: ModelStopReason? = root.wireString("stopReason").map { raw in
            switch raw {
            case "end_turn", "stop_sequence":
                return .stop
            case "max_tokens", "model_context_window_exceeded":
                return .length
            case "tool_use":
                return .toolUse
            case "guardrail_intervened", "content_filtered":
                return .contentFilter
            default:
                return ModelStopReason(providerValue: raw)
            }
        }
        // An output limit reached by reasoning alone, or a guardrail block, is a valid empty turn
        // (returned with usage and stop reason), not a failure that would trigger fallback.
        guard !trimmed.isEmpty || !toolCalls.isEmpty || stopReason?.permitsEmptyOutput == true else {
            throw OpenClawCoreError.unavailable("\(providerID) response did not include text content")
        }
        return ModelGenerationResponse(
            text: toolCalls.isEmpty ? trimmed : text,
            providerID: providerID,
            modelID: modelID,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: stopReason,
            reasoningText: reasoning.isEmpty ? nil : reasoning,
            reasoningSignature: reasoningBlocks == 1 ? signature : nil
        )
    }
}
