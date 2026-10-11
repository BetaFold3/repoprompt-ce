import AppKit

package final class MentionDrawingLayoutManager: NSLayoutManager {
    override package func glyphRange(for textContainer: NSTextContainer) -> NSRange {
        guard textContainers.contains(where: { $0 === textContainer }) else {
            #if DEBUG
                assertionFailure("MentionDrawingLayoutManager asked for detached text container.")
            #endif
            return NSRange(location: 0, length: 0)
        }
        return super.glyphRange(for: textContainer)
    }

    override package func drawBackground(
        forGlyphRange glyphsToShow: NSRange,
        at origin: CGPoint
    ) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }

        let container: NSTextContainer? = {
            if glyphsToShow.location != NSNotFound, glyphsToShow.length > 0,
               let resolved = textContainer(
                   forGlyphAt: glyphsToShow.location,
                   effectiveRange: nil
               )
            {
                return resolved
            }
            return textContainers.first
        }()
        guard let container else { return }

        // Convert the glyph range we're asked to draw into a character range for safe attribute enumeration.
        var actualGlyphRange = NSRange(location: NSNotFound, length: 0)
        let charRangeToDraw = characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: &actualGlyphRange
        )

        textStorage.enumerateAttribute(
            .mentionToken,
            in: charRangeToDraw,
            options: []
        ) { value, attrCharRange, _ in
            guard value != nil else { return }

            // Convert the attribute's character range back into glyph space.
            let attrGlyphRange = self.glyphRange(
                forCharacterRange: attrCharRange,
                actualCharacterRange: nil
            )
            // Only draw the portion intersecting the current glyphsToShow batch.
            let drawGlyphRange = NSIntersectionRange(attrGlyphRange, actualGlyphRange)
            guard drawGlyphRange.length > 0 else { return }

            let rect = self.boundingRect(forGlyphRange: drawGlyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -2, dy: -1)

            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: 4,
                yRadius: 4
            )
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
        }
    }
}
