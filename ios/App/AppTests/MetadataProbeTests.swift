import XCTest
@testable import App

final class MetadataProbeTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempURL) }

    func testProbesNormalizedPCMMetadataAtRequiredRates() throws {
        for rate in [44_100, 48_000, 96_000] {
            let url = tempURL.appendingPathComponent("pcm-\(rate).wav")
            try makePCM16WAV(sampleRate: rate, channels: 2, frames: rate / 10).write(to: url)
            guard case .playable(let media) = MetadataProbe().probe(url: url) else {
                return XCTFail("Expected playable WAV at \(rate) Hz")
            }
            XCTAssertEqual(media.url, url)
            XCTAssertEqual(media.frameCount, Int64(rate / 10))
            XCTAssertEqual(media.descriptor.codec, "pcm_s16le")
            XCTAssertEqual(media.descriptor.container, "wav")
            XCTAssertEqual(media.descriptor.sampleRate, Double(rate))
            XCTAssertEqual(media.descriptor.channelCount, 2)
            XCTAssertEqual(media.descriptor.bitDepth, 16)
            XCTAssertEqual(media.descriptor.duration ?? -1, 0.1, accuracy: 0.000_001)
        }
    }

    func testMissingIsUnavailableAndCorruptKnownContainerIsDecodeFailed() throws {
        XCTAssertEqual(MetadataProbe().probe(url: tempURL.appendingPathComponent("missing.wav")), .unavailable)
        let corrupt = tempURL.appendingPathComponent("corrupt.wav")
        try Data("RIFF truncated".utf8).write(to: corrupt)
        guard case .decodeFailed(let reason) = MetadataProbe().probe(url: corrupt) else {
            return XCTFail("Corrupt WAV must not be guessed unsupported")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testKnownOggDecoderFailureIsUnsupported() throws {
        let ogg = tempURL.appendingPathComponent("unsupported.ogg")
        try Data("OggS invalid".utf8).write(to: ogg)
        guard case .unsupported(let reason) = MetadataProbe().probe(url: ogg) else {
            return XCTFail("OGG decoder-open failure must be explicit")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    private func makePCM16WAV(sampleRate: Int, channels: Int, frames: Int) -> Data {
        let bytes = frames * channels * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: Int) { data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff)) }
        func u32(_ value: Int) { for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((value >> shift) & 0xff)) } }
        text("RIFF"); u32(36 + bytes); text("WAVEfmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        text("data"); u32(bytes); data.append(Data(repeating: 0, count: bytes))
        return data
    }
}
