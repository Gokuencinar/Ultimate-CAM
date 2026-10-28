import XCTest

final class CameraInteractionTests: XCTestCase {
    func testQuickExposureAndRAWFormatsWithoutCapturing() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-ui-test-raw-support"];app.launch()
        app.buttons["camera.quickSettings"].tap()
        let shadows=app.sliders["camera.shadowLift"]
        XCTAssertTrue(shadows.waitForExistence(timeout:3));shadows.adjust(toNormalizedSliderPosition:0.7)
        app.buttons["camera.quickSettings"].tap()
        XCTAssertTrue(app.buttons["camera.headerShadows"].waitForExistence(timeout:3))
        XCTAssertEqual(app.buttons["camera.previewTools"].value as? String,"Activo")
        app.buttons["camera.headerShadows"].tap()
        XCTAssertTrue(app.buttons["camera.headerShadows"].waitForNonExistence(timeout:3))
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

    func testUnifiedNightHasNoSeparateIOSMode() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-ui-test-raw-support"];app.launch()
        let windows=app.windows.count
        XCTAssertFalse(app.buttons["camera.mode.nativeNight"].exists)
        revealMode(app,"camera.mode.night").tap()
        app.buttons["camera.quickSettings"].tap()
        let format=app.buttons["camera.quickFormat"]
        if format.value as? String != "RAW*" { format.tap() }
        XCTAssertEqual(format.value as? String,"RAW*")
        XCTAssertTrue(app.staticTexts["Noche · RAW Metal"].exists)
        app.buttons["camera.quickSettings"].tap()
        app.buttons["camera.settings"].tap();app.buttons["settings.night"].tap()
        let raw=app.switches["night.computationalRAW"]
        XCTAssertTrue(raw.waitForExistence(timeout:3));setSwitch(raw,to:"0");setSwitch(raw,to:"1")
        XCTAssertFalse(app.buttons["processing.nativeNight"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap();app.buttons["Listo"].tap()
        XCTAssertEqual(app.windows.count,windows);XCTAssertTrue(app.buttons["camera.shutter"].exists)
        XCTAssertFalse(app.buttons["camera.mode.nativeNight"].exists)
        capture(app,"unified-night")
        revealMode(app,"camera.mode.photo").tap();XCTAssertTrue(app.staticTexts["Cámara"].exists)
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
        let finder=app.descendants(matching:.any).matching(identifier:"camera.viewfinder").firstMatch
        let originalFrame=finder.frame,windows=app.windows.count
        for mode in ["panorama","sphere","panorama"] {
            let button=revealMode(app,"camera.mode."+mode)
            XCTAssertTrue(button.isHittable);button.tap()
            XCTAssertTrue(app.buttons[mode+".capture"].waitForExistence(timeout:8))
            let transition=app.descendants(matching:.any).matching(identifier:"camera.modeTransition").firstMatch
            XCTAssertTrue(transition.waitForNonExistence(timeout:5))
            XCTAssertTrue(app.scrollViews["camera.modes"].isHittable,"Guided modes must keep the common carousel")
            XCTAssertEqual(app.windows.count,windows)
            XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"camera.viewfinder").count,1,"Guided mode created another visor")
            XCTAssertEqual(finder.frame,originalFrame,"Guided mode changed the persistent viewfinder geometry")
            XCTAssertFalse(app.buttons[mode+".close"].exists,"Guided mode must not present a separate camera")
            if mode=="panorama" {
                XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"panorama.sweepGuide").firstMatch.exists)
                XCTAssertEqual(app.buttons["panorama.capture"].label,"Iniciar barrido panorámico")
                XCTAssertFalse(app.buttons["panorama.merge"].isEnabled)
            }
            if mode=="sphere" {
                let automatic=app.switches["sphere.autoCapture"]
                XCTAssertTrue(automatic.isHittable);setSwitch(automatic,to:"1");setSwitch(automatic,to:"0")
                XCTAssertFalse(app.buttons["sphere.merge"].isEnabled)
            }
            if mode=="sphere",app.buttons["sphere.retryMotion"].exists {
                app.buttons["sphere.retryMotion"].tap();XCTAssertEqual(app.state,.runningForeground)
            }
            XCTAssertEqual(app.buttons[mode+".capture"].frame.midX,app.frame.midX,accuracy:2)
        }
        revealMode(app,"camera.mode.video").tap()
        XCTAssertTrue(app.buttons["video.record"].waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["panorama.capture"].exists)
        let finalTransition=app.descendants(matching:.any).matching(identifier:"camera.modeTransition").firstMatch
        XCTAssertTrue(finalTransition.waitForNonExistence(timeout:5))
        revealMode(app,"camera.mode.photo").tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout:8))
        XCTAssertEqual(app.windows.count,windows)
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
        let videoEV=app.sliders["camera.exposureBias"]
        XCTAssertTrue(videoEV.isHittable);videoEV.adjust(toNormalizedSliderPosition:0.75)
        XCTAssertNotEqual(app.buttons["camera.resetExposureBias"].value as? String,"0.0")
        app.buttons["camera.resetExposureBias"].tap()
        app.buttons["video.quickResolution"].tap()
        XCTAssertTrue(app.buttons["720p"].waitForExistence(timeout:3));app.buttons["720p"].tap()
        XCTAssertTrue(transition.waitForNonExistence(timeout:5))
        XCTAssertTrue(app.buttons["video.record"].exists)
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
        for _ in 0..<2 {
            revealMode(app,"camera.mode.video").tap()
            XCTAssertTrue(app.buttons["video.record"].waitForExistence(timeout:8))
            XCTAssertTrue(transition.waitForNonExistence(timeout:5))
            revealMode(app,"camera.mode.photo").tap()
            XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout:8))
            XCTAssertTrue(transition.waitForNonExistence(timeout:5))
            XCTAssertEqual(finder.frame,originalFrame)
            XCTAssertEqual(app.state,.runningForeground)
        }
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
        XCTAssertTrue(app.navigationBars["Modo Noche"].waitForExistence(timeout:3))
        let astro=app.switches["night.astro"]
        XCTAssertTrue(astro.waitForExistence(timeout:3))
        setSwitch(astro,to:"0");setSwitch(astro,to:"1")
        XCTAssertTrue(app.navigationBars["Modo Noche"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
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
