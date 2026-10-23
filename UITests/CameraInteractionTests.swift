import XCTest

final class CameraInteractionTests: XCTestCase {
    func testViewfinderAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let viewfinder = app.descendants(matching: .any).matching(identifier: "camera.viewfinder").firstMatch
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 10))
        XCTAssertTrue(viewfinder.isHittable)
        let point = viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        point.tap()
        point.press(forDuration: 0.8)
        let settings = app.buttons["camera.settings"]
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Ajustes"].waitForExistence(timeout: 3))
        app.buttons["Procesado"].tap()
        XCTAssertTrue(app.buttons["Luz baja"].waitForExistence(timeout: 3))
        app.buttons["Luz baja"].tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Pila de 7 · Luz baja"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
    }
}
