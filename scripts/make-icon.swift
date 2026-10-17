// Draws the app icon (a RAM module on a light grey squircle) and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>; make-app.sh turns it into AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ ctx: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors.map { color($0) } as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

/// Draws in a 1024×1024 coordinate space (y up), following Apple's macOS icon grid.
func drawIcon(_ ctx: CGContext) {
    // Background squircle with the standard drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0xE2E4E8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linearGradient(ctx, [0xF7F8FA, 0xD3D6DC], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    // RAM module: PCB with side notches, a key notch between the contacts, chips and gold fingers.
    let pcb = CGRect(x: 160, y: 352, width: 704, height: 320)
    let pcbPath = CGMutablePath()
    pcbPath.addRoundedRect(in: pcb, cornerWidth: 22, cornerHeight: 22)
    let notchY = pcb.minY + 120
    for x in [pcb.minX, pcb.maxX] {
        pcbPath.addEllipse(in: CGRect(x: x - 22, y: notchY - 22, width: 44, height: 44))
    }
    let keyNotch = CGRect(x: 590, y: pcb.minY - 1, width: 28, height: 44)
    pcbPath.addRect(keyNotch)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000000, 0.3))
    ctx.addPath(pcbPath)
    ctx.setFillColor(color(0x1F8A55))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pcbPath)
    ctx.clip(using: .evenOdd)
    linearGradient(ctx, [0x34B873, 0x1A7446], from: CGPoint(x: 512, y: pcb.maxY), to: CGPoint(x: 512, y: pcb.minY))

    // Gold contact fingers along the bottom edge.
    let fingerHeight: CGFloat = 54
    let fingerWidth: CGFloat = 13, fingerGap: CGFloat = 9
    var x = pcb.minX + 34
    while x + fingerWidth <= pcb.maxX - 34 {
        let finger = CGRect(x: x, y: pcb.minY, width: fingerWidth, height: fingerHeight)
        if !finger.intersects(keyNotch.insetBy(dx: -6, dy: 0)) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: finger, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.clip()
            linearGradient(ctx, [0xFFE08A, 0xD9A23A], from: CGPoint(x: x, y: finger.maxY),
                           to: CGPoint(x: x, y: finger.minY))
            ctx.restoreGState()
        }
        x += fingerWidth + fingerGap
    }

    // Thin highlight along the top edge of the board.
    ctx.setFillColor(color(0xFFFFFF, 0.18))
    ctx.fill(CGRect(x: pcb.minX, y: pcb.maxY - 8, width: pcb.width, height: 8))
    ctx.restoreGState()

    // Memory chips.
    let chipCount = 4
    let chipWidth: CGFloat = 128, chipHeight: CGFloat = 168
    let spacing = (pcb.width - CGFloat(chipCount) * chipWidth) / CGFloat(chipCount + 1)
    for i in 0..<chipCount {
        let chip = CGRect(x: pcb.minX + spacing + CGFloat(i) * (chipWidth + spacing),
                          y: pcb.minY + 96, width: chipWidth, height: chipHeight)
        let chipPath = CGPath(roundedRect: chip, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: color(0x000000, 0.4))
        ctx.addPath(chipPath)
        ctx.setFillColor(color(0x23262E))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(chipPath)
        ctx.clip()
        linearGradient(ctx, [0x3A3F4B, 0x1A1C22], from: CGPoint(x: chip.minX, y: chip.maxY),
                       to: CGPoint(x: chip.maxX, y: chip.minY))
        ctx.restoreGState()

        // Pin-1 dot.
        ctx.setFillColor(color(0xFFFFFF, 0.25))
        ctx.fillEllipse(in: CGRect(x: chip.minX + 14, y: chip.maxY - 30, width: 14, height: 14))
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(ctx)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let dest = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("Couldn't write \(name)") }
    }
}
