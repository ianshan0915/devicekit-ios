import XCTest

struct OrientationGeometry {
    private static var cachedSize: (Float, Float)?
    private static var lastAppBundleId: String?
    private static var lastOrientation: UIDeviceOrientation?

    static func physicalScreenSize() -> (Float, Float) {
        let springboardBundleId = "com.apple.springboard"

        let app =
            RunningApp.getForegroundApp()
            ?? XCUIApplication(bundleIdentifier: springboardBundleId)

        do {
            let currentAppBundleId = app.bundleID
            let currentOrientation = XCUIDevice.shared.orientation

            if let cached = cachedSize,
                currentAppBundleId == lastAppBundleId,
                currentOrientation == lastOrientation
            {
                NSLog("Returning cached screen size")
                return cached
            }

            let dict = try app.snapshot().dictionaryRepresentation
            let axFrame = AXElement(dict).frame

            guard let width = axFrame["Width"], let height = axFrame["Height"]
            else {
                NSLog("Frame keys missing, falling back to SpringBoard.")
                let springboard = XCUIApplication(
                    bundleIdentifier: springboardBundleId
                )
                let size = springboard.frame.size
                return (Float(size.width), Float(size.height))
            }

            let screenSize = CGSize(width: width, height: height)
            let size = (Float(screenSize.width), Float(screenSize.height))

            cachedSize = size
            lastAppBundleId = currentAppBundleId
            lastOrientation = currentOrientation

            return size
        } catch let error {
            NSLog(
                "Failure while getting screen size: \(error), falling back to get springboard size."
            )
            let application = XCUIApplication(
                bundleIdentifier: springboardBundleId
            )
            let screenSize = application.frame.size
            return (Float(screenSize.width), Float(screenSize.height))
        }
    }

}
