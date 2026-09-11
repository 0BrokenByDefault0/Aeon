import XCTest
@testable import App

final class MetadataProbeTests: XCTestCase {
    private var tempURL: URL!
    private var fixturesURL: URL {
        guard let root = Bundle(for: MetadataProbeTests.self).resourceURL else {
            fatalError("AppTests resource bundle is unavailable")
        }
        return root.appendingPathComponent("audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempURL) }

    func testProbesNormalizedPCMMetadataAtRequiredRates() throws {
        for rate in [44_100, 48_000, 96_000] {
            let url = fixturesURL.appendingPathComponent("pcm-\(rate).wav")
            guard case .playable(let media) = MetadataProbe().probe(url: url) else {
                return XCTFail("Expected playable WAV at \(rate) Hz")
            }
            XCTAssertEqual(media.url, url)
            XCTAssertEqual(media.frameCount, Int64(rate / 4))
            XCTAssertEqual(media.descriptor.codec, "pcm_s16le")
            XCTAssertEqual(media.descriptor.container, "wav")
            XCTAssertEqual(media.descriptor.sampleRate, Double(rate))
            XCTAssertEqual(media.descriptor.channelCount, 2)
            XCTAssertEqual(media.descriptor.bitDepth, 16)
            XCTAssertEqual(media.descriptor.duration ?? -1, 0.25, accuracy: 0.000_001)
        }
    }

    func testMissingIsUnavailableAndCorruptKnownContainerIsDecodeFailed() throws {
        XCTAssertEqual(MetadataProbe().probe(url: tempURL.appendingPathComponent("missing.wav")), .unavailable)
        for name in ["corrupt.wav", "truncated.wav"] {
            guard case .decodeFailed(let reason) = MetadataProbe().probe(url: fixturesURL.appendingPathComponent(name)) else {
                return XCTFail("\(name) must not be guessed unsupported")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testKnownOggDecoderFailureIsUnsupported() throws {
        for name in [
            "corrupt.ogg", "corrupt-crc.ogg", "truncated-opushead.ogg",
            "continued-first-page.ogg", "non-bos-first-page.ogg",
            "trailing-opushead.ogg", "reserved-mapping-family.ogg"
        ] {
            guard case .decodeFailed = MetadataProbe().probe(url: fixturesURL.appendingPathComponent(name)) else {
                return XCTFail("\(name) must be decodeFailed")
            }
        }
        let valid = fixturesURL.appendingPathComponent("valid-opus.ogg")
        try assertCompleteOpusFixture(valid)
        switch MetadataProbe().probe(url: valid) {
        case .playable, .unsupported: break
        default: XCTFail("Structurally valid OGG must have an explicit playable or unsupported outcome")
        }
    }

    private func assertCompleteOpusFixture(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var offset = 0
        var pages: [(type: UInt8, sequence: UInt32, granule: UInt64, packet: Data)] = []
        while offset < data.count {
            XCTAssertTrue(data[offset ..< offset + 4].elementsEqual(Data("OggS".utf8)))
            let count = Int(data[offset + 26])
            XCTAssertEqual(count, 1)
            let length = Int(data[offset + 27])
            let packetStart = offset + 28
            let sequence = UInt32(data[offset + 18]) | UInt32(data[offset + 19]) << 8 |
                UInt32(data[offset + 20]) << 16 | UInt32(data[offset + 21]) << 24
            var granule: UInt64 = 0
            for index in 0 ..< 8 { granule |= UInt64(data[offset + 6 + index]) << UInt64(index * 8) }
            pages.append((data[offset + 5], sequence, granule, Data(data[packetStart ..< packetStart + length])))
            offset = packetStart + length
        }
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(pages[0].type, 2)
        XCTAssertTrue(pages[0].packet.starts(with: Data("OpusHead".utf8)))
        XCTAssertTrue(pages[1].packet.starts(with: Data("OpusTags".utf8)))
        XCTAssertEqual(pages[2].type, 4)
        XCTAssertFalse(pages[2].packet.isEmpty)
        XCTAssertGreaterThan(pages[2].granule, 0)
    }

    func testCompressedCapabilityMatrixAndGaplessFixtureShape() throws {
        for name in ["tone-48000.flac", "tone-48000.m4a", "tone-48000.mp3"] {
            guard case .playable = MetadataProbe().probe(url: fixturesURL.appendingPathComponent(name)) else {
                return XCTFail("Required compressed fixture \(name) must be playable")
            }
        }
        for name in ["gapless-a.wav", "gapless-b.wav"] {
            guard case .playable(let media) = MetadataProbe().probe(url: fixturesURL.appendingPathComponent(name)) else {
                return XCTFail("Missing gapless fixture \(name)")
            }
            XCTAssertEqual(media.descriptor.sampleRate, 48_000)
            XCTAssertEqual(media.frameCount, 2_400)
        }
    }
}
