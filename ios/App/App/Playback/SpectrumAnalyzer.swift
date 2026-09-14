import Accelerate
import AVFoundation
import Combine
import Foundation

protocol SpectrumTapInstalling: AnyObject {
    func installSpectrumTap(bufferSize: AVAudioFrameCount, handler: @escaping AVAudioNodeTapBlock) throws
    func removeSpectrumTap()
}

extension AudioEngineGraph: SpectrumTapInstalling {}

struct SpectrumLevels: Equatable {
    let low: Float
    let mid: Float
    let high: Float

    static let zero = SpectrumLevels(low: 0, mid: 0, high: 0)
}

enum SpectrumAnalyzerError: Error {
    case fftUnavailable
}

final class SpectrumAnalyzer: ObservableObject {
    static let fftSize = 1_024
    static let bandCount = 12
    static let maximumPublishRate = 30.0

    @Published private(set) var bands = [Float](repeating: 0, count: bandCount)

    private let source: SpectrumTapInstalling
    private let processor: SpectrumProcessor
    private let renderLock = NSLock()
    private let workQueue = DispatchQueue(label: "app.aeon.audio.spectrum", qos: .userInteractive)
    private var renderSamples = [Float](repeating: 0, count: fftSize)
    private var analysisSamples = [Float](repeating: 0, count: fftSize)
    private var capturedSampleRate = 48_000.0
    private var hasCapturedFrame = false
    private var playbackActive = false
    private var reduceMotion = false
    private var mode: SpectrumMode = .ambient
    private var timer: DispatchSourceTimer?
    private var playbackObservers = Set<AnyCancellable>()

    init(source: SpectrumTapInstalling) throws {
        self.source = source
        processor = try SpectrumProcessor(size: Self.fftSize, bandCount: Self.bandCount)
    }

    deinit { stop() }

    func start() throws {
        renderLock.lock()
        let alreadyRunning = timer != nil
        renderLock.unlock()
        guard !alreadyRunning else { return }

        try source.installSpectrumTap(bufferSize: AVAudioFrameCount(Self.fftSize)) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now(),
            repeating: 1.0 / Self.maximumPublishRate,
            leeway: .milliseconds(4)
        )
        timer.setEventHandler { [weak self] in self?.publishNextFrame() }
        renderLock.lock()
        self.timer = timer
        renderLock.unlock()
        timer.resume()
    }

    func stop() {
        renderLock.lock()
        let timer = self.timer
        self.timer = nil
        hasCapturedFrame = false
        renderLock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        source.removeSpectrumTap()
        publishClear()
    }

    @MainActor
    func bind(to playback: PlaybackController) {
        playbackObservers.removeAll()
        playback.$snapshot
            .map { $0?.intent == .playing }
            .removeDuplicates()
            .sink { [weak self] active in self?.setPlaybackActive(active) }
            .store(in: &playbackObservers)
        playback.$spectrumMode
            .removeDuplicates()
            .sink { [weak self] mode in self?.setMode(mode) }
            .store(in: &playbackObservers)
    }

    func setPlaybackActive(_ active: Bool) {
        renderLock.lock()
        playbackActive = active
        renderLock.unlock()
        if !active { publishClear() }
    }

    func setReduceMotion(_ reduced: Bool) {
        renderLock.lock()
        reduceMotion = reduced
        renderLock.unlock()
        if reduced { publishClear() }
    }

    func setMode(_ mode: SpectrumMode) {
        renderLock.lock()
        self.mode = mode
        renderLock.unlock()
        if mode == .off { publishClear() }
    }

    func levels(from values: [Float]? = nil) -> SpectrumLevels {
        let values = values ?? bands
        guard values.count >= 3 else { return .zero }
        let third = max(1, values.count / 3)
        return SpectrumLevels(
            low: values.prefix(third).max() ?? 0,
            mid: values.dropFirst(third).prefix(third).max() ?? 0,
            high: values.suffix(from: min(values.count, third * 2)).max() ?? 0
        )
    }

    func analyzeForTesting(samples: [Float], sampleRate: Double) -> [Float] {
        analysisSamples.withUnsafeMutableBufferPointer { destination in
            destination.initialize(repeating: 0)
            let count = min(destination.count, samples.count)
            samples.suffix(count).withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress, let destinationAddress = destination.baseAddress else { return }
                destinationAddress.advanced(by: destination.count - count).update(from: sourceAddress, count: count)
            }
        }
        return processor.process(samples: &analysisSamples, sampleRate: sampleRate, strength: 1)
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = min(Int(buffer.frameLength), Self.fftSize)
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard frameCount > 0 else { return }

        renderLock.lock()
        renderSamples.withUnsafeMutableBufferPointer { destination in
            guard let address = destination.baseAddress else { return }
            vDSP_vclr(address, 1, vDSP_Length(destination.count))
            let offset = destination.count - frameCount
            for frame in 0..<frameCount {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channels[channel][frame] }
                address[offset + frame] = mono / Float(channelCount)
            }
        }
        let sampleRate = buffer.format.sampleRate
        if sampleRate.isFinite, sampleRate > 0 { capturedSampleRate = sampleRate }
        hasCapturedFrame = true
        renderLock.unlock()
    }

    private func publishNextFrame() {
        renderLock.lock()
        let reactive = playbackActive && !reduceMotion && mode != .off
        let ready = hasCapturedFrame
        let sampleRate = capturedSampleRate
        let strength: Float = mode == .full ? 1 : 0.58
        if reactive, ready {
            analysisSamples.withUnsafeMutableBufferPointer { destination in
                renderSamples.withUnsafeBufferPointer { source in
                    guard let destinationAddress = destination.baseAddress, let sourceAddress = source.baseAddress else { return }
                    destinationAddress.update(from: sourceAddress, count: destination.count)
                }
            }
            hasCapturedFrame = false
        }
        renderLock.unlock()
        guard reactive, ready else { return }

        let values = processor.process(samples: &analysisSamples, sampleRate: sampleRate, strength: strength)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isReactive else { return }
            self.bands = values
        }
    }

    private var isReactive: Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        return playbackActive && !reduceMotion && mode != .off
    }

    private func publishClear() {
        let cleared = [Float](repeating: 0, count: Self.bandCount)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bands != cleared else { return }
            self.bands = cleared
        }
    }
}

private final class SpectrumProcessor {
    private static let frequencyEdges: [Double] = [
        30, 55, 90, 150, 250, 400, 650, 1_000, 1_600, 2_500, 4_000, 6_500, 11_000
    ]

    private let size: Int
    private let bandCount: Int
    private let log2Size: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]
    private var runningPeak: Float = 0.000_001

    init(size: Int, bandCount: Int) throws {
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(size))), FFTRadix(kFFTRadix2)) else {
            throw SpectrumAnalyzerError.fftUnavailable
        }
        self.size = size
        self.bandCount = bandCount
        log2Size = vDSP_Length(log2(Double(size)))
        fftSetup = setup
        window = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        smoothed = [Float](repeating: 0, count: bandCount)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func process(samples: inout [Float], sampleRate: Double, strength: Float) -> [Float] {
        guard samples.count == size, sampleRate.isFinite, sampleRate > 0 else {
            return [Float](repeating: 0, count: bandCount)
        }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                magnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                    guard let realAddress = realBuffer.baseAddress,
                          let imaginaryAddress = imaginaryBuffer.baseAddress,
                          let magnitudeAddress = magnitudeBuffer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realAddress, imagp: imaginaryAddress)
                    windowed.withUnsafeBufferPointer { input in
                        guard let address = input.baseAddress else { return }
                        address.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, magnitudeAddress, 1, vDSP_Length(size / 2))
                }
            }
        }

        var raw = [Float](repeating: 0, count: bandCount)
        let nyquistBin = magnitudes.count - 1
        for band in 0..<bandCount {
            let lower = Self.frequencyEdges[min(band, Self.frequencyEdges.count - 2)]
            let upper = Self.frequencyEdges[min(band + 1, Self.frequencyEdges.count - 1)]
            let start = min(nyquistBin, max(1, Int((lower * Double(size) / sampleRate).rounded(.down))))
            let end = min(nyquistBin, max(start, Int((upper * Double(size) / sampleRate).rounded(.up))))
            var total: Float = 0
            vDSP_sve(Array(magnitudes[start...end]), 1, &total, vDSP_Length(end - start + 1))
            raw[band] = sqrt(max(0, total / Float(end - start + 1)))
        }
        let framePeak = raw.max() ?? 0
        runningPeak = max(framePeak, runningPeak * 0.985)
        for index in raw.indices {
            let normalized = min(1, max(0, raw[index] / runningPeak)) * strength
            let response: Float = normalized > smoothed[index] ? 0.67 : 0.08
            smoothed[index] += (normalized - smoothed[index]) * response
        }
        return smoothed
    }
}
