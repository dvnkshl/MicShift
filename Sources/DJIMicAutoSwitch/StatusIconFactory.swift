import AppKit

@MainActor
enum StatusIconFactory {
    /// The installed menu-bar app is intentionally white against the user's
    /// dark menu-bar treatment. Marketing artwork uses separate black paint.
    static let menuBarTintColor = NSColor.white
    static let marketingTintColor = NSColor(calibratedWhite: 0.08, alpha: 1)

    private enum Indicator {
        case none
        case offline
    }

    /// One compact template image where the microphone capsule is also the
    /// battery gauge. The capsule fills upward as charge increases.
    static func activeMicrophone(battery: TransmitterBatteryBand, accessibilityLabel: String) -> NSImage? {
        microphone(battery: battery, indicator: .none, accessibilityLabel: accessibilityLabel)
    }

    /// Offline keeps the exact same empty microphone/battery mark and adds one
    /// 45-degree disabled slash through the capsule. Color remains fully opaque.
    static func offlineMicrophone(accessibilityLabel: String) -> NSImage? {
        microphone(battery: .unknown, indicator: .offline, accessibilityLabel: accessibilityLabel)
    }

    /// Keep the menu-bar image as a template so AppKit can apply the system's
    /// active/inactive display tint, dark/light appearance, and accessibility
    /// contrast. Flattening this to a permanent white bitmap makes MicShift stay
    /// bright on menu bars belonging to an unfocused display.
    static func menuBarImage(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        let template = image.copy() as? NSImage ?? image
        template.isTemplate = true
        template.accessibilityDescription = image.accessibilityDescription
        return template
    }

    private static func microphone(
        battery: TransmitterBatteryBand,
        indicator: Indicator,
        accessibilityLabel: String
    ) -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            // This is a mask source, so draw with pure opaque black rather than
            // the partially transparent semantic label color.
            NSColor.black.set()

            let capsuleRect = NSRect(x: 5, y: 5.5, width: 8, height: 10.5)
            let capsule = NSBezierPath(roundedRect: capsuleRect, xRadius: 4, yRadius: 4)

            NSGraphicsContext.saveGraphicsState()
            capsule.addClip()
            NSRect(
                x: capsuleRect.minX,
                y: capsuleRect.minY,
                width: capsuleRect.width,
                height: capsuleRect.height * battery.fillFraction
            ).fill()
            NSGraphicsContext.restoreGraphicsState()

            capsule.lineWidth = 1.35
            capsule.stroke()

            let cradle = NSBezierPath()
            cradle.lineWidth = 1.55
            cradle.lineCapStyle = .round
            cradle.move(to: NSPoint(x: 3.25, y: 10))
            cradle.curve(
                to: NSPoint(x: 9, y: 3.4),
                controlPoint1: NSPoint(x: 3.25, y: 5.9),
                controlPoint2: NSPoint(x: 5.8, y: 3.4)
            )
            cradle.curve(
                to: NSPoint(x: 14.75, y: 10),
                controlPoint1: NSPoint(x: 12.2, y: 3.4),
                controlPoint2: NSPoint(x: 14.75, y: 5.9)
            )
            cradle.stroke()

            let stand = NSBezierPath()
            stand.lineWidth = 1.55
            stand.lineCapStyle = .round
            stand.move(to: NSPoint(x: 9, y: 3.4))
            stand.line(to: NSPoint(x: 9, y: 1.25))
            stand.move(to: NSPoint(x: 6.4, y: 1.25))
            stand.line(to: NSPoint(x: 11.6, y: 1.25))
            stand.stroke()

            switch indicator {
            case .none:
                break
            case .offline:
                let offlineBar = NSBezierPath()
                offlineBar.lineWidth = 1.55
                offlineBar.lineCapStyle = .round
                // Keep the 45-degree slash centered on the capsule and fully
                // inside its rounded boundary. It should never dip into the
                // cradle or read as a second microphone stroke.
                offlineBar.move(to: NSPoint(x: 6.25, y: 8.0))
                offlineBar.line(to: NSPoint(x: 11.75, y: 13.5))
                offlineBar.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel
        return image
    }
}
