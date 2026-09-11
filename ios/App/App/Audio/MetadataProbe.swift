import AVFoundation
import Foundation

struct ProbedMedia: Equatable {
    let url: URL
    let descriptor: SourceFormatDescriptor
    let frameCount: Int64
}

enum MediaCapability: Equatable {
    case playable(ProbedMedia)
    case unsupported(reason: String)
    case decodeFailed(reason: String)
    case unavailable
}

final class MetadataProbe {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func probe(url: URL) -> MediaCapability {
        guard fileManager.fileExists(atPath: url.path) else { return .unavailable }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            guard sampleRate > 0 else { return .decodeFailed(reason: "invalid_sample_rate") }

            let frameCount = Int64(file.length)
            let settings = file.fileFormat.settings
            let descriptor = SourceFormatDescriptor(
                codec: Self.codec(settings: settings),
                container: Self.container(for: url),
                sampleRate: sampleRate,
                channelCount: Int(format.channelCount),
                bitDepth: Self.bitDepth(settings: settings),
                duration: Double(frameCount) / sampleRate
            )
            return .playable(ProbedMedia(url: url, descriptor: descriptor, frameCount: frameCount))
        } catch {
            let ext = url.pathExtension.lowercased()
            if ext == "ogg" || ext == "opus" {
                return .unsupported(reason: "decoder_unavailable_\(ext)")
            }
            return .decodeFailed(reason: "decoder_open_failed")
        }
    }

    private static func container(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func codec(settings: [String: Any]) -> String? {
        guard let raw = (settings[AVFormatIDKey] as? NSNumber)?.uint32Value else { return nil }
        if raw == kAudioFormatLinearPCM {
            let floating = (settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue ?? false
            if floating { return "pcm_f32" }
            let depth = bitDepth(settings: settings)
            let bigEndian = (settings[AVLinearPCMIsBigEndianKey] as? NSNumber)?.boolValue ?? false
            if let depth { return "pcm_s\(depth)\(bigEndian ? "be" : "le")" }
            return "pcm"
        }
        return fourCC(raw)
    }

    private static func bitDepth(settings: [String: Any]) -> Int? {
        (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? String(format: "0x%08x", value) : text.lowercased()
    }
}
