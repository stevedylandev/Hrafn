//
//  HrafnUITests.swift
//  HrafnUITests
//
//  Created by Steve Simkins on 9/26/26.
//

import XCTest

/// Phase 4 end to end in the simulator: sign in to the Docker Prosody (trusting
/// its private certificate), add romeo, chat with him.
///
/// Needs the servers (docker/README.md) and romeo's echo bot running:
///
/// ```sh
/// HRAFN_ECHO_BOT=1 swift test --package-path Packages/HrafnKit --filter EchoBot &
/// TEST_RUNNER_HRAFN_INTEGRATION=1 xcodebuild test -project Hrafn.xcodeproj -scheme Hrafn \
///   -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HrafnUITests/HrafnUITests
/// ```
final class HrafnUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignInAddContactAndChat() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1",
                          "needs the Docker servers and the echo bot")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()

        signIn(app)

        // Signed in: the tabs appear.
        let contactsTab = app.tab("Contacts")
        XCTAssertTrue(contactsTab.waitForExistence(timeout: 20))
        contactsTab.tap()
        app.buttons["Add Contact"].tap()
        let contactAddress = app.textFields["addContact.address"]
        XCTAssertTrue(contactAddress.waitForExistence(timeout: 5))
        contactAddress.tap()
        contactAddress.typeText("romeo@alpha.test")
        app.textFields["addContact.name"].tap()
        app.textFields["addContact.name"].typeText("Romeo")
        app.navigationBars.buttons["Add"].tap()
        // The bot accepts; Romeo shows up online.
        let romeo = app.staticTexts["Romeo"]
        XCTAssertTrue(romeo.waitForExistence(timeout: 20))
        attach(app, "3 contacts")

        // Chat.
        app.tab("Chats").tap()
        app.navigationBars.buttons["New Chat"].tap()
        let chatAddress = app.textFields["newChat.address"]
        XCTAssertTrue(chatAddress.waitForExistence(timeout: 5))
        chatAddress.tap()
        chatAddress.typeText("romeo@alpha.test")
        app.buttons["newChat.open"].tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Hello from the simulator")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(message(app, "Hello from the simulator").waitForExistence(timeout: 5))
        XCTAssertTrue(message(app, "echo: Hello from the simulator").waitForExistence(timeout: 20))
        // Read by the bot: the displayed marker comes back.
        XCTAssertTrue(message(app, "Hello from the simulator", state: "Read").waitForExistence(timeout: 10))
        attach(app, "4 chat")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Romeo"].waitForExistence(timeout: 5))
        attach(app, "5 conversations")
    }

    /// Phase 6 in the simulator: create a private group, talk in it, look at
    /// its participants, destroy it. Needs only the Docker servers.
    @MainActor
    func testCreateGroupAndChat() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)

        let chatsTab = app.tab("Chats")
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 20))
        chatsTab.tap()
        app.navigationBars.buttons["New Chat"].tap()
        let createRoom = app.buttons["newChat.createRoom"]
        XCTAssertTrue(createRoom.waitForExistence(timeout: 5))
        createRoom.tap()
        let name = app.textFields["createRoom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // Unique: a room left by an interrupted run is rejoined from juliet's bookmarks.
        let roomName = "Capulet Supper \(Int.random(in: 1000...9999))"
        name.typeText(roomName)
        attach(app, "1 new group")
        app.buttons["createRoom.create"].tap()

        // The new room's chat opens once the room is created and joined.
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["1 participant"].waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Welcome, gentlemen")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(message(app, "Welcome, gentlemen").waitForExistence(timeout: 5))
        // The room's reflection marks it delivered.
        XCTAssertTrue(message(app, "Welcome, gentlemen", state: "Delivered").waitForExistence(timeout: 10))
        attach(app, "2 group chat")

        // Group info: we are its owner and only participant.
        app.buttons["chat.title"].tap()
        XCTAssertTrue(app.staticTexts["Affiliation, Owner"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Participants (1)"].waitForExistence(timeout: 5))
        attach(app, "3 group info")
        app.swipeUp()
        app.buttons["Destroy Room"].tap()
        app.buttons["Destroy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: app.staticTexts[roomName])
        wait(for: [gone], timeout: 5)
        attach(app, "4 destroyed")
    }

    /// Phase 7 in the simulator: a photo from the library, uploaded to the
    /// Docker Prosody's HTTP upload service and reflected by a new group;
    /// then an avatar for juliet. Needs only the Docker servers.
    @MainActor
    func testSendPhotoAndSetAvatar() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)
        createGroup(app, named: "Mantua Post")

        // A photo from the simulator's library.
        app.buttons["chat.attach"].tap()
        app.buttons["Photos & Videos"].tap()
        let photo = pickerPhotos(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        sleep(1)
        // The picker's views report themselves not hittable; tap their middle.
        center(of: photo).tap()
        center(of: app.buttons["Done"]).tap()
        let image = app.descendants(matching: .any)["attachment.image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20))
        // Uploaded, sent, and reflected by the room.
        XCTAssertTrue(app.images["Delivered"].firstMatch.waitForExistence(timeout: 30))
        attach(app, "1 photo")

        // An avatar from the library.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tab("Settings").tap()
        app.staticTexts["juliet@alpha.test"].firstMatch.tap()
        let avatar = app.buttons["profile.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        let picture = pickerPhotos(app).element(boundBy: 1)
        XCTAssertTrue(picture.waitForExistence(timeout: 15))
        sleep(1)
        center(of: picture).tap() // one photo: picked at once
        XCTAssertTrue(app.buttons["Remove Avatar"].waitForExistence(timeout: 20))
        attach(app, "3 avatar")
        // Leave juliet without one for the other tests.
        app.buttons["Remove Avatar"].tap()
    }

    /// A voice message in a new group. Needs a microphone the simulator can
    /// use: the Mac's, once macOS has allowed Simulator to record
    /// (`TEST_RUNNER_HRAFN_MICROPHONE=1`).
    @MainActor
    func testSendVoiceMessage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_MICROPHONE"] == "1", "needs a microphone")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        createGroup(app, named: "Mantua Voice")

        // A voice message of a second or so.
        app.buttons["chat.record"].tap()
        app.tap() // lets the interruption monitor answer the prompt
        let sendRecording = app.buttons["chat.sendRecording"]
        XCTAssertTrue(sendRecording.waitForExistence(timeout: 10))
        sleep(2)
        sendRecording.tap()
        XCTAssertTrue(app.buttons["attachment.audio"].firstMatch.waitForExistence(timeout: 10))
        let delivered = NSPredicate(format: "count >= 1")
        expectation(for: delivered, evaluatedWith: app.images.matching(identifier: "Delivered"))
        waitForExpectations(timeout: 30)
        attach(app, "2 voice message")

    }

    /// Phase 8 in the simulator: a styled message in a new group, a reaction
    /// from its context menu (sent to the room and shown under the message),
    /// then a reply quoting it. Needs only the Docker servers.
    @MainActor
    func testReactReplyAndStyle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)
        createGroup(app, named: "Verona Square")

        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("*Fair* Verona, where we lay our _scene_")
        app.buttons["chat.send"].tap()
        let styled = "*Fair* Verona, where we lay our _scene_"
        XCTAssertTrue(message(app, styled).waitForExistence(timeout: 5))
        // Reactions and replies in a room need the room's id: its reflection.
        XCTAssertTrue(message(app, styled, state: "Delivered").waitForExistence(timeout: 10))
        attach(app, "1 styled")

        message(app, styled).press(forDuration: 1)
        let thumbsUp = app.buttons["👍"]
        XCTAssertTrue(thumbsUp.waitForExistence(timeout: 5))
        attach(app, "2 menu")
        thumbsUp.tap()
        XCTAssertTrue(app.buttons["reaction.👍"].waitForExistence(timeout: 10))
        attach(app, "3 reacted")

        // With a reaction under it, the bubble's parts are separate elements.
        app.staticTexts[styled].press(forDuration: 1)
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        XCTAssertTrue(app.otherElements["chat.replyBanner"].waitForExistence(timeout: 5)
                      || app.staticTexts["Replying to You"].waitForExistence(timeout: 1))
        composer.tap()
        composer.typeText("Two households")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Two households"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.quote"].firstMatch.waitForExistence(timeout: 5))
        attach(app, "4 replied")

        // Taking the reaction back.
        app.buttons["reaction.👍"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["reaction.👍"])
        wait(for: [gone], timeout: 10)

        app.buttons["chat.title"].tap()
        app.swipeUp()
        app.swipeUp()
        app.buttons["Destroy Room"].tap()
        app.buttons["Destroy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
    }

    /// Phase 9: full-text search from the chat list, and the chat opening at
    /// the message found. Needs only the Docker servers.
    @MainActor
    func testSearchMessages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)
        createGroup(app, named: "Elsinore")

        let composer = app.textFields["chat.composer"]
        let word = "Yorick\(Int.random(in: 1000...9999))"
        for text in ["Alas, poor \(word)", "I knew him, Horatio", "a fellow of infinite jest"] {
            composer.tap()
            composer.typeText(text)
            app.buttons["chat.send"].tap()
            XCTAssertTrue(message(app, text).waitForExistence(timeout: 5))
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))

        // Pull the list down to reveal the search field.
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(String(word.lowercased().prefix(8)))
        // The row reads "You: Alas, poor …" as one element.
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Alas, poor \(word)")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        attach(app, "1 search")
        result.tap()
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(message(app, "Alas, poor \(word)").waitForExistence(timeout: 5))
        attach(app, "2 found in chat")

        app.buttons["chat.title"].tap()
        app.swipeUp()
        app.swipeUp()
        app.buttons["Destroy Room"].tap()
        app.buttons["Destroy"].firstMatch.tap()
    }

    /// Phase 9: XCTest's accessibility audit (contrast, Dynamic Type,
    /// labels, hit regions, …) on the main screens. Needs only the Docker
    /// servers.
    @MainActor
    func testAccessibilityAudit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1", "needs the Docker servers")
        // The steps assume one column; on iPad the audit of the split chat
        // list also outlasts XCTest's time limit.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--no-notification-prompt"]
        app.launch()
        signIn(app)
        createGroup(app, named: "Audit")
        // Every screen's issues in one run.
        continueAfterFailure = true

        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("Is this *readable*?")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(message(app, "Is this *readable*?", state: "Delivered").waitForExistence(timeout: 10))
        // Keyboard down: it is the system's, and it hides the messages.
        app.scrollViews.firstMatch.swipeDown()
        try audit(app, "chat")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        try audit(app, "chats")

        app.tab("Contacts").tap()
        XCTAssertTrue(app.navigationBars["Contacts"].waitForExistence(timeout: 5))
        try audit(app, "contacts")

        app.tab("Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try audit(app, "settings")
        app.staticTexts["juliet@alpha.test"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["juliet@alpha.test"].waitForExistence(timeout: 5))
        try audit(app, "account")

        app.tab("Chats").tap()
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Audit'")).firstMatch.tap()
        app.buttons["chat.title"].tap()
        try audit(app, "room")
        app.swipeUp()
        app.swipeUp()
        app.buttons["Destroy Room"].tap()
        app.buttons["Destroy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
    }

    /// Runs the audit, attaching a screenshot first so a failure has context.
    ///
    /// Structural issues (labels, hit regions, traits, actions) fail the test,
    /// except in the keyboard and the system bars, and addresses, which the
    /// audit calls "not human-readable". Visual issues (contrast, Dynamic
    /// Type, clipping) are attached as a report instead: on iOS 26 most of
    /// them are the glass bars and content measured through them, or standard
    /// SwiftUI text styles (Form footers, `LabeledContent`) that the audit
    /// reports as "partially unsupported" although they scale.
    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        attach(app, "audit \(screen)")
        var visual: [String] = []
        try app.performAccessibilityAudit { issue in
            let element = issue.element
            if [.contrast, .dynamicType, .textClipped].contains(issue.auditType) {
                visual.append("\(issue.compactDescription): " + (element.map { "\($0.elementType.rawValue) '\($0.label)'" } ?? "?"))
                return true
            }
            // No element: the audit could not tie it to one of our views.
            guard let element else {
                visual.append("\(issue.compactDescription): no element")
                return true
            }
            let system: [XCUIElement.ElementType] = [.keyboard, .key, .tabBar, .navigationBar]
            if system.contains(element.elementType) { return true }
            if issue.auditType == .sufficientElementDescription, element.label.contains("@") { return true }
            return false
        }
        if !visual.isEmpty {
            let report = XCTAttachment(string: visual.joined(separator: "\n"))
            report.name = "audit \(screen) visual"
            report.lifetime = .keepAlways
            add(report)
        }
    }

    @MainActor
    private func createGroup(_ app: XCUIApplication, named name: String) {
        let chatsTab = app.tab("Chats")
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 20))
        chatsTab.tap()
        app.navigationBars.buttons["New Chat"].tap()
        app.buttons["newChat.createRoom"].tap()
        let field = app.textFields["createRoom.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Unique: a room left by an interrupted run is rejoined from juliet's bookmarks.
        field.typeText("\(name) \(Int.random(in: 1000...9999))")
        app.buttons["createRoom.create"].tap()
        XCTAssertTrue(app.staticTexts["1 participant"].waitForExistence(timeout: 20))
    }

    /// Onboarding as juliet on the Docker Prosody, trusting its certificate.
    @MainActor
    private func signIn(_ app: XCUIApplication) {
        let address = app.textFields["setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        attach(app, "onboarding")
        address.tap()
        address.typeText("juliet@alpha.test")
        app.secureTextFields["setup.password"].tap()
        app.secureTextFields["setup.password"].typeText("devpassword")
        app.buttons["Connection settings"].tap()
        app.textFields["setup.host"].tap()
        app.textFields["setup.host"].typeText("127.0.0.1")
        app.textFields["setup.port"].tap()
        app.textFields["setup.port"].typeText("5223")
        app.buttons["setup.signIn"].tap()

        // The Docker CA is private: the app asks before trusting it.
        let trust = app.alerts["Untrusted Certificate"].buttons["Trust and Continue"]
        XCTAssertTrue(trust.waitForExistence(timeout: 15))
        attach(app, "certificate")
        trust.tap()
    }

    /// A plain text message in the open chat. VoiceOver reads it as one
    /// element, "author, text, time, state", so that is how it is found.
    @MainActor
    private func message(_ app: XCUIApplication, _ text: String, state: String? = nil) -> XCUIElement {
        var query = app.descendants(matching: .any).matching(identifier: "chat.message")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
        if let state { query = query.matching(NSPredicate(format: "label ENDSWITH %@", ", " + state)) }
        return query.firstMatch
    }

    @MainActor
    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// The photos in the system Photos picker's grid.
    @MainActor
    private func pickerPhotos(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(identifier: "PXGGridLayout-Info")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
