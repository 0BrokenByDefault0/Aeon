import Foundation
@testable import App

struct PlanetTextureGenerator {
    static let width = 512
    static let height = 512
    static let byteCount = width * height * 4

    func rgbaTexture(seed: UInt64, descriptor: PlanetDescriptor) -> Data {
        precondition(descriptor.algorithm == PlanetDescriptor.algorithmVersion)
        let colors = descriptor.bandColors.isEmpty
            ? [SkyColor(red: 64, green: 72, blue: 88)]
            : descriptor.bandColors
        var bytes = Data(count: Self.byteCount)
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let output = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<Self.height {
                let dy = y * 2 - (Self.height - 1)
                for x in 0..<Self.width {
                    let dx = x * 2 - (Self.width - 1)
                    let distanceSquared = UInt64(dx * dx + dy * dy)
                    let index = (y * Self.width + x) * 4
                    guard distanceSquared <= 511 * 511 else {
                        output[index] = 0
                        output[index + 1] = 0
                        output[index + 2] = 0
                        output[index + 3] = 0
                        continue
                    }
                    let noise = SkyStableHash.mix(
                        seed ^ UInt64(x) &* 0x9e3779b1 ^ UInt64(y) &* 0x85ebca77
                    )
                    let warp = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: noise)))
                        * Int(descriptor.turbulence) / 131_072
                    let bandIndex = positiveModulo(y + warp + Int(seed & 127), colors.count)
                    let color = colors[bandIndex]
                    let radial = Int(integerSquareRoot(distanceSquared))
                    let sphereShade = max(48, 255 - radial * 164 / 511)
                    let light = max(24, min(255, sphereShade + dx * -42 / 511 + dy * -28 / 511))
                    let grain = Int((noise >> 48) & 15) - 7
                    output[index] = shade(color.red, light: light, grain: grain)
                    output[index + 1] = shade(color.green, light: light, grain: grain)
                    output[index + 2] = shade(color.blue, light: light, grain: grain)
                    output[index + 3] = 255
                }
            }
        }
        return bytes
    }

    private func shade(_ component: UInt8, light: Int, grain: Int) -> UInt8 {
        UInt8(clamping: Int(component) * light / 255 + grain)
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result < 0 ? result + modulus : result
    }

    private func integerSquareRoot(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return value }
        var low: UInt64 = 1
        var high = min(value, 1_024)
        while low <= high {
            let middle = low + (high - low) / 2
            if middle <= value / middle { low = middle + 1 } else { high = middle - 1 }
        }
        return high
    }
}
