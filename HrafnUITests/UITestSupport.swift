import XCTest

extension XCUIApplication {
    /// A tab: in the bottom tab bar on iPhone, in the top bar on iPadOS 18
    /// and later (which XCTest does not report as a tab bar). Waits up to
    /// `timeout` for either; `waitForExistence` on the result still works.
    @MainActor
    func tab(_ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        let inTabBar = tabBars.buttons[name]
        let anywhere = buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if inTabBar.exists { return inTabBar }
            if anywhere.exists { return anywhere }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return inTabBar
    }
}
