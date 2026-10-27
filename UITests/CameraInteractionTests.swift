import XCTest

final class CameraInteractionTests: XCTestCase {
    func testGuidedModesAndPreviewToolsWithoutTakingPhotos() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.buttons["camera.previewTools"].tap()
        XCTAssertTrue(app.buttons["Histograma del visor"].waitForExistence(timeout:3))
        app.buttons["Histograma del visor"].tap()
        // Menu selection dismisses the menu; reopen to inspect the other tools.
        app.buttons["camera.previewTools"].tap()
        XCTAssertTrue(app.buttons["Resaltar enfoque"].exists)
        XCTAssertTrue(app.buttons["Cebras de luces"].exists)
        app.buttons["Resaltar enfoque"].tap()
        for (mode,close,capture) in [("panorama","panorama.close","panorama.capture"),("sphere","sphere.close","sphere.capture")] {
            let button=revealMode(app,"camera.mode."+mode)
            XCTAssertTrue(button.isHittable);button.tap()
            XCTAssertTrue(app.buttons[close].waitForExistence(timeout:8))
            XCTAssertTrue(app.buttons[capture].exists)
            XCTAssertEqual(app.buttons[capture].frame.midX,app.frame.midX,accuracy:2,"Guided shutter must stay centered regardless of the side labels")
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Guided "+mode;image.lifetime = .keepAlways;add(image)
            // No shutter, motion service simulation or photo-library write.
            app.buttons[close].tap()
            XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout:5))
        }
    }
    func testVideoStaysInCameraWindowWithoutRecording() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        let windows=app.windows.count
        let finder=app.descendants(matching:.any).matching(identifier:"camera.viewfinder").firstMatch
        XCTAssertTrue(finder.waitForExistence(timeout:10))
        let originalFrame=finder.frame
        revealMode(app,"camera.mode.video").tap()
        XCTAssertTrue(app.buttons["video.record"].waitForExistence(timeout:8))
        XCTAssertTrue(app.buttons["video.quickResolution"].exists)
        XCTAssertTrue(app.buttons["video.quickFPS"].exists)
        XCTAssertTrue(app.scrollViews["camera.modes"].exists)
        XCTAssertEqual(app.windows.count,windows,"Video must use the existing window")
        XCTAssertFalse(app.buttons["video.close"].exists,"Video must not be a separate presented camera")
        XCTAssertEqual(finder.frame,originalFrame,"Persistent viewfinder geometry changed")
        capture(app,"video")
        app.buttons["camera.settings"].tap()
        XCTAssertTrue(app.navigationBars["Ajustes"].waitForExistence(timeout:3))
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"video.resolution").firstMatch.exists)
        capture(app,"settings-video")
        app.buttons["Listo"].tap()
        revealMode(app,"camera.mode.photo").tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["video.record"].exists)
        XCTAssertEqual(app.windows.count,windows)
    }
    func testViewfinderAndCleanSettings() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        let finder=app.descendants(matching:.any).matching(identifier:"camera.viewfinder").firstMatch
        XCTAssertTrue(finder.waitForExistence(timeout:10))
        XCTAssertEqual(finder.frame.width,app.frame.width,accuracy:2)
        XCTAssertEqual(finder.frame.height,app.frame.height,accuracy:2)
        let point=finder.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.45))
        point.tap();point.press(forDuration:0.8)
        app.buttons["camera.settings"].tap()
        XCTAssertTrue(app.navigationBars["Ajustes"].waitForExistence(timeout:3))
        XCTAssertTrue(app.buttons["settings.night"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","shader")).firstMatch.exists)
        capture(app,"settings-top")
        let color=app.buttons["settings.color"]
        for _ in 0..<5 { if color.isHittable { break };app.swipeUp() }
        XCTAssertTrue(color.isHittable)
        color.tap()
        XCTAssertTrue(app.navigationBars["Color y estilo"].waitForExistence(timeout:3))
        XCTAssertTrue(app.sliders["Exposici\u{00f3}n del JPEG (EV)"].exists)
        capture(app,"settings-color")
        app.navigationBars.buttons.element(boundBy:0).tap()
        let mirror=app.switches["capture.mirrorSelfies"],hardware=app.switches["capture.hardwareButtons"]
        for _ in 0..<6 { if mirror.isHittable && hardware.isHittable { break };app.swipeUp() }
        XCTAssertTrue(mirror.isHittable && hardware.isHittable)
        setSwitch(mirror,to:"1");setSwitch(hardware,to:"0")
        capture(app,"settings-bottom")
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
    }
    private func revealMode(_ app:XCUIApplication,_ identifier:String) -> XCUIElement {
        let button=app.buttons[identifier],modes=app.scrollViews["camera.modes"]
        if !button.isHittable { modes.swipeRight() }
        for _ in 0..<4 { if button.isHittable { break };modes.swipeLeft() }
        return button
    }
    private func setSwitch(_ control:XCUIElement,to value:String) {
        XCTAssertTrue(control.isHittable)
        if (control.value as? String) != value { control.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() }
        XCTAssertTrue(NSPredicate(format:"value == %@",value).evaluate(with:control))
    }
}
