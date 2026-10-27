import XCTest

final class CameraInteractionTests: XCTestCase {
    func testQuickExposureAndRAWFormatsWithoutCapturing() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-ui-test-raw-support"];app.launch()
        app.buttons["camera.quickSettings"].tap()
        let exposure=app.sliders["camera.exposureBias"],reset=app.buttons["camera.resetExposureBias"]
        XCTAssertTrue(exposure.waitForExistence(timeout:3))
        exposure.adjust(toNormalizedSliderPosition:0.75)
        XCTAssertGreaterThan(Double(reset.value as? String ?? "0") ?? 0,0.5)
        capture(app,"quick-exposure")
        app.buttons["camera.quickSettings"].tap()
        let headerEV=app.buttons["camera.headerExposureBias"]
        XCTAssertTrue(headerEV.waitForExistence(timeout:3),"EV disappeared when quick settings closed")
        XCTAssertGreaterThan(Double(headerEV.value as? String ?? "0") ?? 0,0.5)
        headerEV.tap();XCTAssertFalse(headerEV.exists)
        app.buttons["camera.quickSettings"].tap()
        XCTAssertEqual(reset.value as? String,"0.0")
        let format=app.buttons["camera.quickFormat"]
        XCTAssertTrue(format.isEnabled)
        XCTAssertEqual(format.value as? String,"JPEG")
        format.tap();XCTAssertEqual(format.value as? String,"RAW+")
        format.tap();XCTAssertEqual(format.value as? String,"JPEG")
        revealMode(app,"camera.mode.night").tap()
        XCTAssertTrue(format.isEnabled,"Stack flag disabled the night RAW control")
        if format.value as? String != "JPEG" { format.tap() }
        format.tap();XCTAssertEqual(format.value as? String,"RAW*")
        XCTAssertTrue(app.staticTexts["Noche · RAW Metal"].exists)
        capture(app,"quick-night-raw")
        format.tap();XCTAssertEqual(format.value as? String,"JPEG")
        revealMode(app,"camera.mode.hdr").tap()
        XCTAssertTrue(format.isEnabled)
        if format.value as? String != "JPEG" { format.tap() }
        format.tap();XCTAssertEqual(format.value as? String,"RAW*")
        XCTAssertTrue(app.staticTexts["HDR · RAW Metal"].exists)
        format.tap();XCTAssertEqual(format.value as? String,"JPEG")
        revealMode(app,"camera.mode.stack").tap()
        XCTAssertFalse(format.isEnabled,"Normal JPEG stack incorrectly enabled single-photo RAW")
        revealMode(app,"camera.mode.photo").tap()
        XCTAssertTrue(format.isEnabled)
    }

    func testNativeNightStaysInsideUltimateCAMWithoutCapturing() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        let windows=app.windows.count
        revealMode(app,"camera.mode.nativeNight").tap()
        // Simulator has no native camera capability; dismiss the compatibility
        // explanation, without faking hardware support or pressing a shutter.
        let accept=app.alerts.buttons["Aceptar"]
        if accept.waitForExistence(timeout:2) { accept.tap() }
        XCTAssertTrue(app.staticTexts["Noche · iOS"].waitForExistence(timeout:3))
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertEqual(app.windows.count,windows)
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
        app.buttons["camera.quickSettings"].tap()
        XCTAssertEqual(app.buttons["camera.quickFormat"].value as? String,"JPEG · iOS")
        XCTAssertFalse(app.buttons["camera.quickFormat"].isEnabled)
        revealMode(app,"camera.mode.photo").tap()
        XCTAssertTrue(app.staticTexts["Cámara"].exists)
    }

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
        let transition=app.descendants(matching:.any).matching(identifier:"camera.modeTransition").firstMatch
        XCTAssertTrue(transition.waitForNonExistence(timeout:5),"Video transition did not complete")
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
        XCTAssertTrue(transition.waitForNonExistence(timeout:5),"Photo transition did not complete")
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
        XCTAssertTrue(app.sliders["Exposici\u{00f3}n"].exists)
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
    func testAstroPreferenceWithoutCapturing() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.buttons["camera.settings"].tap()
        app.buttons["settings.night"].tap()
        let astro=app.switches["night.astro"]
        XCTAssertTrue(astro.waitForExistence(timeout:3))
        setSwitch(astro,to:"0");setSwitch(astro,to:"1")
        XCTAssertTrue(app.buttons["Listo"].exists)
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
    }
    func testAdvancedHasOnlyTechnicalPanels() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.buttons["camera.settings"].tap()
        let advanced=app.buttons["settings.advanced"]
        for _ in 0..<7 { if advanced.isHittable { break };app.swipeUp() }
        XCTAssertTrue(advanced.isHittable);advanced.tap()
        XCTAssertTrue(app.navigationBars["Avanzado"].waitForExistence(timeout:3))
        let tabs=app.scrollViews["settings.tabs"]
        XCTAssertEqual(tabs.buttons.count,3)
        XCTAssertFalse(tabs.buttons["settings.tab.Color"].exists)
        XCTAssertFalse(tabs.buttons["settings.tab.Perfiles"].exists)
        for title in ["Manual","Fusi\u{00f3}n","Detalle"] {
            tabs.buttons["settings.tab."+title].tap()
            XCTAssertFalse(app.switches["capture.hardwareButtons"].isHittable)
            XCTAssertFalse(app.switches["capture.mirrorSelfies"].isHittable)
            XCTAssertFalse(app.switches["output.preserveHDR"].isHittable)
        }
        capture(app,"settings-advanced")
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
