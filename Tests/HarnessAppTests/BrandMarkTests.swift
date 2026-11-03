@testable import HarnessApp
import AppKit
import Testing

struct BrandMarkTests {
    /// A point on the 18-point grid, top-left origin, that the mark must cover or leave clear.
    struct Probe: Sendable, CustomTestStringConvertible {
        let x: Double
        let y: Double
        let inked: Bool
        let part: String

        var testDescription: String { part }
    }

    /// The mark drawn at 2x into RGBA pixels, first row at the top.
    static let pixels: [UInt8] = {
        let size = Int(BrandMark.side) * 2
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: 2, y: -2)
            BrandMark.draw(in: context)
        }
        return pixels
    }()

    @Test func menuBarImageIsAnAccessibleTemplate() {
        let image = BrandMark.menuBarImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "harnessmd")
    }

    @Test(arguments: [
        Probe(x: 9, y: 9.25, inked: true, part: "strap across the page"),
        Probe(x: 2.25, y: 9.25, inked: true, part: "strap past the page edge"),
        Probe(x: 9, y: 4.75, inked: true, part: "heading line"),
        Probe(x: 8, y: 13.75, inked: true, part: "text line below the strap"),
        Probe(x: 3.75, y: 4, inked: true, part: "page outline above the strap"),
        Probe(x: 14.25, y: 13, inked: true, part: "page outline below the strap"),
        Probe(x: 3.75, y: 7.1, inked: false, part: "gap where the strap wraps the page"),
        Probe(x: 9, y: 6.4, inked: false, part: "page between heading and strap"),
        Probe(x: 17, y: 1, inked: false, part: "outside the mark")
    ])
    func drawsPageAndStrap(probe: Probe) {
        let size = Int(BrandMark.side) * 2
        let alpha = Self.pixels[(Int(probe.y * 2) * size + Int(probe.x * 2)) * 4 + 3]
        #expect((alpha > 128) == probe.inked, "alpha \(alpha)")
    }
}
