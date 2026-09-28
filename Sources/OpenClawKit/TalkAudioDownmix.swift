#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// Downmixes microphone buffers to mono before Apple Speech (`SFSpeechRecognizer`,
/// `SpeechAnalyzer`) or the realtime relay sees them.
///
/// Multi-channel interfaces (aggregate devices, USB mixers) otherwise reach recognizers with
/// channel layouts they reject or transcribe poorly (upstream macOS 2026.5.2 fix, #42533).
public enum OpenClawAudioDownmix {
    /// Averages every channel into one Float32 channel at the same sample rate.
    ///
    /// Mono Float32 buffers are returned unchanged; other layouts (interleaved or integer
    /// formats) are converted with `AVAudioConverter`.
    /// - Parameter buffer: Source PCM buffer.
    /// - Returns: A mono Float32 buffer, or `nil` when the format cannot be converted.
    public static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        if format.channelCount == 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
            return buffer
        }
        return self.averageFloatChannels(buffer) ?? self.convert(buffer)
    }

    /// Returns a buffer Apple Speech accepts: buffers with more than two channels are downmixed
    /// to mono; mono and stereo buffers pass through unchanged, and so does any buffer that
    /// cannot be converted.
    /// - Parameter buffer: Source PCM buffer.
    public static func speechCompatibleBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 2 else { return buffer }
        return self.mono(buffer) ?? buffer
    }

    private static func averageFloatChannels(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let source = buffer.floatChannelData,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: 1,
                  interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, buffer.frameCapacity)),
              let target = output.floatChannelData?[0]
        else {
            return nil
        }

        output.frameLength = buffer.frameLength
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return output }

        let scale = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += source[channel][frame]
            }
            target[frame] = sum * scale
        }
        return output
    }

    private static func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false),
            let converter = AVAudioConverter(from: buffer.format, to: targetFormat),
            let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, buffer.frameLength))
        else {
            return nil
        }

        let input = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if input.didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.didProvide = true
            outStatus.pointee = .haveData
            return input.buffer
        }
        guard status != .error, error == nil else { return nil }
        return output
    }

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var didProvide = false

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }
}
#endif
