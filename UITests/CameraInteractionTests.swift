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
        app.buttons["camera.quickSettings"].tap()
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
        XCTAssertTrue(app.buttons["processing.systemQuality"].waitForExistence(timeout:3))
        app.buttons["processing.systemQuality"].tap()
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
        let hdrOutput = app.switches["output.preserveHDR"]
        for _ in 0..<8 {
            if hdrOutput.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(hdrOutput.isHittable)
        // SwiftUI exposes the whole label row as a switch. Its center is text;
        // tap the visible trailing thumb rather than the row's midpoint.
        hdrOutput.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        XCTAssertTrue(NSPredicate(format:"value == %@","1").evaluate(with:hdrOutput))
        let outputScreen = XCTAttachment(screenshot:app.screenshot())
        outputScreen.name="Adaptive HDR output and PNG LUT import";outputScreen.lifetime = .keepAlways;add(outputScreen)
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
        app.buttons["camera.settings"].tap()
        app.scrollViews["settings.tabs"].swipeLeft()
        app.buttons["settings.tab.Color"].tap()
        app.segmentedControls.buttons["HSL"].tap()
        XCTAssertTrue(app.sliders["Matiz (°)"].waitForExistence(timeout:3))
        app.buttons["Naranja"].tap()
        let hue = app.sliders["Matiz (°)"]
        XCTAssertTrue(hue.waitForExistence(timeout:3))
        hue.adjust(toNormalizedSliderPosition:0.6)
        app.segmentedControls.buttons["Curvas"].tap()
        XCTAssertTrue(app.sliders["Negros"].waitForExistence(timeout:3))
        app.segmentedControls.buttons["Ruedas"].tap()
        XCTAssertTrue(app.sliders["Balance de zonas"].waitForExistence(timeout:3))
        let wheels = XCTAttachment(screenshot:app.screenshot())
        wheels.name="Color grading wheels";wheels.lifetime = .keepAlways;add(wheels)
        app.segmentedControls.buttons["Efectos"].tap()
        XCTAssertTrue(app.sliders["Grano"].waitForExistence(timeout:3))
        app.buttons["Listo"].tap()
        let hdr = app.buttons["camera.mode.hdr"]
        XCTAssertTrue(hdr.isHittable)
        hdr.tap()
        XCTAssertTrue(app.staticTexts["HDR · 3 exposiciones"].waitForExistence(timeout:3))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
        XCTAssertTrue(app.buttons["camera.gallery"].isHittable)
        app.buttons["camera.gallery"].tap()
        XCTAssertTrue(app.buttons["Importar desde Fotos"].waitForExistence(timeout:3))
    }
}
