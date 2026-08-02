import CoreGraphics

/// Resolves input points expressed in the same coordinate space as the visible
/// `/h264` frame.
///
/// Physical device orientation is intentionally not an input. XCTest's pointer
/// records already consume screen points. Rotating those points a second time
/// makes taps miss whenever a phone is physically sideways while SpringBoard
/// (and therefore the stream) remains portrait-shaped.
enum StreamCoordinateSpace {
    static func point(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }

    static func point(_ point: CGPoint) -> CGPoint {
        point
    }
}
