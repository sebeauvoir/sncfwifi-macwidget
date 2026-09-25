import Cocoa
import CoreText

class StatusBarImageGenerator {
    /// Une valeur de la pastille : « 278 », unité « km/h » en colonne à sa droite.
    struct Readout {
        let value: String
        let unit: String
        /// Gabarit de largeur minimale (« 888 ») : la colonne ne change pas de largeur quand la
        /// valeur perd un chiffre, la pastille ne bouge pas dans la barre de menus.
        let template: String
    }

    /// Valeurs côte à côte, unité de chacune en lettres empilées à sa droite (le « / » devient
    /// un trait de fraction : « km » sur « h »), jauge de progression en dessous.
    /// - Parameter progress: `nil` pour ne pas dessiner de jauge (réseau sans desserte connue).
    static func draw(readouts: [Readout], progress: Double?) -> NSImage? {
        guard !readouts.isEmpty else { return nil }

        // Chiffres à chasse fixe : la vitesse ne fait pas trembler la pastille.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let unitFont = NSFont.systemFont(ofSize: 5.5, weight: .semibold)
        // Noir : transformé par isTemplate selon le thème de la barre de menus.
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]

        let columns = readouts.map { readout -> (value: NSAttributedString, valueWidth: CGFloat, unit: UnitStack) in
            let value = NSAttributedString(string: readout.value, attributes: valueAttributes)
            let template = NSAttributedString(string: readout.template, attributes: valueAttributes)
            let width = ceil(max(value.size().width, template.size().width))
            return (value, width, UnitStack(readout.unit, font: unitFont))
        }

        let marginX: CGFloat = 4
        let unitGap: CGFloat = 1.5
        let spacing: CGFloat = 7
        let columnWidths = columns.map { $0.valueWidth + unitGap + $0.unit.width }
        let contentWidth = columnWidths.reduce(0, +) + spacing * CGFloat(columns.count - 1)
        let width = ceil(contentWidth + marginX * 2)
        let height = max(22, NSStatusBar.system.thickness)

        // Chiffres centrés dans la hauteur laissée libre par la jauge ; unités centrées sur
        // les chiffres.
        let barY: CGFloat = 1.5
        let barHeight: CGFloat = 2.5
        let bottom: CGFloat = progress == nil ? 0 : barY + barHeight + 1
        let middle = bottom + (height - bottom) / 2
        let valueBaseline = (middle - valueFont.capHeight / 2).rounded()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        var x = marginX
        for (index, column) in columns.enumerated() {
            // Valeur calée à droite contre son unité ; `draw(at:)` place le bas de la ligne,
            // descendante comprise, au point donné.
            let valueSize = column.value.size()
            column.value.draw(at: NSPoint(x: x + column.valueWidth - valueSize.width,
                                          y: valueBaseline + valueFont.descender))
            column.unit.draw(x: x + column.valueWidth + unitGap,
                             centerY: valueBaseline + valueFont.capHeight / 2)
            x += columnWidths[index] + spacing
        }

        if let progress {
            drawProgress(progress, x: marginX, y: barY, width: contentWidth, height: barHeight)
        }

        image.unlockFocus()

        // S'adapte au thème clair / sombre de macOS.
        image.isTemplate = true

        return image
    }

    /// Unité en lettres empilées : « k m — h » pour km/h, « k m » pour km. Chaque lettre est
    /// placée d'après son encre réelle, pour un empilement serré et régulier.
    private struct UnitStack {
        private enum Piece {
            case glyph(NSAttributedString, CGRect)
            case bar
        }

        private let pieces: [Piece]
        private let font: NSFont
        private let letterGap: CGFloat = 0.8
        private let barThickness: CGFloat = 0.7
        private let barGap: CGFloat = 1.1
        let width: CGFloat

        init(_ unit: String, font: NSFont) {
            self.font = font
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            pieces = unit.map { character -> Piece in
                guard character != "/" else { return .bar }
                let text = NSAttributedString(string: String(character), attributes: attributes)
                return .glyph(text, UnitStack.inkBounds(of: character, font: font))
            }
            let widest = pieces.compactMap { piece -> CGFloat? in
                if case let .glyph(_, bounds) = piece { return bounds.width }
                return nil
            }.max() ?? 0
            width = ceil(widest + 0.5)
        }

        private var height: CGFloat {
            pieces.enumerated().reduce(0) { total, item in
                let gap: CGFloat = item.offset == 0 ? 0 : gapBefore(item.offset)
                switch item.element {
                case let .glyph(_, bounds): return total + gap + bounds.height
                case .bar: return total + gap + barThickness
                }
            }
        }

        private func gapBefore(_ index: Int) -> CGFloat {
            let isBar: (Piece) -> Bool = { if case .bar = $0 { return true } else { return false } }
            return isBar(pieces[index]) || isBar(pieces[index - 1]) ? barGap : letterGap
        }

        func draw(x: CGFloat, centerY: CGFloat) {
            var top = centerY + height / 2
            for (index, piece) in pieces.enumerated() {
                if index > 0 { top -= gapBefore(index) }
                switch piece {
                case let .glyph(text, bounds):
                    // Ligne de base telle que le haut de l'encre tombe sur `top`.
                    let baseline = top - bounds.maxY
                    text.draw(at: NSPoint(x: x + (width - bounds.width) / 2 - bounds.minX,
                                          y: baseline + font.descender))
                    top -= bounds.height
                case .bar:
                    NSColor.black.setFill()
                    NSRect(x: x + 0.25, y: top - barThickness, width: width - 0.5, height: barThickness).fill()
                    top -= barThickness
                }
            }
        }

        /// Encre du caractère, relative à la ligne de base.
        private static func inkBounds(of character: Character, font: NSFont) -> CGRect {
            let utf16 = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyphs, utf16.count) else {
                return CGRect(x: 0, y: 0, width: font.pointSize * 0.6, height: font.capHeight)
            }
            return CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, glyphs, nil, glyphs.count)
        }
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
