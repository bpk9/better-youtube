import XCTest

final class BetterYouTubeUITests: XCTestCase {
    @MainActor func testFollowingFeedFailureOffersRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--subscription-permission-test"]
        app.launch()
        app.buttons["tab-Following"].tap()
        XCTAssertTrue(app.staticTexts["Reconnect Google from the account screen to load your subscriptions."].waitForExistence(timeout: 10))
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Reconnect Google from the account screen to load your subscriptions."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Couldn’t load recent uploads. Pull to refresh when you’re online."].exists)
    }

    @MainActor func testWebScrubberSeeksInlineAndFullscreen() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=kRQF9xii9cc\n")
        let status = app.staticTexts["playbackStatus"]
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 35)
        app.buttons["videoSurface"].tap()
        app.buttons["videoOverlayPlayPause"].tap()
        let scrubber = app.sliders["videoScrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let inlineHeight = app.buttons["videoSurface"].frame.height
        scrubber.adjust(toNormalizedSliderPosition: 0.25)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["playbackTime"].label) > 20 }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        let inlineTime = seconds(app.staticTexts["playbackTime"].label)
        XCTAssertEqual(status.label, "Paused", "Scrubbing must preserve paused playback")
        attach(app, "Native slider in collapsed web player")
        app.buttons["Full screen"].tap()
        XCTAssertGreaterThan(app.buttons["videoSurface"].frame.height, inlineHeight * 2)
        XCTAssertTrue(scrubber.isHittable)
        scrubber.adjust(toNormalizedSliderPosition: 0.5)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["fullscreenTime"].label) > inlineTime + 20 }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        attach(app, "Native slider in expanded web player")
        app.buttons["Exit full screen"].tap()
        XCTAssertGreaterThan(seconds(app.staticTexts["playbackTime"].label), inlineTime + 20)
        XCTAssertEqual(status.label, "Paused")
        XCTAssertTrue(scrubber.isHittable)
        app.buttons["videoOverlayPlayPause"].tap()
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }

    @MainActor func testUnsubscribeWithReadOnlyGoogleShowsPermissionPrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--subscription-permission-test"]
        app.launch()
        app.buttons["YouTube account"].tap()
        let unsubscribe = app.buttons["Unsubscribe from Example Channel"]
        XCTAssertTrue(unsubscribe.waitForExistence(timeout: 5))
        unsubscribe.tap()
        let prompt = app.alerts["Allow subscription changes"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "An unsubscribe tap inside the account sheet must not silently do nothing")
        XCTAssertTrue(prompt.buttons["Connect Google"].exists)
        XCTAssertTrue(prompt.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "unsubscribe from Example Channel")).firstMatch.exists)
        prompt.buttons["Cancel"].tap()
        XCTAssertTrue(unsubscribe.exists, "Cancel must leave the subscription unchanged")
        unsubscribe.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "Permission prompting must work on repeated attempts")
    }

    @MainActor func testPlaybackSpeedAndCaptions() throws {
        let app = XCUIApplication(); app.launchArguments = ["--playback-diagnostics"]; app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=kRQF9xii9cc\n")
        let status = app.staticTexts["playbackStatus"]
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 35)
        app.buttons["videoSurface"].tap()
        app.buttons["videoOverlayPlayPause"].tap()
        app.buttons["playbackSettings"].tap(); app.buttons["playbackSpeedMenu"].tap(); app.buttons["2×"].tap()
        XCTAssertEqual(status.label, "Paused", "Changing speed must not resume paused playback")
        app.buttons["videoOverlayPlayPause"].tap()
        let before = seconds(app.staticTexts["playbackTime"].label)
        let interval = expectation(description: "Playback at double speed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { interval.fulfill() }
        wait(for: [interval], timeout: 6)
        XCTAssertGreaterThanOrEqual(seconds(app.staticTexts["playbackTime"].label), before + 6)
        app.buttons["playbackSettings"].tap(); app.buttons["captionsMenu"].tap()
        let captions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English"))
        XCTAssertTrue(captions.firstMatch.waitForExistence(timeout: 8))
        let captionName = captions.firstMatch.label
        captions.firstMatch.tap()
        expectation(for: NSPredicate { _, _ in (app.buttons["playbackSettings"].value as? String ?? "").contains(captionName) }, evaluatedWith: nil)
        waitForExpectations(timeout: 12)
        app.buttons["Forward 15 seconds in video"].tap()
        let captionTime = seconds(app.staticTexts["playbackTime"].label)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["playbackTime"].label) >= captionTime + 5 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        attach(app, "Captions enabled at double speed")
        app.terminate(); app.launch()
        app.buttons["Search"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=kRQF9xii9cc\n")
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 35)
        app.buttons["videoSurface"].tap()
        expectation(for: NSPredicate { _, _ in
            let value = app.buttons["playbackSettings"].value as? String ?? ""
            return value.contains(captionName) && value.contains("2×")
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 12)
        app.buttons["Full screen"].tap()
        app.buttons["playbackSettings"].tap(); app.buttons["captionsMenu"].tap()
        let menuStable = expectation(description: "Captions submenu stays open during progress updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { menuStable.fulfill() }
        wait(for: [menuStable], timeout: 5)
        attach(app, "Caption languages menu in fullscreen")
        app.buttons["Off"].tap()
        expectation(for: NSPredicate { _, _ in (app.buttons["playbackSettings"].value as? String ?? "").contains("Captions Off") }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        attach(app, "Fullscreen captions off")
        app.buttons["playbackSettings"].tap(); app.buttons["playbackSpeedMenu"].tap(); app.buttons["1× (Normal)"].tap()
        app.buttons["Exit full screen"].tap()
        XCTAssertEqual(status.label, "Playing")
    }

    @MainActor func testFullscreenAndAudioControls() throws {
        let app = XCUIApplication(); app.launchArguments = ["--playback-diagnostics"]; app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=kRQF9xii9cc\n")
        let status = app.staticTexts["playbackStatus"]
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 35)
        XCTAssertFalse(app.buttons["playPause"].exists, "No duplicate transport row below the video")
        XCTAssertFalse(app.buttons["Back 15 seconds"].exists)
        app.buttons["videoSurface"].tap()
        XCTAssertTrue(app.buttons["Mute video"].exists)
        app.buttons["Mute video"].tap()
        XCTAssertTrue(app.buttons["Unmute video"].exists)
        app.buttons["Unmute video"].tap()
        let inlineHeight = app.buttons["videoSurface"].frame.height
        let before = seconds(app.staticTexts["playbackTime"].label)
        app.buttons["Full screen"].tap()
        XCTAssertTrue(app.buttons["Exit full screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["tab-Home"].exists)
        XCTAssertFalse(app.buttons["videoActions"].exists)
        XCTAssertGreaterThan(app.buttons["videoSurface"].frame.height, inlineHeight * 2)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["fullscreenTime"].label) >= before + 5 }, evaluatedWith: nil)
        waitForExpectations(timeout: 12)
        attach(app, "Fullscreen portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.buttons["videoSurface"].frame.width > app.buttons["videoSurface"].frame.height }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        let landscapeTime = seconds(app.staticTexts["fullscreenTime"].label)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["fullscreenTime"].label) >= landscapeTime + 3 }, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        attach(app, "Fullscreen landscape")
        app.buttons["Exit full screen"].tap()
        XCTAssertTrue(app.buttons["tab-Home"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(seconds(app.staticTexts["playbackTime"].label), before)
        XCTAssertTrue(status.label == "Playing")
        XCUIDevice.shared.orientation = .portrait
        let portraitTime = seconds(app.staticTexts["playbackTime"].label)
        expectation(for: NSPredicate { _, _ in self.seconds(app.staticTexts["playbackTime"].label) >= portraitTime + 2 }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        attach(app, "Single transport controls inline")
    }

    @MainActor func testNativePlayerFullscreenKeepsPlayback() throws {
        let app = XCUIApplication()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = source.appendingPathComponent("server/state/media/aqz-KE-bpKQ.mp4").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture), "Native playback test requires the local MP4 fixture")
        app.launchEnvironment["BETTER_YOUTUBE_TEST_VIDEO"] = fixture
        app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=aqz-KE-bpKQ\n")
        XCTAssertTrue(app.staticTexts["Downloaded · available offline"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == 'Playing'"), evaluatedWith: app.staticTexts["playbackStatus"])
        waitForExpectations(timeout: 10)
        setNativePlayback(app, playing: false)
        app.buttons["playbackSettings"].tap(); app.buttons["playbackSpeedMenu"].tap(); app.buttons["2×"].tap()
        app.buttons["playbackSettings"].tap(); app.buttons["captionsMenu"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "No captions available for this video")).firstMatch.exists)
        app.buttons["Off"].tap()
        setNativePlayback(app, playing: true)
        let before = seconds(app.staticTexts["playbackTime"].label)
        let wallStart = Date()
        app.buttons["Full screen"].tap()
        XCTAssertTrue(app.buttons["Exit full screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["tab-Home"].exists)
        attach(app, "Native fullscreen")
        let interval = expectation(description: "Playback during native fullscreen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { interval.fulfill() }
        wait(for: [interval], timeout: 8)
        app.buttons["Exit full screen"].tap()
        XCTAssertTrue(app.buttons["tab-Home"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(Double(seconds(app.staticTexts["playbackTime"].label) - before) / Date().timeIntervalSince(wallStart), 1.5, "Native playback must actually run at double speed")
        setNativePlayback(app, playing: false)
        app.buttons["playbackSettings"].tap(); app.buttons["playbackSpeedMenu"].tap(); app.buttons["1× (Normal)"].tap()
        app.buttons["backToFeed"].tap()
    }

    @MainActor func testVideoDetailBackAndSelectedTabReturnToFeed() throws {
        let app = XCUIApplication(); app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["For you"].exists)
        let selectedID = cards.firstMatch.identifier
        for returnControl in ["backToFeed", "tab-Home"] {
            app.buttons[selectedID].tap()
            let back = app.buttons["backToFeed"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertLessThan(back.frame.minX, 70)
            XCTAssertLessThan(back.frame.minY, 180, "Back belongs at the top left")
            XCTAssertFalse(app.staticTexts["Made for your curiosity"].exists)
            XCTAssertFalse(app.staticTexts["Find something worth your time."].exists)
            XCTAssertFalse(app.buttons["For you"].exists)
            XCTAssertFalse(app.staticTexts["Bring your YouTube along"].exists)
            XCTAssertFalse(app.buttons["Close player"].exists)
            XCTAssertFalse(app.buttons["Dismiss player"].exists)
            attach(app, "Video detail with top-left Back")
            app.buttons[returnControl].tap()
            XCTAssertFalse(back.exists)
            XCTAssertFalse(app.staticTexts["playbackStatus"].exists)
            XCTAssertTrue(app.buttons["For you"].exists)
            XCTAssertTrue(app.buttons[selectedID].exists, "Return should preserve the existing feed")
        }
        app.buttons["tab-Library"].tap()
        app.segmentedControls.buttons["History"].tap()
        app.buttons[selectedID].tap()
        XCTAssertTrue(app.buttons["backToFeed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your library"].exists)
        app.buttons["tab-Library"].tap()
        XCTAssertFalse(app.buttons["backToFeed"].exists)
        XCTAssertTrue(app.staticTexts["Your library"].exists)
        attach(app, "Library restored by tapping selected tab")
    }

    @MainActor func testWebPlaybackSurvivesHostAudioSessionInterruption() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--playback-diagnostics", "--simulate-host-audio-interruption"]
        app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=kRQF9xii9cc\n")
        let status = app.staticTexts["playbackStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in
            status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= 8
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 25)
        attach(app, "Web playback after host audio interruption")
    }

    @MainActor func testHomeVideoAutoplayAndSurfaceControls() throws {
        let app = XCUIApplication(); app.launchArguments = ["--playback-diagnostics"]; app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 35))
        for index in 0..<2 {
            let card = cards.element(boundBy: index)
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            card.tap()
            let status = app.staticTexts["playbackStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            expectation(for: NSPredicate(format: "label BEGINSWITH 'Playing'"), evaluatedWith: status)
            waitForExpectations(timeout: 35)
            let startupTime = seconds(app.staticTexts["playbackTime"].label)
            expectation(for: NSPredicate { _, _ in
                status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= startupTime + 12
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 50)
            XCTAssertTrue(app.buttons["videoSurface"].exists, "Exercise the web video surface on live Home videos")
            let before = seconds(app.staticTexts["playbackTime"].label)
            app.buttons["videoSurface"].tap()
            XCTAssertTrue(app.buttons["Pause in video"].waitForExistence(timeout: 3))
            expectation(for: NSPredicate { _, _ in
                status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= before + 5
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            attach(app, "Home playback with controls \(index)")
            app.buttons["Pause in video"].tap()
            expectation(for: NSPredicate(format: "label BEGINSWITH 'Paused'"), evaluatedWith: status)
            waitForExpectations(timeout: 5)
            let unwantedResume = expectation(for: NSPredicate(format: "label BEGINSWITH 'Playing'"), evaluatedWith: status)
            unwantedResume.isInverted = true; wait(for: [unwantedResume], timeout: 5)
            app.buttons["videoSurface"].tap(); app.buttons["videoSurface"].tap()
            XCTAssertTrue(status.label.hasPrefix("Paused"), "Revealing controls must not start a paused video")
            app.buttons["Play in video"].tap()
            let resumeTime = seconds(app.staticTexts["playbackTime"].label)
            expectation(for: NSPredicate { _, _ in
                status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= resumeTime + 4
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 15)
            app.buttons["backToFeed"].tap()
        }
    }

    @MainActor func testAutoplayKeepsAdvancingAfterStartup() throws {
        let app = XCUIApplication(); app.launch()
        for id in ["aqz-KE-bpKQ", "M7lc1UVf-VE"] {
            if !app.textFields["searchField"].exists { app.buttons["Search"].tap() }
            let field = app.textFields["searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
            field.tap(); field.typeText("https://www.youtube.com/watch?v=\(id)\n")
            let status = app.staticTexts["playbackStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            // A single playing event or one advancing second is insufficient:
            // the old implementation could start, then pause during page setup.
            expectation(for: NSPredicate { _, _ in
                status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= 12
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 45)
            let baseline = seconds(app.staticTexts["playbackTime"].label)
            expectation(for: NSPredicate { _, _ in
                status.label.hasPrefix("Playing") && self.seconds(app.staticTexts["playbackTime"].label) >= baseline + 4
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            attach(app, "Sustained automatic playback \(id)")
            if !app.buttons["videoOverlayPlayPause"].exists { app.buttons["videoSurface"].tap() }; app.buttons["videoOverlayPlayPause"].tap()
            expectation(for: NSPredicate(format: "label BEGINSWITH 'Paused'"), evaluatedWith: status)
            waitForExpectations(timeout: 5)
            let restarted = expectation(for: NSPredicate(format: "label BEGINSWITH 'Playing'"), evaluatedWith: status)
            restarted.isInverted = true
            wait(for: [restarted], timeout: 4)
            app.buttons["backToFeed"].tap()
        }
    }

    @MainActor func testGoogleSignInOpensSystemAuthentication() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["YouTube account"].tap()
        let signIn = app.buttons["Sign in with Google"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        try XCTSkipUnless(signIn.isEnabled, "Configure your Google iOS client to run the OAuth integration test")
        signIn.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = system.buttons["Continue"]
        if permission.waitForExistence(timeout: 5) { permission.tap() }
        let email = app.webViews.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 25), "Google should show its account sign-in page in the system authentication browser")
        attach(app, "Google system authentication")
        XCTAssertFalse(app.webViews.staticTexts["Access blocked"].exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["accountConnectionStatus"].label, "Not connected to Google", "Canceling Google sign-in must not authenticate the account")
    }

    @MainActor func testHomeLoadsDiscoveryAndAccountIsVisible() throws {
        let app = XCUIApplication(); app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Home must show real videos even when YouTube returns an empty signed-out feed")
        attach(app, "Home discovery")
        app.buttons["YouTube account"].tap()
        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open Google in browser"].exists)
        XCTAssertEqual(app.buttons["Sign in with Google"].isEnabled, !app.staticTexts["signInSetupRequired"].exists)
        XCTAssertFalse(app.staticTexts["preferredAccount"].exists)
        XCTAssertEqual(app.staticTexts["accountConnectionStatus"].label, "Not connected to Google")
        attach(app, "Account connection")
        app.buttons["Done"].tap()
    }

    @MainActor func testFollowingSignedOutDoesNotLoadSubscriptions() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["tab-Following"].tap()
        let prompt = app.staticTexts["Please sign in"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 2), "Signed-out Following must immediately ask for sign-in")
        XCTAssertTrue(app.buttons["followingSignIn"].exists)
        XCTAssertFalse(app.staticTexts["Finding your next watch…"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-")).count, 0)
        // Outlast the old Home timeout: late feed callbacks must not replace this state.
        let loading = expectation(for: NSPredicate { _, _ in
            app.staticTexts["Finding your next watch…"].exists || !prompt.exists
        }, evaluatedWith: nil)
        loading.isInverted = true
        wait(for: [loading], timeout: 13)
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(prompt.exists, "Pull-to-refresh must keep the sign-in state")
        XCTAssertFalse(app.staticTexts["Finding your next watch…"].exists)
        attach(app, "Following signed out")
        app.buttons["followingSignIn"].tap()
        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Sign in with Google"].isEnabled, !app.staticTexts["signInSetupRequired"].exists)
        XCTAssertFalse(app.buttons["Open Google in browser"].exists)
        attach(app, "Google sign-in ready")
        app.buttons["Done"].tap()
        XCTAssertTrue(prompt.exists)
        app.buttons["tab-Library"].tap()
        app.buttons["tab-Following"].tap()
        XCTAssertTrue(prompt.exists)
        XCTAssertFalse(app.staticTexts["Finding your next watch…"].exists)
    }

    @MainActor func testLibraryDownloadsAndSettings() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Downloads"].isSelected)
        XCTAssertFalse(app.segmentedControls.buttons["Saved"].exists)
        XCTAssertTrue(app.buttons["openDownloads"].exists)
        attach(app, "Downloads library")
        app.buttons["openDownloads"].tap()
        XCTAssertTrue(app.switches["Download on Wi-Fi only"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Download settings"].exists)
        app.buttons["Done"].tap()
        app.segmentedControls.buttons["History"].tap()
        XCTAssertFalse(app.buttons["openDownloads"].exists)
        app.segmentedControls.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["openDownloads"].exists)
    }

    @MainActor func testOfflineDownloadAndLocalPlayback() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=aqz-KE-bpKQ\n")
        XCTAssertTrue(app.buttons["videoActions"].waitForExistence(timeout: 10))
        app.buttons["videoActions"].tap()
        app.buttons["Download current video"].tap()
        XCTAssertTrue(app.buttons["View downloads"].waitForExistence(timeout: 3))
        app.buttons["View downloads"].tap()
        let offline = app.buttons["offline-aqz-KE-bpKQ"]
        XCTAssertTrue(offline.waitForExistence(timeout: 55), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Available offline"].exists)
        attach(app, "Offline download ready")
        app.terminate()
        app.launch()
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "Downloaded file must survive relaunch")
        offline.tap()
        XCTAssertTrue(app.staticTexts["Downloaded · available offline"].waitForExistence(timeout: 5))
        let status = app.staticTexts["playbackStatus"]
        expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.otherElements["nativeVideoSurface"])
        waitForExpectations(timeout: 10)
        let time = app.staticTexts["playbackTime"].label
        expectation(for: NSPredicate { _, _ in app.staticTexts["playbackTime"].label != time }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        attach(app, "Local native playback")
        let beforeBackground = seconds(app.staticTexts["playbackTime"].label)
        XCUIDevice.shared.press(.home)
        let interval = expectation(description: "Native background interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { interval.fulfill() }
        wait(for: [interval], timeout: 12)
        app.activate()
        XCTAssertGreaterThan(seconds(app.staticTexts["playbackTime"].label) - beforeBackground, 5)
        attach(app, "Native background playback")
        app.buttons["backToFeed"].tap()
    }

    @MainActor func testLiveSearchPlaybackAndHistory() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("Big Buck Bunny Blender\n")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 35), app.debugDescription)
        attach(app, "Native search results")
        card.tap()
        let status = app.staticTexts["playbackStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let playing = NSPredicate(format: "label BEGINSWITH 'Playing'")
        expectation(for: playing, evaluatedWith: status)
        waitForExpectations(timeout: 35)
        let before = app.staticTexts["playbackTime"].label
        let advance = NSPredicate { _, _ in app.staticTexts["playbackTime"].label != before }
        expectation(for: advance, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        attach(app, "Live playback")
        let native = app.otherElements["nativeVideoSurface"].exists
        if native { setNativePlayback(app, playing: false) }
        else {
            if !app.buttons["videoOverlayPlayPause"].exists { app.buttons["videoSurface"].tap() }
            app.buttons["videoOverlayPlayPause"].tap()
        }
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Paused'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        let restarted = expectation(for: playing, evaluatedWith: status)
        restarted.isInverted = true
        wait(for: [restarted], timeout: 4)
        if native { setNativePlayback(app, playing: true) }
        else {
            if !app.buttons["videoOverlayPlayPause"].exists { app.buttons["videoSurface"].tap() }
            app.buttons["videoOverlayPlayPause"].tap()
        }
        expectation(for: playing, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        if native { setNativePlayback(app, playing: false) }
        app.buttons["videoActions"].tap()
        XCTAssertFalse(app.buttons["Save current video"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        app.buttons["tab-Library"].tap()
        XCTAssertFalse(app.buttons["backToFeed"].exists, "Changing tabs must dismiss the pinned player")
        XCTAssertFalse(app.staticTexts["playbackStatus"].exists)
        app.segmentedControls.buttons["History"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        attach(app, "Watch history")
    }

    @MainActor func testPlayerDoesNotFollowTabNavigation() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://www.youtube.com/watch?v=jNQXAC9IVRw\n")
        XCTAssertTrue(app.buttons["backToFeed"].waitForExistence(timeout: 10))
        app.buttons["tab-Following"].tap()
        XCTAssertFalse(app.buttons["backToFeed"].exists)
        XCTAssertFalse(app.buttons["Expand player"].exists)
        XCTAssertFalse(app.staticTexts["playbackStatus"].exists)
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.staticTexts["Your library"].exists)
        XCTAssertLessThan(app.staticTexts["Your library"].frame.minY, 300, "Library should get the screen space back")
        attach(app, "Library without pinned player")
        app.buttons["tab-Home"].tap()
        XCTAssertFalse(app.buttons["backToFeed"].exists, "Returning Home must not resurrect the dismissed player")
    }

    @MainActor func testSettingsAndTabs() throws {
        let app = XCUIApplication(); app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Block ads"].waitForExistence(timeout: 5))
        let filter = app.staticTexts["filterStatus"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(filter.label.contains("Loaded"), app.debugDescription)
        attach(app, "Settings")
        app.buttons["Done"].tap()
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.staticTexts["Your library"].exists)
    }

    @MainActor private func setNativePlayback(_ app: XCUIApplication, playing: Bool) {
        let button = app.buttons["Play/Pause"]
        if !button.isHittable {
            app.otherElements["nativeVideoSurface"].coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.label == (playing ? "Play" : "Pause") { button.tap() }
        expectation(for: NSPredicate(format: "label == %@", playing ? "Playing" : "Paused"), evaluatedWith: app.staticTexts["playbackStatus"])
        waitForExpectations(timeout: 5)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func seconds(_ label: String) -> Int {
        let components = label.components(separatedBy: " / ")[0].split(separator: ":").compactMap { Int($0) }
        return components.count == 2 ? components[0] * 60 + components[1] : 0
    }
}
