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
        let ext = url.pathExtension.lowercased()
        if (ext == "ogg" || ext == "opus"), !Self.isValidOggContainer(url: url) {
            return .decodeFailed(reason: "invalid_ogg_container")
        }

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
            if ext == "ogg" || ext == "opus" {
                return .unsupported(reason: "decoder_unavailable_\(ext)")
            }
            return .decodeFailed(reason: "decoder_open_failed")
        }
    }

    private static func isValidOggContainer(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 28 else { return false }
        var offset = 0
        var packets: [Data] = []
        var currentPacket = Data()
        var packetContinues = false
        var firstPage = true
        var serial: UInt32?
        var expectedSequence: UInt32 = 0
        var sawEOS = false
        while offset < data.count {
            guard !sawEOS else { return false }
            guard data.count - offset >= 27,
                  data[offset ..< offset + 4].elementsEqual(Data("OggS".utf8)),
                  data[offset + 4] == 0 else { return false }
            let headerType = data[offset + 5]
            let pageSerial = littleEndianUInt32(data, at: offset + 14)
            let sequence = littleEndianUInt32(data, at: offset + 18)
            guard sequence == expectedSequence else { return false }
            expectedSequence &+= 1
            if firstPage {
                guard headerType & 0x02 != 0, headerType & 0x01 == 0, sequence == 0 else { return false }
                serial = pageSerial
                firstPage = false
            } else {
                guard headerType & 0x02 == 0, pageSerial == serial else { return false }
            }
            guard (headerType & 0x01 != 0) == packetContinues else { return false }
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
                currentPacket.append(data[payloadOffset ..< payloadOffset + length])
                payloadOffset += length
                if length < 255 {
                    packets.append(currentPacket)
                    currentPacket.removeAll(keepingCapacity: true)
                    packetContinues = false
                } else {
                    packetContinues = true
                }
            }
            if headerType & 0x04 != 0 { sawEOS = true }
            offset = next
        }
        guard sawEOS, !packetContinues, currentPacket.isEmpty else { return false }
        if packets.first.map(validOpusIdentification) == true {
            return packets.count >= 3 && validOpusTags(packets[1]) && packets.dropFirst(2).contains(where: { !$0.isEmpty })
        }
        if packets.first.map(validVorbisIdentification) == true {
            return packets.count >= 4 && validVorbisComment(packets[1]) && validVorbisSetup(packets[2]) &&
                packets.dropFirst(3).contains(where: { !$0.isEmpty })
        }
        return false
    }

    private static func validOpusIdentification(_ packet: Data) -> Bool {
        guard packet.count >= 19,
              packet.prefix(8).elementsEqual(Data("OpusHead".utf8)),
              packet[8] <= 15,
              packet[9] > 0 else { return false }
        let channels = Int(packet[9])
        let mappingFamily = packet[18]
        if mappingFamily == 0 { return packet.count == 19 && channels <= 2 }
        guard mappingFamily == 1 || mappingFamily == 2 || mappingFamily == 3 || mappingFamily == 255,
              mappingFamily != 1 || channels <= 8,
              packet.count == 21 + channels else { return false }
        let streams = Int(packet[19])
        let coupled = Int(packet[20])
        let mappingsAreValid = packet[21 ..< 21 + channels].allSatisfy {
            Int($0) < streams + coupled
        }
        return streams > 0 && coupled <= streams && mappingsAreValid
    }

    private static func validOpusTags(_ packet: Data) -> Bool {
        guard packet.count >= 16, packet.prefix(8).elementsEqual(Data("OpusTags".utf8)) else { return false }
        let vendorLength = Int(littleEndianUInt32(packet, at: 8))
        guard vendorLength <= packet.count - 16 else { return false }
        var offset = 12 + vendorLength
        let commentCount = Int(littleEndianUInt32(packet, at: offset))
        offset += 4
        for _ in 0 ..< commentCount {
            guard packet.count - offset >= 4 else { return false }
            let length = Int(littleEndianUInt32(packet, at: offset))
            offset += 4
            guard length <= packet.count - offset else { return false }
            offset += length
        }
        return offset == packet.count
    }

    private static func validVorbisComment(_ packet: Data) -> Bool {
        packet.count >= 8 && packet.prefix(7).elementsEqual(Data([3]) + Data("vorbis".utf8)) && packet.last == 1
    }

    private static func validVorbisSetup(_ packet: Data) -> Bool {
        packet.count >= 8 && packet.prefix(7).elementsEqual(Data([5]) + Data("vorbis".utf8)) && packet.last.map { $0 & 1 == 1 } == true
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func validVorbisIdentification(_ packet: Data) -> Bool {
        guard packet.count == 30,
              packet.prefix(7).elementsEqual(Data([1]) + Data("vorbis".utf8)),
              packet[7 ..< 11].allSatisfy({ $0 == 0 }),
              packet[11] > 0 else { return false }
        let sampleRate = UInt32(packet[12]) | UInt32(packet[13]) << 8 |
            UInt32(packet[14]) << 16 | UInt32(packet[15]) << 24
        let blockSizes = packet[28]
        let small = blockSizes & 0x0f
        let large = blockSizes >> 4
        return sampleRate > 0 && small >= 6 && large >= small && large <= 13 && packet[29] == 1
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
