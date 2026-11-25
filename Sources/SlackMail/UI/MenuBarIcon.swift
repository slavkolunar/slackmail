import AppKit

/// Ikonica za gornju traku: oblačić poruke (Slack) sa kovertom (mejl) unutra.
/// Template slika — macOS je sam boji za svetlu/tamnu traku. Vektorska, pa je oštra i na 1x i na 2x.
enum MenuBarIcon {
    enum Variant { case active, paused, error }

    static let size = NSSize(width: 20, height: 16)

    /// `scale` > 1 crta isti vektor u većoj veličini (za logo aplikacije), bez pikselizacije.
    static func image(_ variant: Variant, scale: CGFloat = 1) -> NSImage {
        let img = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            let bubble = bubblePath()
            switch variant {
            case .active:
                NSColor.black.setFill()
                bubble.fill()
                // Koverta se "izreže" iz punog oblačića.
                ctx.setBlendMode(.destinationOut)
                let env = envelopePath()
                env.lineWidth = 1.35
                env.lineJoinStyle = .round
                env.lineCapStyle = .round
                env.stroke()
                ctx.setBlendMode(.normal)
            case .paused:
                NSColor.black.setStroke()
                bubble.lineWidth = 1.3
                bubble.stroke()
                let env = envelopePath()
                env.lineWidth = 1.2
                env.lineJoinStyle = .round
                env.lineCapStyle = .round
                env.stroke()
            case .error:
                NSColor.black.setStroke()
                bubble.lineWidth = 1.3
                bubble.stroke()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 9.3, y: 3.2, width: 1.5, height: 5.2), xRadius: 0.75, yRadius: 0.75).fill()
                NSBezierPath(ovalIn: NSRect(x: 9.25, y: 9.3, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "SlackMail"
        return img
    }

    private static func bubblePath() -> NSBezierPath {
        let p = NSBezierPath()
        let r: CGFloat = 3.6
        let minX: CGFloat = 1.2, maxX: CGFloat = 18.8, minY: CGFloat = 1.2, maxY: CGFloat = 12.2
        p.move(to: NSPoint(x: minX + r, y: minY))
        p.line(to: NSPoint(x: maxX - r, y: minY))
        p.appendArc(withCenter: NSPoint(x: maxX - r, y: minY + r), radius: r, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: maxX, y: maxY - r))
        p.appendArc(withCenter: NSPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: 0, endAngle: 90)
        // rep oblačića dole levo
        p.line(to: NSPoint(x: 9.0, y: maxY))
        p.line(to: NSPoint(x: 5.0, y: 15.2))
        p.line(to: NSPoint(x: 5.6, y: maxY))
        p.line(to: NSPoint(x: minX + r, y: maxY))
        p.appendArc(withCenter: NSPoint(x: minX + r, y: maxY - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: minX, y: minY + r))
        p.appendArc(withCenter: NSPoint(x: minX + r, y: minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    private static func envelopePath() -> NSBezierPath {
        let rect = NSRect(x: 5.4, y: 4.0, width: 9.2, height: 5.6)
        let p = NSBezierPath(roundedRect: rect, xRadius: 0.9, yRadius: 0.9)
        p.move(to: NSPoint(x: rect.minX + 0.4, y: rect.minY + 0.5))
        p.line(to: NSPoint(x: rect.midX, y: rect.minY + 3.3))
        p.line(to: NSPoint(x: rect.maxX - 0.4, y: rect.minY + 0.5))
        return p
    }
}
