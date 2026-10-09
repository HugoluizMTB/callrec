// Gera Resources/AppIcon.icns: squircle com gradiente + telefone com onda (SF Symbol).
// Uso: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = size * 0.1  // margem padrão dos ícones do macOS
        let box = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.shadowBlurRadius = size * 0.03
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.33, alpha: 1),
                            NSColor(red: 0.86, green: 0.15, blue: 0.36, alpha: 1)])!
            .draw(in: path, angle: -90)
        // brilho sutil no topo
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225), angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: box.width * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "phone.badge.waveform.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = render(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ \(out.path)" : "iconutil falhou")
