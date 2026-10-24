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
        XCTAssertTrue(app.buttons["Noche estática"].waitForExistence(timeout: 3))
        app.buttons["Noche estática"].tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Noche estática · JPEG"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
        app.buttons["camera.settings"].tap()
        let tabs = app.scrollViews["settings.tabs"]
        tabs.swipeLeft()
        app.buttons["settings.tab.Color"].tap()
        XCTAssertTrue(app.staticTexts["Exposición del JPEG (EV)"].waitForExistence(timeout: 3))
        let colorScreen = XCTAttachment(screenshot: app.screenshot())
        colorScreen.name = "Color controls"; colorScreen.lifetime = .keepAlways; add(colorScreen)
        let profiles = app.buttons["settings.tab.Perfiles"]
        XCTAssertTrue(profiles.waitForExistence(timeout: 3))
        profiles.tap()
        let name = app.textFields["profile.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("UI test profile")
        app.buttons["Guardar perfil actual"].tap()
        XCTAssertTrue(app.buttons["UI test profile"].waitForExistence(timeout: 3))
        let profileScreen = XCTAttachment(screenshot: app.screenshot())
        profileScreen.name = "Saved processing profile"; profileScreen.lifetime = .keepAlways; add(profileScreen)
        app.buttons["UI test profile"].tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Noche estática · JPEG"].waitForExistence(timeout: 3))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
    }
}
