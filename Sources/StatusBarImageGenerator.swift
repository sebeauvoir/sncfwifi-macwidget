import Cocoa

class StatusBarImageGenerator {
    /// Une valeur de la pastille : « 278 » sur « km/h ».
    struct Readout {
        let value: String
        let unit: String
        /// Gabarit de largeur minimale (« 888 ») : la colonne ne change pas de largeur quand la
        /// valeur perd un chiffre, la pastille ne bouge pas dans la barre de menus.
        let template: String
    }

    /// Valeurs côte à côte, unités en tout petit sous chacune, jauge de progression en dessous.
    /// - Parameter progress: `nil` pour ne pas dessiner de jauge (réseau sans desserte connue).
    static func draw(readouts: [Readout], progress: Double?) -> NSImage? {
        guard !readouts.isEmpty else { return nil }

        // Chiffres à chasse fixe : la vitesse ne fait pas trembler la pastille.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let unitFont = NSFont.systemFont(ofSize: 5.5, weight: .medium)
        // Noir : transformé par isTemplate selon le thème de la barre de menus.
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let unitAttributes: [NSAttributedString.Key: Any] = [.font: unitFont, .foregroundColor: NSColor.black]

        let columns = readouts.map { readout -> (value: NSAttributedString, unit: NSAttributedString, width: CGFloat) in
            let value = NSAttributedString(string: readout.value, attributes: valueAttributes)
            let unit = NSAttributedString(string: readout.unit, attributes: unitAttributes)
            let template = NSAttributedString(string: readout.template, attributes: valueAttributes)
            let width = ceil(max(value.size().width, unit.size().width, template.size().width))
            return (value, unit, width)
        }

        let marginX: CGFloat = 4
        let spacing: CGFloat = 8
        let contentWidth = columns.reduce(0) { $0 + $1.width } + spacing * CGFloat(columns.count - 1)
        let width = contentWidth + marginX * 2
        let height = max(22, NSStatusBar.system.thickness)

        // Lignes de base : l'unité juste au-dessus de la jauge, la valeur au-dessus de l'unité.
        // Sans jauge, l'ensemble descend pour rester centré.
        let barY: CGFloat = 1.5
        let barHeight: CGFloat = 2.5
        let unitBaseline: CGFloat = (progress == nil ? 2.5 : barY + barHeight + 2) + (height - 22) / 2
        let valueBaseline = unitBaseline + unitFont.capHeight + 2.25

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        var x = marginX
        for column in columns {
            // `draw(at:)` place le bas de la ligne, descendante comprise, au point donné.
            let valueSize = column.value.size()
            column.value.draw(at: NSPoint(x: x + (column.width - valueSize.width) / 2,
                                          y: valueBaseline + valueFont.descender))
            let unitSize = column.unit.size()
            column.unit.draw(at: NSPoint(x: x + (column.width - unitSize.width) / 2,
                                         y: unitBaseline + unitFont.descender))
            x += column.width + spacing
        }

        if let progress {
            drawProgress(progress, x: marginX, y: barY, width: contentWidth, height: barHeight)
        }

        image.unlockFocus()

        // S'adapte au thème clair / sombre de macOS.
        image.isTemplate = true

        return image
    }

    /// Jauge arrondie, partie parcourue pleine et pouce de progression.
    private static func drawProgress(_ progress: Double, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius).fill()

        let clamped = CGFloat(max(0.0, min(1.0, progress)))
        let filled = width * clamped
        if filled > 0 {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: filled, height: height), xRadius: radius, yRadius: radius).fill()
        }

        // Pouce, borné pour ne pas déborder de la jauge.
        let thumbRadius: CGFloat = 3
        let thumbX = min(max(x + filled - thumbRadius, x - thumbRadius), x + width - thumbRadius)
        let thumbRect = NSRect(x: thumbX, y: y + radius - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: thumbRect).fill()
    }
}
