import AppKit

/// O ícone do projeto: uma meia-lua com ponteiro, desenhada em código. As mesmas formas
/// geram o ícone colorido do app e a versão de uma cor da barra de menus.
/// (Não usa SF Symbols: a licença da Apple não permite símbolos em ícones de app.)
enum GaugeIcon {
    /// Quanto do arco aparece preenchido (o ponteiro aponta para cá).
    static let fraction: CGFloat = 0.72

    // MARK: Geometria compartilhada

    /// Ângulo (graus, eixo y para cima) de uma fração da meia-lua: 0 = esquerda, 1 = direita.
    private static func degrees(_ f: CGFloat) -> CGFloat { 180 - 180 * f }

    private static func point(_ center: NSPoint, _ radius: CGFloat, _ f: CGFloat) -> NSPoint {
        let a = degrees(f) * .pi / 180
        return NSPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }

    private static func arc(_ center: NSPoint, _ radius: CGFloat, to f: CGFloat, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: degrees(f), clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        return path
    }

    /// Ponteiro afinando até a ponta, com a base redonda no centro. Triângulo e círculo
    /// são preenchidos separados, senão a sobreposição deles vira um buraco.
    private static func fillNeedle(_ center: NSPoint, length: CGFloat, base: CGFloat) {
        let tip = point(center, length, fraction)
        let a = degrees(fraction) * .pi / 180
        let normal = NSPoint(x: -sin(a), y: cos(a))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + normal.x * base / 2, y: center.y + normal.y * base / 2))
        path.line(to: tip)
        path.line(to: NSPoint(x: center.x - normal.x * base / 2, y: center.y - normal.y * base / 2))
        path.close()
        path.fill()
        NSBezierPath(ovalIn: NSRect(x: center.x - base * 0.75, y: center.y - base * 0.75,
                                    width: base * 1.5, height: base * 1.5)).fill()
    }

    // MARK: Ícone do app

    enum Style: String, CaseIterable {
        case noturno, claro, azul, classico, setas, solido

        var title: String {
            switch self {
            case .noturno: "1 · Noturno"
            case .claro: "2 · Claro"
            case .azul: "3 · Azul do sistema"
            case .classico: "4 · Clássico"
            case .setas: "5 · Setas ↓↑"
            case .solido: "6 · Meia-lua sólida"
            }
        }
    }

    /// O estilo usado no app.
    static let style: Style = .setas

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(red: r, green: g, blue: b, alpha: a)
    }

    private static let navyTop = rgb(0.14, 0.19, 0.38)
    private static let navyBottom = rgb(0.04, 0.05, 0.14)
    private static let blueTop = rgb(0.24, 0.66, 1.00)
    private static let blueBottom = rgb(0.05, 0.35, 0.92)
    private static let cyanToBlue = [rgb(0.20, 0.85, 1.00), rgb(0.16, 0.42, 1.00)]
    private static let purpleToPink = [rgb(0.62, 0.36, 1.00), rgb(1.00, 0.36, 0.66)]

    /// Desenha o ícone colorido num quadrado de lado `s`, no contexto gráfico atual.
    static func drawAppIcon(side s: CGFloat, style: Style = style) {
        let radius = s * 0.29
        let width = s * 0.08
        let center = NSPoint(x: s / 2, y: s * 0.5 - radius / 2)

        switch style {
        case .noturno:
            drawTile(s, navyTop, navyBottom)
            drawGauge(s, center, radius, width, track: .white.withAlphaComponent(0.13), fill: cyanToBlue,
                      ticks: .white.withAlphaComponent(0.45), needle: .white, hub: navyBottom)
        case .claro:
            drawTile(s, .white, rgb(0.89, 0.90, 0.93))
            drawGauge(s, center, radius, width, track: .black.withAlphaComponent(0.08),
                      fill: [rgb(0.20, 0.78, 1.00), rgb(0.10, 0.40, 0.98)],
                      ticks: .black.withAlphaComponent(0.28), needle: rgb(0.12, 0.13, 0.16), hub: .white)
        case .azul:
            drawTile(s, blueTop, blueBottom)
            drawGauge(s, center, radius, width, track: .white.withAlphaComponent(0.28), fill: [.white, .white],
                      ticks: .white.withAlphaComponent(0.6), needle: .white, hub: blueBottom)
        case .classico:
            drawTile(s, rgb(0.24, 0.25, 0.28), rgb(0.08, 0.08, 0.10))
            drawGauge(s, center, radius, width, track: .clear,
                      fill: [rgb(0.20, 0.85, 0.40), rgb(1.00, 0.80, 0.10), rgb(1.00, 0.30, 0.25)], fillTo: 1,
                      ticks: .white.withAlphaComponent(0.5), needle: .white, hub: rgb(0.08, 0.08, 0.10))
        case .setas:
            drawTile(s, navyTop, navyBottom)
            let w = s * 0.2
            fillGradient(arrow(centerX: s * 0.39, bottom: s * 0.25, height: s * 0.44, width: w, up: false), cyanToBlue, angle: -90)
            fillGradient(arrow(centerX: s * 0.61, bottom: s * 0.31, height: s * 0.44, width: w, up: true), purpleToPink, angle: 90)
        case .solido:
            drawTile(s, blueTop, blueBottom)
            let r = s * 0.31
            let c = NSPoint(x: s / 2, y: s * 0.5 - r / 2)
            let half = NSBezierPath()
            half.move(to: c)
            half.appendArc(withCenter: c, radius: r, startAngle: 180, endAngle: 0, clockwise: true)
            half.close()
            NSColor.white.setFill()
            half.fill()
            blueBottom.setFill()
            fillNeedle(c, length: r * 0.82, base: s * 0.055)
        }
    }

    private static func drawTile(_ s: CGFloat, _ top: NSColor, _ bottom: NSColor) {
        // Placa com margem e cantos no padrão dos ícones do macOS.
        let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        bottom.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: top, ending: bottom)!.draw(in: tilePath, angle: -90)
    }

    private static func drawGauge(_ s: CGFloat, _ center: NSPoint, _ radius: CGFloat, _ width: CGFloat,
                                  track: NSColor, fill: [NSColor], fillTo: CGFloat = fraction,
                                  ticks: NSColor, needle: NSColor, hub: NSColor) {
        track.setStroke()
        arc(center, radius, to: 1, width: width).stroke()

        let filled = arc(center, radius, to: fillTo, width: width).cgPath
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        fillGradient(NSBezierPath(cgPath: filled), fill, angle: 0)

        // Marcas da escala, por dentro do arco
        ticks.setFill()
        for i in 0...6 {
            let p = point(center, radius - width * 1.25, CGFloat(i) / 6)
            let d = s * 0.016
            NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
        }

        needle.setFill()
        fillNeedle(center, length: radius - width * 0.2, base: s * 0.05)
        hub.setFill()
        let h = s * 0.024
        NSBezierPath(ovalIn: NSRect(x: center.x - h / 2, y: center.y - h / 2, width: h, height: h)).fill()
    }

    private static func fillGradient(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat) {
        NSGradient(colors: colors)!.draw(in: path, angle: angle)
    }

    /// Seta com haste e ponta, apontando para cima ou para baixo.
    private static func arrow(centerX x: CGFloat, bottom: CGFloat, height: CGFloat, width w: CGFloat, up: Bool) -> NSBezierPath {
        let shaft = w * 0.4
        let head = w * 0.8
        let top = bottom + height
        let pts: [NSPoint] = up
            ? [NSPoint(x: x - shaft / 2, y: bottom), NSPoint(x: x + shaft / 2, y: bottom),
               NSPoint(x: x + shaft / 2, y: top - head), NSPoint(x: x + w / 2, y: top - head),
               NSPoint(x: x, y: top), NSPoint(x: x - w / 2, y: top - head), NSPoint(x: x - shaft / 2, y: top - head)]
            : [NSPoint(x: x - shaft / 2, y: top), NSPoint(x: x + shaft / 2, y: top),
               NSPoint(x: x + shaft / 2, y: bottom + head), NSPoint(x: x + w / 2, y: bottom + head),
               NSPoint(x: x, y: bottom), NSPoint(x: x - w / 2, y: bottom + head), NSPoint(x: x - shaft / 2, y: bottom + head)]
        let path = NSBezierPath()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    /// Prancha comparando os estilos: cada um em tamanho grande e no tamanho do Dock/Finder pequeno.
    static func writeOptionsSheet(to url: URL) throws {
        let cell = NSSize(width: 300, height: 330)
        let cols = 3
        let rows = (Style.allCases.count + cols - 1) / cols
        let size = NSSize(width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        rgb(0.95, 0.95, 0.96).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, style) in Style.allCases.enumerated() {
            let origin = NSPoint(x: CGFloat(i % cols) * cell.width,
                                 y: size.height - CGFloat(i / cols + 1) * cell.height)
            draw(style, side: 240, at: NSPoint(x: origin.x + 30, y: origin.y + 70))
            draw(style, side: 40, at: NSPoint(x: origin.x + 30, y: origin.y + 22))
            draw(style, side: 20, at: NSPoint(x: origin.x + 76, y: origin.y + 32))
            (style.title as NSString).draw(
                at: NSPoint(x: origin.x + 108, y: origin.y + 33),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func draw(_ style: Style, side: CGFloat, at origin: NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: origin.x, yBy: origin.y)
        t.concat()
        drawAppIcon(side: side, style: style)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Grava o .iconset (todos os tamanhos que o macOS usa) na pasta indicada.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                drawAppIcon(side: CGFloat(px))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
                try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: Barra de menus

    /// Versão de uma cor (template): o macOS pinta de preto ou branco conforme a barra.
    /// Acompanha o estilo do ícone do app: setas ↓↑ ou a meia-lua com ponteiro.
    static let menuBarImage: NSImage = {
        let arrows = style == .setas
        let size = NSSize(width: arrows ? 14 : 19, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            if arrows {
                // Mesmo desenho do ícone do app, com a seta de upload um pouco mais alta.
                arrow(centerX: 4, bottom: 1, height: 13, width: 7, up: false).fill()
                arrow(centerX: 10, bottom: 2.5, height: 13, width: 7, up: true).fill()
                return true
            }
            let center = NSPoint(x: rect.midX, y: 4)
            let radius: CGFloat = 7.5
            NSColor.black.withAlphaComponent(0.35).setStroke()
            arc(center, radius, to: 1, width: 2.2).stroke()
            NSColor.black.setStroke()
            arc(center, radius, to: fraction, width: 2.2).stroke()
            fillNeedle(center, length: radius - 1.5, base: 2.2)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fluxo"
        return image
    }()
}
