import AppKit

/// The menu bar mark: an instruction page held by a strap, the app icon reduced to a template glyph.
enum BrandMark {
    /// Points on a side; the menu bar centers it in its 22-point height.
    static let side: CGFloat = 18

    /// Drawn in code so it stays vector at every scale and needs no resource bundle.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "harnessmd"
        return image
    }

    /// Geometry on an 18-point grid with the origin at the top left.
    static func draw(in context: CGContext) {
        context.setFillColor(.black)
        context.setStrokeColor(.black)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        let page = CGPath(roundedRect: CGRect(x: 3.75, y: 1.75, width: 10.5, height: 14.5), cornerWidth: 2, cornerHeight: 2, transform: nil)
        // The page outline stops short of the strap, so the strap reads as wrapping around it.
        for visible in [CGRect(x: 0, y: 0, width: side, height: 6.75), CGRect(x: 0, y: 11.75, width: side, height: side - 11.75)] {
            context.saveGState()
            context.clip(to: visible)
            context.addPath(page)
            context.strokePath()
            context.restoreGState()
        }
        context.addPath(CGPath(roundedRect: CGRect(x: 1.5, y: 7.5, width: 15, height: 3.5), cornerWidth: 1.75, cornerHeight: 1.75, transform: nil))
        context.fillPath()
        // A heading above the strap and a shorter line of text below it.
        context.move(to: CGPoint(x: 6.5, y: 4.75)); context.addLine(to: CGPoint(x: 11.5, y: 4.75))
        context.move(to: CGPoint(x: 6.5, y: 13.75)); context.addLine(to: CGPoint(x: 10, y: 13.75))
        context.strokePath()
    }
}
