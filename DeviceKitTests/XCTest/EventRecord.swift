import Foundation
import UIKit

@objc
final class EventRecord: NSObject {
    let eventRecord: NSObject

    static let defaultTapDuration = 0.1

    /// Short enough to make ordinary remote taps responsive while remaining
    /// above the lowest plateau measured reliably on physical iPhones.
    static let remoteTapDuration = 0.01

    /// A short stationary endpoint avoids turning a bounded remote scroll into
    /// a zero-dwell fling while still removing 80 ms of the old 100 ms dwell.
    static let remoteSwipeReleaseDwell = 0.02

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
        // for another 100 ms. Keep a bounded 20 ms release dwell so scrolling
        // settles predictably without paying the old full dwell.
        path.offset += duration
        path.moveTo(point: end)
        path.offset += Self.remoteSwipeReleaseDwell
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
