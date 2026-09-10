import Cocoa

class StatusBarImageGenerator {
    /// Largeur maximale de la pastille (px). Au-delà, le texte est tronqué avec « … ».
    /// Borner la largeur évite que macOS masque complètement l'élément quand la barre
    /// de menus est encombrée (notamment avec l'encoche des MacBook récents).
    static let maxWidth: CGFloat = 150

    /// Texte au-dessus, jauge de progression en dessous.
    /// - Parameters:
    ///   - progress: `nil` pour ne pas dessiner de jauge (réseau sans desserte connue).
    ///   - maxWidth: le texte est tronqué au-delà.
    static func draw(text: String, progress: Double?, maxWidth: CGFloat = StatusBarImageGenerator.maxWidth) -> NSImage? {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black, // Sera transformé par isTemplate
            .paragraphStyle: paragraph
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let naturalSize = attributedString.size()

        let marginX: CGFloat = 4
        let maxTextWidth = max(0, maxWidth - marginX * 2)
        let textWidth = min(naturalSize.width, maxTextWidth)
        let width = textWidth + (marginX * 2)
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        // Décalé vers le haut pour laisser place à la barre, recentré s'il n'y en a pas.
        let textY: CGFloat = progress == nil ? 4 : 6
        let textRect = NSRect(x: marginX, y: textY, width: textWidth, height: naturalSize.height)
        attributedString.draw(in: textRect)

        if let progress {
            let barWidth = textWidth
            let barHeight: CGFloat = 2.5
            let barY: CGFloat = 2

            let bgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: barWidth, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
            NSColor.black.withAlphaComponent(0.3).setFill()
            bgPath.fill()

            let clampedProgress = CGFloat(max(0.0, min(1.0, progress)))
            let progressW = barWidth * clampedProgress

            if progressW > 0 {
                let fgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: progressW, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
                NSColor.black.setFill()
                fgPath.fill()
            }

            // Pouce de progression, borné pour ne pas déborder de la barre.
            let thumbRadius: CGFloat = 3.0
            var thumbX = marginX + progressW - thumbRadius
            if thumbX < marginX - thumbRadius { thumbX = marginX - thumbRadius }
            if thumbX > marginX + barWidth - thumbRadius { thumbX = marginX + barWidth - thumbRadius }

            let thumbRect = NSRect(x: thumbX, y: barY + (barHeight/2) - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)

            let thumbPath = NSBezierPath(ovalIn: thumbRect)
            NSColor.black.setFill()
            thumbPath.fill()
        }

        image.unlockFocus()
        
        // S'adapte au thème clair / sombre de macOS.
        image.isTemplate = true
        
        return image
    }
}
