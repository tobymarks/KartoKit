#if canImport(UIKit) && canImport(Metal)
import UIKit
import Metal
import KartoCore

/// Rastert Marker, Symbole, Text und Bilder einmalig in eine Atlas-Textur (2048², @scale)
/// und liefert UV-Rechtecke. Shelf-Packing; bei Überlauf wird der Atlas geleert
/// (Marker werden dann im nächsten Frame neu gerastert – praktisch nie).
@MainActor
final class IconAtlas {
    struct Region {
        let u0: Float, v0: Float, u1: Float, v1: Float
        /// Größe in Punkten.
        let width: Double, height: Double
    }

    enum Key: Hashable {
        case annotation(MapAnnotation.Style, size: Double)
        case image(String, size: Double)
        case text(String, size: Double, weight: Int, color: UInt32, halo: UInt32)
    }

    let texture: MTLTexture
    private let scale: CGFloat
    private let size: Int
    private var regions: [Key: Region] = [:]
    private var shelfY = 0, shelfX = 0, shelfH = 0
    private let pad = 2

    init(device: MTLDevice, scale: CGFloat, size: Int = 2048) {
        self.scale = scale
        self.size = size
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        texture = device.makeTexture(descriptor: d)!
        texture.label = "KartoKit icon atlas"
    }

    func region(for key: Key) -> Region? {
        if let r = regions[key] { return r }
        guard let (image, pointSize) = render(key) else { return nil }
        guard let r = pack(image, pointSize: pointSize) else {
            // Atlas voll → leeren und erneut versuchen
            regions.removeAll(); shelfX = 0; shelfY = 0; shelfH = 0
            guard let r2 = pack(image, pointSize: pointSize) else { return nil }
            regions[key] = r2
            return r2
        }
        regions[key] = r
        return r
    }

    // MARK: - Packing

    private func pack(_ cg: CGImage, pointSize: CGSize) -> Region? {
        let w = cg.width, h = cg.height
        guard w <= size, h <= size else { return nil }
        if shelfX + w + pad > size { shelfX = 0; shelfY += shelfH + pad; shelfH = 0 }
        guard shelfY + h + pad <= size else { return nil }
        // Pixel kopieren (BGRA premultiplied)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        texture.replace(region: MTLRegionMake2D(shelfX, shelfY, w, h), mipmapLevel: 0, withBytes: &data, bytesPerRow: w * 4)
        let r = Region(u0: Float(shelfX) / Float(size), v0: Float(shelfY) / Float(size),
                       u1: Float(shelfX + w) / Float(size), v1: Float(shelfY + h) / Float(size),
                       width: Double(pointSize.width), height: Double(pointSize.height))
        shelfX += w + pad
        shelfH = max(shelfH, h)
        return r
    }

    // MARK: - Rasterung

    private func render(_ key: Key) -> (CGImage, CGSize)? {
        switch key {
        case .annotation(let style, let size):
            return renderAnnotation(style, size: size)
        case .image(let name, let size):
            guard let img = Self.loadImage(name) else { return nil }
            let s = CGSize(width: size, height: size * img.size.height / max(img.size.width, 1))
            return (rasterize(size: s) { img.draw(in: CGRect(origin: .zero, size: s)) }, s)
        case .text(let text, let size, let weight, let color, let halo):
            return renderText(text, size: size, weight: weight, color: color, halo: halo)
        }
    }

    static func loadImage(_ name: String) -> UIImage? {
        if let i = UIImage(named: name) { return i }
        for ext in ["png", "pdf", "jpg"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext), let i = UIImage(contentsOfFile: url.path) { return i }
        }
        return nil
    }

    private func rasterize(size: CGSize, _ draw: () -> Void) -> CGImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        return r.image { _ in draw() }.cgImage!
    }

    private static func ui(_ c: RGBA) -> UIColor { UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a)) }

    private func renderAnnotation(_ style: MapAnnotation.Style, size: Double) -> (CGImage, CGSize)? {
        switch style {
        case .pin(let color, let glyphText, let symbolName, let glyphColor):
            let s = CGSize(width: size, height: size * 1.3)
            let img = rasterize(size: s) {
                let ctx = UIGraphicsGetCurrentContext()!
                let r = size / 2 - 1.5
                let cx = size / 2, cy = size / 2
                // Tropfen: Kreis + Spitze nach unten
                let path = UIBezierPath()
                path.addArc(withCenter: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi * 0.85, endAngle: .pi * 0.15, clockwise: true)
                path.addLine(to: CGPoint(x: cx, y: s.height - 1))
                path.close()
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                Self.ui(color).setFill(); path.fill()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 1.5; path.stroke()
                Self.drawGlyph(text: glyphText, symbol: symbolName, color: Self.ui(glyphColor), center: CGPoint(x: cx, y: cy), size: r * 1.1)
            }
            return (img, s)
        case .circle(let color, let glyphText, let symbolName, let glyphColor, let ring):
            let s = CGSize(width: size, height: size)
            let img = rasterize(size: s) {
                let ctx = UIGraphicsGetCurrentContext()!
                let c = CGPoint(x: size / 2, y: size / 2)
                var r = size / 2 - 1.5
                if let ring {
                    Self.ui(ring).setFill()
                    UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
                    r -= size * 0.14
                    UIColor.white.setFill()
                    UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
                    r -= size * 0.05
                } else {
                    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                }
                Self.ui(color).setFill()
                UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                if ring == nil {
                    UIColor.white.withAlphaComponent(0.9).setStroke()
                    let p = UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    p.lineWidth = 1.5; p.stroke()
                }
                Self.drawGlyph(text: glyphText, symbol: symbolName, color: Self.ui(glyphColor), center: c, size: r * 1.15)
            }
            return (img, s)
        case .image(let name):
            guard let ui = Self.loadImage(name) else { return nil }
            let s = CGSize(width: size, height: size * ui.size.height / max(ui.size.width, 1))
            return (rasterize(size: s) { ui.draw(in: CGRect(origin: .zero, size: s)) }, s)
        case .text(let text, let color, let halo):
            return renderText(text, size: size, weight: 600, color: Self.pack(color), halo: Self.pack(halo))
        case .ring(let symbolName, let fill, let symbolColor, let segments, let track):
            let s = CGSize(width: size, height: size)
            let img = rasterize(size: s) {
                let ctx = UIGraphicsGetCurrentContext()!
                let c = CGPoint(x: size / 2, y: size / 2)
                let ringWidth = size * 0.16
                let rRing = size / 2 - ringWidth / 2 - 0.5
                // Ring: Segmente mit Lücke, ab 17 Einheiten proportional ohne Lücken
                let n = segments.count
                if n == 0 {
                    let p = UIBezierPath(arcCenter: c, radius: rRing, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    p.lineWidth = ringWidth; Self.ui(track).setStroke(); p.stroke()
                } else {
                    let gap: CGFloat = n <= 16 ? (n == 1 ? 0 : 0.10) : 0
                    let step = 2 * CGFloat.pi / CGFloat(n)
                    for (i, col) in segments.enumerated() {
                        let a0 = -CGFloat.pi / 2 + step * CGFloat(i) + gap / 2
                        let a1 = a0 + step - gap
                        let p = UIBezierPath(arcCenter: c, radius: rRing, startAngle: a0, endAngle: a1, clockwise: true)
                        p.lineWidth = ringWidth; p.lineCapStyle = n <= 16 ? .butt : .butt
                        Self.ui(col).setStroke(); p.stroke()
                    }
                }
                // Kern
                let rCore = size / 2 - ringWidth - 1.5
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.25).cgColor)
                Self.ui(fill).setFill()
                UIBezierPath(arcCenter: c, radius: rCore, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.setStroke()
                let border = UIBezierPath(arcCenter: c, radius: rCore, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                border.lineWidth = 1.2; border.stroke()
                Self.drawGlyph(text: nil, symbol: symbolName, color: Self.ui(symbolColor), center: c, size: rCore * 1.25)
            }
            return (img, s)
        case .pill(let text, let symbolName, let fill, let textColor, let stroke):
            let h = size, tail = h * 0.28, pad = h * 0.32
            let font = UIFont.systemFont(ofSize: h * 0.52, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.ui(textColor)]
            let ns = NSString(string: text)
            let tw = ns.size(withAttributes: attrs).width
            let symbolW: CGFloat = symbolName != nil ? h * 0.62 : 0
            let w = ceil(pad + symbolW + tw + pad + 4)
            let s = CGSize(width: w, height: h + tail + 3)
            let img = rasterize(size: s) {
                let ctx = UIGraphicsGetCurrentContext()!
                let body = CGRect(x: 2, y: 1, width: w - 4, height: h)
                // Ein zusammenhängender Umriss (Pille + Spitze), damit keine Kante zwischen Körper
                // und Spitze entsteht – die Spitze wächst unten aus der Pille heraus.
                let r = h / 2, cx = w / 2
                let path = UIBezierPath()
                path.move(to: CGPoint(x: body.minX + r, y: body.minY))
                path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
                path.addArc(withCenter: CGPoint(x: body.maxX - r, y: body.midY), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
                path.addLine(to: CGPoint(x: cx + tail * 0.75, y: body.maxY))
                path.addLine(to: CGPoint(x: cx, y: body.maxY + tail))
                path.addLine(to: CGPoint(x: cx - tail * 0.75, y: body.maxY))
                path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
                path.addArc(withCenter: CGPoint(x: body.minX + r, y: body.midY), radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: true)
                path.close()
                path.lineJoinStyle = .round
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                Self.ui(fill).setFill(); path.fill()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                Self.ui(stroke).setStroke(); path.lineWidth = 1.5; path.stroke()
                var x = body.minX + pad
                if let symbolName {
                    Self.drawGlyph(text: nil, symbol: symbolName, color: Self.ui(textColor),
                                   center: CGPoint(x: x + symbolW / 2 - 2, y: body.midY), size: h * 0.9)
                    x += symbolW
                }
                ns.draw(at: CGPoint(x: x, y: body.midY - font.lineHeight / 2), withAttributes: attrs)
            }
            return (img, s)
        }
    }

    private static func drawGlyph(text: String?, symbol: String?, color: UIColor, center: CGPoint, size: CGFloat) {
        if let symbol, let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.7, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let s = img.size
            img.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
        } else if let text {
            let font = UIFont.systemFont(ofSize: size * (text.count > 1 ? 0.62 : 0.78), weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let ns = NSString(string: text)
            let sz = ns.size(withAttributes: attrs)
            ns.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        }
    }

    static func pack(_ c: RGBA) -> UInt32 {
        (UInt32(c.r * 255) << 24) | (UInt32(c.g * 255) << 16) | (UInt32(c.b * 255) << 8) | UInt32(c.a * 255)
    }
    static func unpack(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255, blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }

    /// Text mit Halo (Konturschrift), wie Kartenbeschriftungen. `weight` 400…800.
    private func renderText(_ text: String, size: Double, weight: Int, color: UInt32, halo: UInt32) -> (CGImage, CGSize)? {
        let w: UIFont.Weight = weight >= 700 ? .bold : (weight >= 600 ? .semibold : (weight >= 500 ? .medium : .regular))
        let font = UIFont.systemFont(ofSize: size, weight: w)
        // Halo schmal (~2 pt bei 11 pt), runde Ecken – Miter-Joins der Kontur wirken sonst „ausgefranst“.
        let haloWidth = max(1.5, size * 0.17)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.unpack(color)]
        let ns = NSString(string: text)
        let textSize = ns.size(withAttributes: attrs)
        let s = CGSize(width: ceil(textSize.width + haloWidth * 2 + 2), height: ceil(textSize.height + haloWidth * 2))
        let haloColor = Self.unpack(halo)
        let img = rasterize(size: s) {
            let ctx = UIGraphicsGetCurrentContext()!
            let origin = CGPoint(x: haloWidth + 1, y: haloWidth)
            if haloColor.cgColor.alpha > 0.01 {
                ctx.saveGState()
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                ctx.setShouldAntialias(true); ctx.setAllowsAntialiasing(true)
                // strokeWidth in Prozent der Schriftgröße; negativ = füllen + Kontur
                let haloAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: haloColor,
                                                                 .strokeColor: haloColor, .strokeWidth: -(haloWidth * 2 / size) * 100]
                ns.draw(at: origin, withAttributes: haloAttrs)
                ctx.restoreGState()
            }
            ns.draw(at: origin, withAttributes: attrs)
        }
        return (img, s)
    }
}
#endif
