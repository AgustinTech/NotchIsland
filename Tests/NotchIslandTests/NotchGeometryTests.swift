import AppKit
import XCTest
@testable import NotchIsland

final class NotchGeometryTests: XCTestCase {
    func testBuiltInNotchTakesPriorityOverExternalScreenUnderPointer() {
        let external = ScreenInfo(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let builtIn = ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 37,
            auxLeftWidth: 624,
            auxRightWidth: 624
        )

        let geometry = NotchGeometry.make(
            screens: [external, builtIn],
            mouse: CGPoint(x: 2000, y: 900),
            mainIndex: 0
        )

        XCTAssertEqual(geometry.screenFrame, builtIn.frame)
        XCTAssertEqual(geometry.notchSize, CGSize(width: 264, height: 37))
        XCTAssertEqual(geometry.expandedSize, CGSize(width: 520, height: 201))
    }

    func testNoNotchUsesExternalScreenUnderPointer() {
        let main = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let external = ScreenInfo(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

        let geometry = NotchGeometry.make(
            screens: [main, external],
            mouse: CGPoint(x: -500, y: 700),
            mainIndex: 0
        )

        XCTAssertEqual(geometry.screenFrame, external.frame)
        XCTAssertEqual(geometry.notchSize, NotchGeometry.fakeNotch)
        XCTAssertEqual(geometry.expandedSize, CGSize(width: 520, height: 196))
    }

    func testPointerOutsideScreensFallsBackToMainScreen() {
        let first = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let main = ScreenInfo(frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440))

        let geometry = NotchGeometry.make(
            screens: [first, main],
            mouse: CGPoint(x: 9000, y: 9000),
            mainIndex: 1
        )

        XCTAssertEqual(geometry.screenFrame, main.frame)
        XCTAssertEqual(geometry.notchSize, NotchGeometry.fakeNotch)
    }
}
