import CoreGraphics
import Foundation

public enum CoordinateTransform {
    public static func screenPoint(
        imagePoint: AdapterPoint,
        pixelWidth: Int,
        pixelHeight: Int,
        windowFrame: AdapterRect
    ) throws -> CGPoint {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AdapterError.actionNotAllowed("INVALID_CAPTURE_GEOMETRY")
        }
        guard imagePoint.x >= 0,
              imagePoint.y >= 0,
              imagePoint.x < Double(pixelWidth),
              imagePoint.y < Double(pixelHeight) else {
            throw AdapterError.actionNotAllowed("POINT_OUTSIDE_CAPTURE")
        }
        return CGPoint(
            x: windowFrame.x + (imagePoint.x / Double(pixelWidth)) * windowFrame.width,
            y: windowFrame.y + (imagePoint.y / Double(pixelHeight)) * windowFrame.height
        )
    }
}

public enum WorldMapControlGeometry {
    private static let reviewedFrameWidth = 768.0
    private static let reviewedFrameHeight = 839.0
    private static let reviewedClickPoint = AdapterPoint(x: 707, y: 169)

    public static func sourcePoint(pixelWidth: Int, pixelHeight: Int) throws -> AdapterPoint {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AdapterError.actionNotAllowed("INVALID_CAPTURE_GEOMETRY")
        }
        return AdapterPoint(
            x: reviewedClickPoint.x * Double(pixelWidth) / reviewedFrameWidth,
            y: reviewedClickPoint.y * Double(pixelHeight) / reviewedFrameHeight
        )
    }
}
