import CoreGraphics
import Foundation

private func assertPoint(
    _ label: String,
    input: CGPoint,
    expected: CGPoint
) {
    let actual = StreamCoordinateSpace.point(input)
    guard actual == expected else {
        fatalError("\(label): got \(actual), expected \(expected)")
    }
}

@main
private enum StreamCoordinateSpaceTests {
    static func main() {
        // The three physical placements share a portrait-shaped visible stream.
        // Because physical orientation is not part of the mapping, none may
        // rotate or mirror the supplied point.
        for placement in ["portrait", "landscape-left", "landscape-right"] {
            assertPoint(
                "portrait stream, phone \(placement)",
                input: CGPoint(x: 342, y: 611),
                expected: CGPoint(x: 342, y: 611)
            )
        }

        // A genuinely landscape-rendered stream supplies landscape-space points
        // directly. Those coordinates must remain direct as well.
        assertPoint(
            "true landscape stream",
            input: CGPoint(x: 611, y: 342),
            expected: CGPoint(x: 611, y: 342)
        )

        // Exercise the scalar overload used by RPC handlers.
        let scalar = StreamCoordinateSpace.point(x: 17, y: 649)
        guard scalar == CGPoint(x: 17, y: 649) else {
            fatalError("scalar overload rotated or mirrored the point: \(scalar)")
        }

        print("stream coordinate-space tests passed")
    }
}
