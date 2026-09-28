import XCTest

/// Phase 5 end to end, as far as the simulator allows: sign in as tybalt,
/// allow notifications, see the APNs token registered with the server, leave
/// the app. `PushSender` (paris, and the push app server) waits for the app to
/// log out, writes, receives the server's XEP-0357 publish for this device's
/// token, and delivers fpush's push with `simctl push`. Tapping the banner
/// brings the app back, which catches up and shows the message.
///
/// Simulated pushes do not start notification service extensions, so the
/// banner is fpush's generic text here; the extension's fetch is covered by
/// `PushPipelineTests` and needs a device for the rest (docs/PHASE-STATUS.md).
///
/// ```sh
/// export HRAFN_PUSH_BODY="ping from paris $RANDOM"
/// HRAFN_PUSH_SENDER=1 swift test --package-path Packages/HrafnKit --filter PushSender &
/// TEST_RUNNER_HRAFN_INTEGRATION=1 TEST_RUNNER_HRAFN_PUSH_BODY="$HRAFN_PUSH_BODY" xcodebuild test \
///   -project Hrafn.xcodeproj -scheme Hrafn -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -parallel-testing-enabled NO -only-testing:HrafnUITests/HrafnPushUITests
/// ```
///
/// Parallel testing must be off: `simctl push booted` cannot reach the clone
/// simulators it runs on.
final class HrafnPushUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPushShowsTheFetchedMessage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1",
                          "needs the Docker servers and PushSender")
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["--reset-data"]
        app.launch()

        let address = app.textFields["setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("tybalt@alpha.test")
        app.secureTextFields["setup.password"].tap()
        app.secureTextFields["setup.password"].typeText("devpassword")
        app.buttons["Connection settings"].tap()
        app.textFields["setup.host"].tap()
        app.textFields["setup.host"].typeText("127.0.0.1")
        app.textFields["setup.port"].tap()
        app.textFields["setup.port"].typeText("5223")
        app.buttons["setup.signIn"].tap()
        let trust = app.alerts["Untrusted Certificate"].buttons["Trust and Continue"]
        XCTAssertTrue(trust.waitForExistence(timeout: 15))
        trust.tap()
        XCTAssertTrue(app.tab("Chats").waitForExistence(timeout: 20))

        // The permission prompt follows the first account.
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }

        // The simulator gets a real APNs token, and the server takes it.
        app.tab("Settings").tap()
        app.staticTexts["tybalt@alpha.test"].firstMatch.tap()
        let push = app.staticTexts["account.push"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        let registered = NSPredicate(format: "label ENDSWITH 'On'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: registered, evaluatedWith: push)], timeout: 20), .completed,
                       "push not registered with the server: \(push.label)")
        attach(app, "1 registered")
        app.tab("Chats").tap()

        // Leave: after the grace period the app logs out and PushSender writes.
        XCUIDevice.shared.press(.home)

        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'New Message'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 180), "no push banner")
        attach(springboard, "2 banner")

        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let body = ProcessInfo.processInfo.environment["HRAFN_PUSH_BODY"] ?? "ping from paris"
        let preview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 20), "the app did not catch up on return")
        attach(app, "3 caught up")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
