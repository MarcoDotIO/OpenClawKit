import Foundation

// Ported from upstream OpenClaw 2026.9.6 `OpenClawChatDictationControl.swift`. A plain value type with main-actor
// closures, so ChatUI stays independent of the host's speech engine.

/// Host-provided dictation state and actions for the composer's microphone button.
///
/// `start()` runs the whole capture and returns the final transcript (or `nil`); the composer appends it to the
/// draft with smart spacing, only if the session did not change meanwhile.
public struct OpenClawChatDictationControl {
    /// Dictation lifecycle phase.
    public enum Phase: Equatable {
        /// Not capturing.
        case idle
        /// Preparing the recognizer and microphone.
        case starting
        /// Capturing speech.
        case listening
        /// Finalizing the transcript after capture ends.
        case processing

        var statusText: String {
            switch self {
            case .idle: String(localized: "Not listening")
            case .starting: String(localized: "Starting dictation…")
            case .listening: String(localized: "Listening…")
            case .processing: String(localized: "Finishing dictation…")
            }
        }
    }

    /// Current phase.
    public var phase: Phase
    /// Whether dictation can start (recognizer available and authorized).
    public var isAvailable: Bool
    /// Live partial transcript while listening.
    public var partialTranscript: String
    /// Live microphone level in 0...1 for the waveform.
    public var level: Double
    /// Runs one capture and returns the final transcript (`nil` or empty when nothing was recognized).
    public var start: @MainActor () async throws -> String?
    /// Ends capture and lets `start()` return the transcript.
    public var finish: @MainActor () -> Void
    /// Cancels capture; `start()` should throw `CancellationError` or return `nil`.
    public var cancel: @MainActor () -> Void

    /// Creates a dictation control.
    public init(
        phase: Phase,
        isAvailable: Bool,
        partialTranscript: String,
        level: Double,
        start: @escaping @MainActor () async throws -> String?,
        finish: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void)
    {
        self.phase = phase
        self.isAvailable = isAvailable
        self.partialTranscript = partialTranscript
        self.level = level
        self.start = start
        self.finish = finish
        self.cancel = cancel
    }

    /// Whether dictation is in any non-idle phase.
    public var isActive: Bool {
        self.phase != .idle
    }
}

extension OpenClawChatViewModel {
    func appendDictationTranscript(_ transcript: String, for session: SessionSnapshot) {
        guard self.isCurrentSession(session) else { return }
        if self.input.isEmpty {
            self.input = transcript
        } else {
            let separator = self.input.last?.isWhitespace == true ? "" : " "
            self.input += separator + transcript
        }
    }

    func setDictationError(_ error: Error, for session: SessionSnapshot) {
        guard self.isCurrentSession(session) else { return }
        self.errorText = error.localizedDescription
    }
}
