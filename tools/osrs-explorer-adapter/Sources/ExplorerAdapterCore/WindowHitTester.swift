import CoreGraphics
import Foundation

public struct WindowHitTestEntry: Equatable, Sendable {
    public let processIdentifier: Int32
    public let layer: Int
    public let alpha: Double
    public let bounds: AdapterRect

    public init(
        processIdentifier: Int32,
        layer: Int,
        alpha: Double,
        bounds: AdapterRect
    ) {
        self.processIdentifier = processIdentifier
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

public enum WindowHitTester {
    public static func topmostProcessIdentifier(at point: CGPoint) -> Int32? {
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }
        let entries = rows.compactMap(entry(from:))
        return topmostProcessIdentifier(
            at: AdapterPoint(x: point.x, y: point.y),
            entries: entries
        )
    }

    public static func topmostProcessIdentifier(
        at point: AdapterPoint,
        entries: [WindowHitTestEntry]
    ) -> Int32? {
        entries.first { entry in
            entry.layer == 0
                && entry.alpha > 0
                && entry.bounds.cgRect.contains(CGPoint(x: point.x, y: point.y))
        }?.processIdentifier
    }

    private static func entry(from row: [String: Any]) -> WindowHitTestEntry? {
        guard let processIdentifier = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let rawBounds = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds) else {
            return nil
        }
        let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return WindowHitTestEntry(
            processIdentifier: processIdentifier,
            layer: layer,
            alpha: alpha,
            bounds: AdapterRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            )
        )
    }
}
