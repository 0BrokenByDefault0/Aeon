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
                guard Self.isValidOggContainer(url: url) else {
                    return .decodeFailed(reason: "invalid_ogg_container")
                }
                return .unsupported(reason: "decoder_unavailable_\(ext)")
            }
            return .decodeFailed(reason: "decoder_open_failed")
        }
    }

    private static func isValidOggContainer(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 28 else { return false }
        var offset = 0
        var firstPacket = Data()
        var recognizedIdentification = false
        while offset < data.count {
            guard data.count - offset >= 27,
                  data[offset ..< offset + 4].elementsEqual(Data("OggS".utf8)),
                  data[offset + 4] == 0 else { return false }
            let segmentCount = Int(data[offset + 26])
            let tableStart = offset + 27
            guard data.count - tableStart >= segmentCount else { return false }
            let payloadSize = (0 ..< segmentCount).reduce(0) { $0 + Int(data[tableStart + $1]) }
            let next = tableStart + segmentCount + payloadSize
            guard next <= data.count else { return false }
            var page = Data(data[offset ..< next])
            let expectedCRC = UInt32(page[22]) | UInt32(page[23]) << 8 | UInt32(page[24]) << 16 | UInt32(page[25]) << 24
            page.replaceSubrange(22 ..< 26, with: repeatElement(UInt8(0), count: 4))
            guard oggCRC(page) == expectedCRC else { return false }
            var payloadOffset = tableStart + segmentCount
            for index in 0 ..< segmentCount {
                let length = Int(data[tableStart + index])
                if !recognizedIdentification { firstPacket.append(data[payloadOffset ..< payloadOffset + length]) }
                payloadOffset += length
                if !recognizedIdentification, length < 255 {
                    recognizedIdentification = firstPacket.starts(with: Data("OpusHead".utf8)) ||
                        firstPacket.starts(with: Data([1]) + Data("vorbis".utf8))
                    guard recognizedIdentification else { return false }
                }
            }
            offset = next
        }
        return recognizedIdentification
    }

    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1
            }
        }
        return crc
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
