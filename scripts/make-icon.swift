// Renders the app icon artwork into an .icns file: `make icon` after editing Support/AppIcon.svg.
// AppKit draws the SVG itself, so no design tool or rasterizer has to be installed.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: swift scripts/make-icon.swift <artwork.svg> <output.icns>\n", stderr); exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let artwork = NSImage(contentsOf: source) else {
    fputs("Could not read \(source.path) as an image\n", stderr); exit(1)
}

/// One square sRGB PNG of the artwork, tagged with its point size so @2x files carry 144 dpi.
func png(points: Int, scale: Int) throws -> Data {
    let pixels = points * scale
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: points, height: points)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

let files = FileManager.default
let iconset = files.temporaryDirectory.appendingPathComponent("harnessmd-\(UUID().uuidString).iconset")
var failed = false
do {
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try png(points: points, scale: scale).write(to: iconset.appendingPathComponent(name))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    if iconutil.terminationStatus != 0 { fputs("iconutil failed with status \(iconutil.terminationStatus)\n", stderr); failed = true }
} catch {
    fputs("Icon rendering failed: \(error.localizedDescription)\n", stderr); failed = true
}
do { try files.removeItem(at: iconset) } catch { fputs("Could not remove \(iconset.path): \(error.localizedDescription)\n", stderr) }
if failed { exit(1) }
print("Wrote \(output.path)")
