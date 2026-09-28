import Foundation
import OpenClawProtocol

/// Result of matching a transcript against voice-wake trigger phrases.
public enum TalkWakeWordMatch: Equatable, Sendable {
    /// The transcript starts with a trigger (optionally after fillers) and carries a command.
    case command(String, trigger: String)
    /// The transcript is only the trigger (plus fillers); hosts should open listening mode.
    case triggerOnly(trigger: String)
}

/// Text-only voice-wake trigger matching (upstream macOS `VoiceWakeTextUtils`).
///
/// Matching is case, diacritic, and width insensitive; ASCII triggers require word boundaries.
/// Leading fillers (`hey`, `um`, `呃`, ...) before the trigger are allowed.
public enum TalkWakeWordMatcher {
    private static let whitespaceAndPunctuation = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    private static let wakePrefixFillers: Set<String> = [
        "a", "ah", "eh", "er", "erm", "hey", "hmm", "huh", "mhm", "mm", "oh", "uh", "um",
        "yo", "呃", "嗯", "啊", "诶", "欸",
    ]

    /// Matches a transcript against trigger phrases.
    /// - Parameters:
    ///   - transcript: Recognized speech.
    ///   - triggers: Trigger phrases (for example `["openclaw", "hey claw"]`).
    ///   - minCommandLength: Minimum command length; shorter remainders count as trigger-only.
    /// - Returns: A command, a trigger-only match, or `nil` when no trigger leads the transcript.
    public static func match(
        transcript: String,
        triggers: [String],
        minCommandLength: Int = 1) -> TalkWakeWordMatch?
    {
        guard !transcript.isEmpty, !self.normalizeToken(transcript).isEmpty else { return nil }
        guard self.matchesTextOnly(text: transcript, triggers: triggers) else { return nil }
        guard self.startsWithTrigger(transcript: transcript, triggers: triggers)
            || self.hasOnlyFillerBeforeTrigger(transcript: transcript, triggers: triggers)
        else { return nil }
        let trigger = self.matchedTriggerWord(transcript: transcript, triggers: triggers) ?? ""
        let remainder = self.commandAfterTrigger(transcript, triggers: triggers)
        if remainder.isEmpty || self.isFillerOnly(remainder) || remainder.count < max(1, minCommandLength) {
            return .triggerOnly(trigger: trigger)
        }
        return .command(remainder, trigger: trigger)
    }

    /// The text after the first trigger occurrence, trimmed.
    /// - Parameters:
    ///   - text: Transcript.
    ///   - triggers: Trigger phrases.
    public static func commandAfterTrigger(_ text: String, triggers: [String]) -> String {
        guard let match = self.bestRawTriggerMatch(transcript: text, triggers: triggers) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[match.range.upperBound...])
            .trimmingCharacters(in: self.whitespaceAndPunctuation)
    }

    /// The normalized trigger phrase found earliest (longest at the same offset) in the transcript.
    public static func matchedTriggerWord(transcript: String, triggers: [String]) -> String? {
        if let rawMatch = self.bestRawTriggerMatch(transcript: transcript, triggers: triggers) {
            return rawMatch.normalizedTrigger
        }
        let transcriptTokens = self.tokens(transcript)
        guard !transcriptTokens.isEmpty else { return nil }

        var bestStartIndex = Int.max
        var bestTokenCount = -1
        var bestTokens: [String]?
        for trigger in triggers {
            let triggerTokens = self.normalizedTriggerTokens(trigger)
            guard !triggerTokens.isEmpty, transcriptTokens.count >= triggerTokens.count else { continue }
            for index in 0...(transcriptTokens.count - triggerTokens.count) {
                let candidate = transcriptTokens[index..<(index + triggerTokens.count)]
                guard zip(triggerTokens, candidate).allSatisfy({ $0 == $1 }) else { continue }
                if index < bestStartIndex || (index == bestStartIndex && triggerTokens.count > bestTokenCount) {
                    bestStartIndex = index
                    bestTokenCount = triggerTokens.count
                    bestTokens = triggerTokens
                }
            }
        }
        return bestTokens?.joined(separator: " ")
    }

    static func normalizeToken(_ token: String) -> String {
        token.trimmingCharacters(in: self.whitespaceAndPunctuation).lowercased()
    }

    static func matchesTextOnly(text: String, triggers: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        for trigger in triggers {
            let token = trigger.trimmingCharacters(in: self.whitespaceAndPunctuation)
            guard !token.isEmpty else { continue }
            if text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    static func startsWithTrigger(transcript: String, triggers: [String]) -> Bool {
        let tokens = self.tokens(transcript)
        guard !tokens.isEmpty else { return false }
        for trigger in triggers {
            let triggerTokens = self.normalizedTriggerTokens(trigger)
            guard !triggerTokens.isEmpty, tokens.count >= triggerTokens.count else { continue }
            if zip(triggerTokens, tokens.prefix(triggerTokens.count)).allSatisfy({ $0 == $1 }) {
                return true
            }
        }
        return false
    }

    static func hasOnlyFillerBeforeTrigger(transcript: String, triggers: [String]) -> Bool {
        guard let match = self.bestRawTriggerMatch(transcript: transcript, triggers: triggers) else { return false }
        return self.fillerTokens(String(transcript[..<match.range.lowerBound]))
            .allSatisfy { self.wakePrefixFillers.contains($0) }
    }

    private static func isFillerOnly(_ text: String) -> Bool {
        let tokens = self.fillerTokens(text)
        return !tokens.isEmpty && tokens.allSatisfy { self.wakePrefixFillers.contains($0) }
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { self.normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func fillerTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy { self.whitespaceAndPunctuation.contains($0) }
        })
        .map { self.normalizeToken(String($0)) }
        .filter { !$0.isEmpty }
    }

    private static func normalizedTriggerTokens(_ trigger: String) -> [String] {
        self.tokens(trigger)
    }

    private static func isASCIIWordScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    private static func hasASCIIWordBoundaries(
        transcript: String,
        range: Range<String.Index>,
        trigger: String) -> Bool
    {
        guard trigger.unicodeScalars.contains(where: self.isASCIIWordScalar) else { return true }
        if range.lowerBound > transcript.startIndex {
            let before = transcript[transcript.index(before: range.lowerBound)]
            if before.unicodeScalars.contains(where: self.isASCIIWordScalar) { return false }
        }
        if range.upperBound < transcript.endIndex {
            if transcript[range.upperBound].unicodeScalars.contains(where: self.isASCIIWordScalar) { return false }
        }
        return true
    }

    private static func bestRawTriggerMatch(
        transcript: String,
        triggers: [String]) -> (range: Range<String.Index>, normalizedTrigger: String)?
    {
        var bestMatch: (range: Range<String.Index>, normalizedTrigger: String, tokenCount: Int)?
        for trigger in triggers {
            let normalizedTokens = self.normalizedTriggerTokens(trigger)
            let rawTrigger = trigger.trimmingCharacters(in: self.whitespaceAndPunctuation)
            guard !normalizedTokens.isEmpty, !rawTrigger.isEmpty else { continue }
            var searchStart = transcript.startIndex
            while searchStart < transcript.endIndex,
                  let range = transcript.range(
                      of: rawTrigger,
                      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      range: searchStart..<transcript.endIndex)
            {
                searchStart = transcript.index(after: range.lowerBound)
                guard self.hasASCIIWordBoundaries(transcript: transcript, range: range, trigger: rawTrigger) else {
                    continue
                }
                if let bestMatch {
                    if range.lowerBound > bestMatch.range.lowerBound { break }
                    if range.lowerBound == bestMatch.range.lowerBound, normalizedTokens.count <= bestMatch.tokenCount {
                        break
                    }
                }
                bestMatch = (range, normalizedTokens.joined(separator: " "), normalizedTokens.count)
                break
            }
        }
        return bestMatch.map { (range: $0.range, normalizedTrigger: $0.normalizedTrigger) }
    }
}

/// Where voice-wake and push-to-talk transcripts are sent (upstream macOS 2026.5.2, #51040).
///
/// Transcripts go to the caller-selected session target through `chat.send` instead of always
/// the main session.
public struct TalkVoiceWakeRoute: Equatable, Sendable {
    /// Session key used when no target is selected.
    public static let defaultSessionKey = "main"

    /// Session that receives transcripts.
    public var targetSessionKey: String

    /// Creates a route.
    /// - Parameter targetSessionKey: Selected session key; empty or `nil` uses ``defaultSessionKey``.
    public init(targetSessionKey: String? = nil) {
        let trimmed = targetSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.targetSessionKey = trimmed.isEmpty ? Self.defaultSessionKey : trimmed
    }

    /// Channel and recipient encoded in a routed session key
    /// (`[agent:<id>:]<channel>:<direct|group|channel>:<to>`), or `nil` for plain keys.
    public var sessionKeyRoute: (channel: String, to: String?)? {
        let rawParts = self.targetSessionKey.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let body: [String] = if rawParts.count >= 3, rawParts[0].caseInsensitiveCompare("agent") == .orderedSame {
            Array(rawParts.dropFirst(2))
        } else {
            rawParts
        }
        guard body.count >= 3 else { return nil }
        let kind = body[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard kind == "direct" || kind == "group" || kind == "channel" else { return nil }
        let channel = body[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else { return nil }
        let to = body.dropFirst(2).joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
        return (channel: channel, to: to.isEmpty ? nil : to)
    }

    /// Wraps a transcript with the upstream voice-recognition preamble.
    /// - Parameters:
    ///   - transcript: Recognized speech (trigger already stripped).
    ///   - deviceName: Device name shown to the agent.
    public static func prefixedTranscript(_ transcript: String, deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = trimmed.isEmpty ? "this device" : trimmed
        return """
        User talked via voice recognition on \(device) - repeat prompt first \
        + remember some words might be incorrectly transcribed.

        \(transcript)
        """
    }

    /// `chat.send` parameters for a transcript on this route.
    /// - Parameters:
    ///   - transcript: Recognized speech.
    ///   - deviceName: Device name for the preamble; `nil` sends the transcript verbatim.
    ///   - thinking: Optional thinking level.
    ///   - idempotencyKey: Idempotency key; a fresh UUID by default.
    public func chatSendParams(
        transcript: String,
        deviceName: String? = nil,
        thinking: String? = nil,
        idempotencyKey: String = UUID().uuidString) -> ChatSendParams
    {
        let message = deviceName.map { Self.prefixedTranscript(transcript, deviceName: $0) } ?? transcript
        return ChatSendParams(
            sessionkey: self.targetSessionKey,
            message: message,
            thinking: thinking,
            idempotencykey: idempotencyKey)
    }
}
