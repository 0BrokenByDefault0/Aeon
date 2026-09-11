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
        for name in ["corrupt.ogg", "corrupt-crc.ogg"] {
            guard case .decodeFailed = MetadataProbe().probe(url: fixturesURL.appendingPathComponent(name)) else {
                return XCTFail("\(name) must be decodeFailed")
            }
        }
        switch MetadataProbe().probe(url: fixturesURL.appendingPathComponent("valid-opus.ogg")) {
        case .playable, .unsupported: break
        default: XCTFail("Structurally valid OGG must have an explicit playable or unsupported outcome")
        }
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
