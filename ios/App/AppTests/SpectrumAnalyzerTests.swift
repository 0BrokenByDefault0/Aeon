import AVFoundation
import XCTest
@testable import App

final class SpectrumAnalyzerTests: XCTestCase {
    func testAnalyzerPublishesBoundedPerceptualBands() throws {
        let analyzer = try SpectrumAnalyzer(source: SpectrumTapSource())
        let sampleRate = 48_000.0
        let samples = (0..<SpectrumAnalyzer.fftSize).map { index in
            Float(sin(2 * Double.pi * 110 * Double(index) / sampleRate))
        }

        let bands = analyzer.analyzeForTesting(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(bands.count, SpectrumAnalyzer.bandCount)
        XCTAssertTrue(bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertGreaterThan(bands.prefix(4).max() ?? 0, bands.suffix(3).max() ?? 0)
    }

    func testMonoAnalysisAcceptsShortFramesWithoutGrowingItsOutput() throws {
        let analyzer = try SpectrumAnalyzer(source: SpectrumTapSource())

        let bands = analyzer.analyzeForTesting(samples: [0.4, -0.4, 0.2], sampleRate: 44_100)

        XCTAssertEqual(bands.count, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(SpectrumAnalyzer.fftSize, 1_024)
        XCTAssertEqual(SpectrumAnalyzer.maximumPublishRate, 30)
    }

    func testSpectrumLevelsMapLowMidAndHighRanges() throws {
        let analyzer = try SpectrumAnalyzer(source: SpectrumTapSource())
        let values: [Float] = [0.1, 0.8, 0.2, 0.3, 0.4, 0.7, 0.2, 0.1, 0.6, 0.9, 0.1, 0.2]

        XCTAssertEqual(analyzer.levels(from: values), SpectrumLevels(low: 0.8, mid: 0.7, high: 0.9))
    }

    func testTapInstallsOnceAndUninstallsCleanly() throws {
        let source = SpectrumTapSource()
        let analyzer = try SpectrumAnalyzer(source: source)

        try analyzer.start()
        try analyzer.start()
        analyzer.stop()

        XCTAssertEqual(source.installCount, 1)
        XCTAssertEqual(source.removeCount, 1)
        XCTAssertEqual(source.bufferSize, AVAudioFrameCount(SpectrumAnalyzer.fftSize))
    }
}

private final class SpectrumTapSource: SpectrumTapInstalling {
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var bufferSize: AVAudioFrameCount?
    private var handler: AVAudioNodeTapBlock?

    func installSpectrumTap(bufferSize: AVAudioFrameCount, handler: @escaping AVAudioNodeTapBlock) throws {
        installCount += 1
        self.bufferSize = bufferSize
        self.handler = handler
    }

    func removeSpectrumTap() {
        removeCount += 1
        handler = nil
    }
}
