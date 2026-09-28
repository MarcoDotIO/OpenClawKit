#if canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
@testable import OpenClawKit

private func makeFloatBuffer(
    channels: [[Float]],
    sampleRate: Double = 48000,
    interleaved: Bool = false) throws -> AVAudioPCMBuffer
{
    let frameCount = channels.first?.count ?? 0
    // Formats with more than two channels need an explicit channel layout.
    let format: AVAudioFormat = if channels.count > 2 {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: interleaved,
            channelLayout: try #require(AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels.count))))
    } else {
        try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: interleaved))
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let data = try #require(buffer.floatChannelData)
    for (channelIndex, samples) in channels.enumerated() {
        for (frame, sample) in samples.enumerated() {
            if interleaved {
                data[0][(frame * channels.count) + channelIndex] = sample
            } else {
                data[channelIndex][frame] = sample
            }
        }
    }
    return buffer
}

private func int16Samples(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count - 1, by: 2).map { offset in
        Int16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) })
    }
}

@Suite("Talk audio levels and downmix")
struct TalkAudioProcessingTests {
    @Test("normalized levels map a 50 dB window onto 0...1")
    func normalizedLevelsMapFiftyDecibelWindow() {
        #expect(TalkAudioLevel.normalized(decibels: 0) == 1)
        #expect(TalkAudioLevel.normalized(decibels: -25) == 0.5)
        #expect(TalkAudioLevel.normalized(decibels: -50) == 0)
        #expect(TalkAudioLevel.normalized(decibels: -120) == 0)
        #expect(TalkAudioLevel.normalized(decibels: 6) == 1)
        #expect(TalkAudioLevel.normalized(rms: 1) == 1)
        #expect(TalkAudioLevel.normalized(rms: 0) == 0)
    }

    @Test("PCM16 RMS reads unaligned slices and ignores a trailing odd byte")
    func pcm16RMSReadsUnalignedSlices() {
        let full = Data([0xAA]) + [Int16.max, Int16.max, -Int16.max, -Int16.max].withUnsafeBufferPointer { Data(buffer: $0) } + Data([0x01])
        let unaligned = full.dropFirst()
        #expect(abs(TalkAudioLevel.pcm16RMS(unaligned) - 1) < 1e-9)
        #expect(TalkAudioLevel.pcm16RMS(Data()) == 0)
        #expect(TalkAudioLevel.pcm16RMS(Data([0x01])) == 0)
        #expect(TalkAudioLevel.pcm16RMS(Data(repeating: 0, count: 8)) == 0)
    }

    @Test("float buffer RMS averages every channel")
    func floatBufferRMSAveragesChannels() throws {
        let buffer = try makeFloatBuffer(channels: [[1, 1, 1, 1], [0, 0, 0, 0]])
        #expect(abs(TalkAudioLevel.rms(buffer: buffer) - (0.5).squareRoot()) < 1e-6)
        let interleaved = try makeFloatBuffer(channels: [[1, 1], [0, 0]], interleaved: true)
        #expect(abs(TalkAudioLevel.rms(buffer: interleaved) - (0.5).squareRoot()) < 1e-6)
    }

    @Test("mono downmix averages channels at the same sample rate")
    func monoDownmixAveragesChannels() throws {
        let stereo = try makeFloatBuffer(channels: [[1, 0.5, -1], [0, 0.5, 1]], sampleRate: 44100)
        let mono = try #require(OpenClawAudioDownmix.mono(stereo))
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 44100)
        #expect(mono.frameLength == 3)
        let samples = try #require(mono.floatChannelData?[0])
        #expect((0..<3).map { samples[$0] } == [0.5, 0.5, 0])

        let alreadyMono = try makeFloatBuffer(channels: [[0.25, 0.75]])
        #expect(OpenClawAudioDownmix.mono(alreadyMono) === alreadyMono)
    }

    @Test("speech-compatible buffers downmix only beyond stereo")
    func speechCompatibleBuffersDownmixBeyondStereo() throws {
        let stereo = try makeFloatBuffer(channels: [[1, 1], [0, 0]])
        #expect(OpenClawAudioDownmix.speechCompatibleBuffer(stereo) === stereo)

        let quad = try makeFloatBuffer(channels: [[1, 1], [1, 1], [0, 0], [0, 0]])
        let downmixed = OpenClawAudioDownmix.speechCompatibleBuffer(quad)
        #expect(downmixed.format.channelCount == 1)
        let samples = try #require(downmixed.floatChannelData?[0])
        #expect(samples[0] == 0.5)
        #expect(samples[1] == 0.5)
    }

    @Test("interleaved and integer layouts convert to mono float")
    func interleavedLayoutsConvert() throws {
        let interleaved = try makeFloatBuffer(channels: [[0.5, 0.5], [0.5, 0.5]], interleaved: true)
        let mono = try #require(OpenClawAudioDownmix.mono(interleaved))
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.commonFormat == .pcmFormatFloat32)
        #expect(!mono.format.isInterleaved)
    }

    @Test("the playback envelope publishes nil when cancelled")
    @MainActor
    func playbackEnvelopePublishesNilOnCancel() {
        var levels: [Double?] = []
        let envelope = PCMPlaybackEnvelope { levels.append($0) }
        envelope.begin(sampleRate: 24000)
        envelope.append(Data(repeating: 0, count: 960))
        envelope.cancel()
        #expect(levels.first == .some(nil))
        #expect(levels.last == .some(nil))
    }

    #if compiler(>=6.4)
    @Test("read-only buffer RMS matches the mutable-buffer path")
    func readOnlyBufferRMSMatches() throws {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else { return }
        let buffer = try makeFloatBuffer(channels: [[0.5, -0.5, 0.25, 1], [0, 0.5, -0.25, -1]])
        let readOnly = AVReadOnlyAudioPCMBuffer(copying: buffer)
        #expect(readOnly.frameLength == 4)
        #expect(abs(TalkAudioLevel.rms(buffer: readOnly) - TalkAudioLevel.rms(buffer: buffer)) < 1e-9)
    }
    #endif
}

#if os(iOS) || os(macOS) || os(visionOS)
@Suite("Realtime Talk PCM16 encoder")
struct RealtimeTalkPCM16EncoderTests {
    @Test("stereo 48 kHz input downmixes and resamples to 24 kHz little-endian PCM16")
    func stereoInputDownmixesAndResamples() throws {
        let buffer = try makeFloatBuffer(channels: [
            [1, 1, 0.5, 0.5, 0, 0, -1, -1],
            [0, 0, 0.5, 0.5, 0, 0, -1, -1],
        ])
        let encoded = RealtimeTalkPCM16Encoder.encode(buffer: buffer, inputSampleRate: 48000, targetSampleRate: 24000)
        let samples = int16Samples(encoded)
        #expect(samples.count == 4)
        #expect(samples == [
            Int16((0.5 * Float(Int16.max)).rounded()),
            Int16((0.5 * Float(Int16.max)).rounded()),
            0,
            -Int16.max,
        ])
    }

    @Test("out-of-range samples clamp and degenerate input encodes empty")
    func outOfRangeSamplesClamp() throws {
        let loud = try makeFloatBuffer(channels: [[4, -4]], sampleRate: 24000)
        #expect(int16Samples(RealtimeTalkPCM16Encoder.encode(
            buffer: loud, inputSampleRate: 24000, targetSampleRate: 24000)) == [Int16.max, -Int16.max])
        #expect(RealtimeTalkPCM16Encoder.encode(buffer: loud, inputSampleRate: 0, targetSampleRate: 24000).isEmpty)
        #expect(RealtimeTalkPCM16Encoder.encode(buffer: loud, inputSampleRate: 24000, targetSampleRate: 0).isEmpty)
    }

    #if compiler(>=6.4)
    @Test("read-only buffers encode identically to mutable buffers")
    func readOnlyBuffersEncodeIdentically() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let buffer = try makeFloatBuffer(channels: [
            (0..<480).map { Float(sin(Double($0) / 7)) },
            (0..<480).map { Float(cos(Double($0) / 11)) },
        ])
        let expected = RealtimeTalkPCM16Encoder.encode(buffer: buffer, inputSampleRate: 48000, targetSampleRate: 24000)
        let readOnly = AVReadOnlyAudioPCMBuffer(copying: buffer)
        let encoded = RealtimeTalkPCM16Encoder.encode(buffer: readOnly, inputSampleRate: 48000, targetSampleRate: 24000)
        #expect(!encoded.isEmpty)
        #expect(encoded == expected)
    }
    #endif
}
#endif
#endif
