// 產生 AppIcon.icns：swift scripts/make_icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.45, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.75, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // 手機外框
    let pw = rect.width * 0.38, ph = rect.width * 0.66
    let phone = NSRect(x: rect.midX - pw / 2, y: rect.midY - ph / 2, width: pw, height: ph)
    let body = NSBezierPath(roundedRect: phone, xRadius: pw * 0.18, yRadius: pw * 0.18)
    NSColor.white.setFill(); body.fill()
    let screen = phone.insetBy(dx: pw * 0.08, dy: pw * 0.08)
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(roundedRect: screen, xRadius: pw * 0.11, yRadius: pw * 0.11).fill()
    // 螢幕上的四格 App
    let g = screen.width * 0.26, gap = screen.width * 0.12
    let colors: [NSColor] = [.systemGreen, .systemOrange, .systemPink, .systemTeal]
    for i in 0..<4 {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let x = screen.midX - g - gap / 2 + col * (g + gap)
        let y = screen.midY + gap / 2 - row * (g + gap)
        colors[i].setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: g, height: g), xRadius: g * 0.25, yRadius: g * 0.25).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run(); p.waitUntilExit()
