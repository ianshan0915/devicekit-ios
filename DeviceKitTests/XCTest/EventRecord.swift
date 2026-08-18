import Foundation
import UIKit

@objc
final class EventRecord: NSObject {
    let eventRecord: NSObject

    static let defaultTapDuration = 0.1

    /// Short enough to make ordinary remote taps responsive while remaining
    /// above the lowest plateau measured reliably on physical iPhones. Swipe
    /// and gesture timing intentionally keep `defaultTapDuration`.
    static let remoteTapDuration = 0.01

    enum Style: String {
        case singleFinger = "Single-Finger Touch Action"
        case multiFinger = "Multi-Finger Touch Action"
    }

    init(orientation: UIInterfaceOrientation, style: Style = .singleFinger) {
        eventRecord =
            objc_lookUpClass("XCSynthesizedEventRecord")?.alloc()
            .perform(
                NSSelectorFromString("initWithName:interfaceOrientation:"),
                with: style.rawValue,
                with: orientation
            )
            .takeUnretainedValue() as! NSObject
    }

    func addPointerTouchEvent(at point: CGPoint, touchUpAfter: TimeInterval?)
        -> Self
    {
        var path = PointerEventPath.pathForTouch(at: point)
        path.offset += touchUpAfter ?? Self.defaultTapDuration
        path.liftUp()
        return add(path)
    }

    func addSwipeEvent(start: CGPoint, end: CGPoint, duration: TimeInterval) -> Self {
        var path = PointerEventPath.pathForTouch(at: start)
        // The endpoint timestamp defines the swipe's motion duration. The old
        // shape moved for defaultTapDuration (100 ms), then added `duration`
        // again before lift-up, leaving the finger stationary at the endpoint
        // for another 100 ms. That doubled an ordinary 100 ms swipe and delayed
        // XCTest completion without improving its trajectory.
        path.offset += duration
        path.moveTo(point: end)
        path.liftUp()
        return add(path)
    }

    func add(_ path: PointerEventPath) -> Self {
        let selector = NSSelectorFromString("addPointerEventPath:")
        let imp = eventRecord.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, NSObject) -> Void
        let method = unsafeBitCast(imp, to: Method.self)
        method(eventRecord, selector, path.path)
        return self
    }
}
