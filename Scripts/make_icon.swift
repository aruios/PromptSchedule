import AppKit
import CoreGraphics

// Renders the PromptSchedule app icon at 1024x1024.
// Usage: swift make_icon.swift <output.png>

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: Base tile (macOS icon grid: 824pt tile inset 100pt)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x3A2BA8))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
linear([rgb(0x7463F5), rgb(0x4A36C9), rgb(0x24196E)],
       from: CGPoint(x: 300, y: 100), to: CGPoint(x: 724, y: 924))
// Soft top sheen.
let sheen = CGGradient(colorsSpace: space,
                       colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 400, y: 120), startRadius: 0,
                       endCenter: CGPoint(x: 400, y: 120), endRadius: 620, options: [])

// MARK: Queue cards
struct Card { var y: CGFloat; var alpha: CGFloat; var line: CGFloat }
let cards = [Card(y: 660, alpha: 0.45, line: 190),
             Card(y: 512, alpha: 0.72, line: 250),
             Card(y: 364, alpha: 1.0, line: 210)]
let cardX: CGFloat = 176, cardW: CGFloat = 440, cardH: CGFloat = 116

for card in cards {
    let rect = CGRect(x: cardX, y: card.y, width: cardW, height: cardH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: rgb(0x120B45, 0.35))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, card.alpha))
    ctx.fillPath()
    ctx.restoreGState()

    // Terminal prompt chevron.
    let cy = rect.midY
    ctx.setStrokeColor(rgb(0x4A36C9, card.alpha))
    ctx.setLineWidth(20)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: cardX + 48, y: cy - 26))
    ctx.addLine(to: CGPoint(x: cardX + 78, y: cy))
    ctx.addLine(to: CGPoint(x: cardX + 48, y: cy + 26))
    ctx.strokePath()

    // Prompt text line.
    let line = CGRect(x: cardX + 118, y: cy - 13, width: card.line, height: 26)
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(rgb(0xB9B0F2, card.alpha))
    ctx.fillPath()
}

// MARK: Motion trail into the plane
ctx.saveGState()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.6))
ctx.setLineWidth(13)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [1, 32])
ctx.move(to: CGPoint(x: 646, y: 712))
ctx.addQuadCurve(to: CGPoint(x: 748, y: 600), control: CGPoint(x: 730, y: 700))
ctx.strokePath()
ctx.restoreGState()

// MARK: Paper plane (send), nose pointing up-right
let nose = CGPoint(x: 866, y: 300)
let wing = CGPoint(x: 634, y: 416)
let fold = CGPoint(x: 742, y: 458)
let tail = CGPoint(x: 790, y: 590)
let keel = CGPoint(x: 744, y: 528)

func face(_ pts: [CGPoint], _ colors: [CGColor], _ a: CGPoint, _ b: CGPoint) {
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    linear(colors, from: a, to: b)
    ctx.restoreGState()
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 22, color: rgb(0x120B45, 0.45))
let outline = CGMutablePath()
outline.addLines(between: [nose, wing, fold, keel, tail])
outline.closeSubpath()
ctx.addPath(outline)
ctx.setFillColor(rgb(0xFF8A5C))
ctx.fillPath()
ctx.restoreGState()

face([nose, wing, fold], [rgb(0xFFD08A), rgb(0xFF9A62)], CGPoint(x: 800, y: 320), CGPoint(x: 680, y: 440))
face([nose, fold, tail], [rgb(0xFF7F55), rgb(0xE85A35)], CGPoint(x: 820, y: 340), CGPoint(x: 770, y: 580))
face([fold, keel, tail], [rgb(0xC8442A), rgb(0xA8341F)], CGPoint(x: 742, y: 470), CGPoint(x: 780, y: 580))

// MARK: Sparkles (reframe)
func sparkle(center c: CGPoint, radius r: CGFloat, color: CGColor) {
    let w = r * 0.28
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: rgb(0xFFE08A, 0.7))
    ctx.addPath(p)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}
sparkle(center: CGPoint(x: 252, y: 262), radius: 66, color: rgb(0xFFD66B))
sparkle(center: CGPoint(x: 350, y: 222), radius: 28, color: rgb(0xFFE9A8))

ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
