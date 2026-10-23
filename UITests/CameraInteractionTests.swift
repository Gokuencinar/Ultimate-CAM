import XCTest

final class CameraInteractionTests: XCTestCase {
    func testViewfinderAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let viewfinder = app.descendants(matching: .any).matching(identifier: "camera.viewfinder").firstMatch
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 10))
        XCTAssertTrue(viewfinder.isHittable)
        XCTAssertEqual(viewfinder.frame.width, app.frame.width, accuracy: 2)
        XCTAssertEqual(viewfinder.frame.height, app.frame.height, accuracy: 2)
        let point = viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        point.tap()
        point.press(forDuration: 0.8)
        app.buttons["Temporizador OFF"].tap()
        XCTAssertTrue(app.buttons["Temporizador 3s"].exists)
        app.buttons["Temporizador 3s"].tap()
        XCTAssertTrue(app.buttons["Temporizador 10s"].exists)
        app.buttons["Temporizador 10s"].tap()
        XCTAssertTrue(app.buttons["Temporizador OFF"].exists)
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
