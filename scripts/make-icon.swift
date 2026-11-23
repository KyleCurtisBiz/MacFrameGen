// Draws the app icon (1024 px PNG): two real frames with a glowing generated frame between them.
// Usage: swift scripts/make-icon.swift icon-1024.png   (then sips + iconutil to make Resources/AppIcon.icns)
import AppKit
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
// macOS icon shape: 824 px rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: col(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(col(0.05, 0.06, 0.12)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [col(0.10, 0.12, 0.26), col(0.03, 0.04, 0.09)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Three 16:9 frames stepping diagonally; the middle one is the generated frame.
let w: CGFloat = 440, h: CGFloat = 248, r: CGFloat = 34
func frame(_ cx: CGFloat, _ cy: CGFloat) -> CGPath { CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil) }
func solid(_ p: CGPath, _ top: CGColor, _ bottom: CGColor, shadow: CGColor, blur: CGFloat) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: blur, color: shadow)
    ctx.addPath(p); ctx.setFillColor(bottom); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    let b = p.boundingBox
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!, start: CGPoint(x: b.midX, y: b.maxY), end: CGPoint(x: b.midX, y: b.minY), options: [])
    ctx.restoreGState()
}
solid(frame(372, 652), col(0.62, 0.66, 0.78), col(0.42, 0.46, 0.60), shadow: col(0, 0, 0, 0.5), blur: 26)          // older real frame
solid(frame(512, 512), col(0.35, 0.95, 0.80), col(0.10, 0.70, 0.95), shadow: col(0.2, 0.9, 0.9, 0.85), blur: 60)     // generated frame
solid(frame(652, 372), col(0.98, 0.98, 1.00), col(0.80, 0.83, 0.92), shadow: col(0, 0, 0, 0.5), blur: 26)          // newest real frame
ctx.restoreGState()
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
