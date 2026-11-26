import XCTest

final class WebServiceWorkflowTests: XCTestCase {
    @MainActor
    func testAlexaShoppingFixtureSendsAndKeepsNewChatAndHistoryAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        selectShoppingAgent("Alexa Shopping Web", in: app)
        capture(app, name: "Alexa Shopping added — local fixture")
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Compare reusable water bottle materials")
        app.buttons["Send & compare"].click()
        let answer = reply(app, containing: "Simulated Alexa reply: Compare reusable water bottle materials")
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        capture(app, name: "Alexa Shopping reply — local fixture")
        app.buttons["Alexa overflow menu"].click()
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Chat history"].exists)
        capture(app, name: "Alexa New chat and Chat history — local fixture")
    }

    @MainActor
    func testWalmartSparkyReceivesSharedQuestion() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        selectShoppingAgent("Walmart Shopping Agent", in: app)
        let editor = app.textViews["Shared prompt"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Compare two reusable water bottles")
        capture(app, name: "Sparky selected with shopping question — local fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "The steel bottle keeps water cold").waitForExistence(timeout: 20))
        capture(app, name: "Sparky shopping reply — local fixture")
    }

    @MainActor
    private func selectShoppingAgent(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"] {
            app.buttons[name].click()
        }
        app.buttons["Edit agents"].click()
        app.scrollViews["Agent grid scroll area"].scroll(byDeltaX: 0, deltaY: -1000)
        let add = app.buttons["Add \(name)"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        app.buttons["Done editing agents"].click()
        app.buttons[name].click()
    }

    @MainActor
    func testAddNamedAccountFromSettingsAndOpenSeparateSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let add = app.buttons["add-account-chatgpt"]
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.staticTexts["settings-page-websites"].click()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let name = app.textFields["Agent name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("ChatGPT Work")
        XCTAssertFalse(app.switches["Use another account"].exists, "Adding an account must always isolate its sign-in")
        app.buttons["Add account"].click()
        let signIn = app.buttons["Sign in to ChatGPT Work"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.click()
        XCTAssertTrue(app.staticTexts["Sign in to ChatGPT Work"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo website · sign-in is simulated; no provider account is contacted."].exists)
        capture(app, name: "Separate account website — simulated sign-in")
        app.buttons["Done"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["ChatGPT Work"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["ChatGPT Work"].value as? String, "Not selected")
    }

    @MainActor
    private func selectWebFixtureRecipients(_ app: XCUIApplication) {
        app.enableFixtureWebsites("muse", "chatgpt", "claude", "grok")
        for name in ["Muse Web", "ChatGPT Web", "Claude Web", "Grok Web"] {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            if button.value as? String != "Selected" { button.click() }
            XCTAssertEqual(button.value as? String, "Selected")
        }
    }
    @MainActor
    func testRemoveWebAgentFromViewPreservesConversationAndCanRestore() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        app.enableFixtureWebsites("muse", "chatgpt")
        for name in ["Muse Web", "ChatGPT Web"] {
            let tile = app.buttons[name]
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            tile.click()
            XCTAssertEqual(tile.value as? String, "Selected")
        }
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Remove web pane fixture")
        app.buttons["Send & compare"].click()
        let header = app.descendants(matching: .any).matching(identifier: "Agent header Muse Web").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        capture(app, name: "Before removal — simulated comparison")
        header.rightClick()
        XCTAssertTrue(app.menuItems["Remove from view"].waitForExistence(timeout: 3))
        capture(app, name: "Header removal menu — simulated comparison")
        app.menuItems["Remove from view"].click()
        XCTAssertFalse(header.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Agent header ChatGPT Web").firstMatch.exists)
        XCTAssertEqual(app.buttons["Recipient Muse Web"].value as? String, "Not selected")
        capture(app, name: "After removal — simulated comparison")
        app.buttons["Recipient Muse Web"].click()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(reply(app, containing: "Fixture reply: Remove web pane fixture").exists)
    }

    @MainActor
    func testSevenChatsCanBeHiddenAndRestoredWithoutResizing() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Maple"].waitForExistence(timeout: 5))
        for name in ["Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.buttons["Send & compare"].click()
        let window = app.windows.firstMatch
        let webAgents = ["Muse Web", "ChatGPT Web", "Claude Web", "Grok Web"]
        let messagesAgents = ["Cedar", "Lumen", "Orbit"]
        let headers = webAgents.map {
            app.descendants(matching: .any).matching(identifier: "Agent header \($0)").firstMatch
        }
        XCTAssertTrue(headers[0].waitForExistence(timeout: 15))
        let composers = messagesAgents.map { app.textViews["Private reply to \($0)"] }
        XCTAssertTrue(composers[0].waitForExistence(timeout: 5))
        for pane in headers + composers { XCTAssertTrue(pane.exists) }
        let wideWidth = window.frame.width
        for header in headers {
            XCTAssertTrue(header.isHittable)
            header.rightClick()
            app.menuItems["Remove from view"].click()
            XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        }
        for composer in composers { XCTAssertTrue(composer.isHittable) }
        XCTAssertEqual(window.frame.width, wideWidth, accuracy: 1)
        for (name, header) in zip(webAgents, headers) {
            app.buttons["Recipient \(name)"].click()
            XCTAssertTrue(header.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(window.frame.width, wideWidth, accuracy: 1)
        capture(app, name: "Seven reachable chats — isolated fixture")
    }

    @MainActor
    func testAddAgentToExistingBlastInjectsSharedHistoryOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        defer { app.terminate() }
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Claude Web", "Grok Web"]
        for name in excluded {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            if button.value as? String == "Selected" { button.click() }
        }
        // Confirm setup after launch tasks settle before exercising recipient joins.
        for name in excluded {
            let button = app.buttons[name]
            if button.value as? String == "Selected" { button.click() }
            XCTAssertEqual(button.value as? String, "Not selected")
        }
        let editor = app.textViews["Shared prompt"]
        func broadcast(_ text: String) {
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(text)
            XCTAssertTrue(app.buttons["Send & compare"].isEnabled)
            app.buttons["Send & compare"].click()
            let reply = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: " + text)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 15))
        }
        broadcast("Original joining fixture ask")
        broadcast("Shared joining fixture follow-up")
        app.buttons["Recipient ChatGPT Web"].click()
        broadcast("Private joining fixture detail")
        capture(app, name: "Before adding Grok — isolated simulated chats")
        app.buttons["Recipient Grok Web"].click()
        assertJoiningReply(app, agent: "Grok Web", original: "Original joining fixture ask",
                           shared: "Shared joining fixture follow-up", privateDetail: "Private joining fixture detail")
        XCTAssertEqual(app.buttons["Recipient Grok Web"].value as? String, "Selected")
        capture(app, name: "Grok joined existing blast with shared context — isolated simulated chats")
        app.buttons["Recipient Cedar"].click()
        let cedar = app.buttons["Recipient Cedar"]
        let deadline = Date().addingTimeInterval(15)
        while cedar.value as? String != "Selected", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(cedar.value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["Shared joining fixture follow-up"].waitForExistence(timeout: 15))
        capture(app, name: "Messages agent joined existing blast — isolated simulated chats")
    }

    @MainActor
    func testFreshPrivateCLIConversationSharesOnlyExplicitBroadcastsWhenAgentsJoin() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Muse Web"].waitForExistence(timeout: 5))
        let settings = enableCLIFixtureAccounts(in: app)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse Web", "ChatGPT Web", "Claude Web", "Grok Web", "Claude Code"]
        for _ in 0..<2 {
            for name in excluded where app.buttons[name].value as? String == "Selected" { app.buttons[name].click() }
        }
        for name in excluded { XCTAssertEqual(app.buttons[name].value as? String, "Not selected") }
        let codex = app.buttons["Codex CLI"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        XCTAssertEqual(codex.value as? String, "Not selected")
        codex.click()
        codex.rightClick()
        app.menuItems["Open chat"].click()
        let direct = app.textViews["Message Codex CLI"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        func sendDirect(_ text: String) {
            direct.click(); direct.typeText(text)
            XCTAssertEqual(direct.value as? String, text)
            direct.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: " + text).waitForExistence(timeout: 15))
        }
        sendDirect("Original CLI privacy ask")
        sendDirect("Private CLI detail")
        let shared = app.textViews["Shared prompt"]
        shared.click(); shared.typeKey("a", modifierFlags: .command); shared.typeText("Shared CLI follow-up")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Shared CLI follow-up").waitForExistence(timeout: 15))
        capture(app, name: "Private sole CLI conversation before joins — isolated fixture")
        shared.click(); shared.typeText("Retained unsent shared draft")
        for name in ["Grok Web", "Claude Code", "Cedar"] {
            app.buttons["Recipient \(name)"].click()
            let deadline = Date().addingTimeInterval(15)
            while !app.buttons["Send & compare"].isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            XCTAssertEqual(app.buttons["Recipient \(name)"].value as? String, "Selected")
        }
        for agent in ["Grok Web", "Claude Code"] {
            assertJoiningReply(app, agent: agent, original: "Original CLI privacy ask",
                               shared: "Shared CLI follow-up", privateDetail: "Private CLI detail")
        }
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value == %@", "Private CLI detail")).count, 0)
        XCTAssertEqual(shared.value as? String, "Retained unsent shared draft")
        capture(app, name: "Web CLI and Messages joins exclude private CLI detail — isolated fixture")
    }

    @MainActor
    func testWebDefaultsAndOptionalCLIConversationsStaySeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        defer { app.terminate() }
        for name in ["Muse Web", "ChatGPT Web", "Claude Web", "Grok Web"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons[name].value as? String, "Selected")
        }
        XCTAssertFalse(app.buttons["Codex CLI"].exists)
        XCTAssertFalse(app.buttons["Claude Code"].exists)
        XCTAssertFalse(app.staticTexts["Your local accounts (simulated)"].exists)
        capture(app, name: "Featured grid with optional CLI setup — isolated fixture")
        let settings = enableCLIFixtureAccounts(in: app)
        capture(app, name: "Optional CLI toggles in Settings — simulated accounts")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse Web", "Grok Web"] { app.buttons[name].click() }
        for name in ["Codex CLI", "Claude Code"] {
            let tile = app.buttons[name]
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "Enabling a CLI adds it to an existing custom grid")
            XCTAssertEqual(tile.value as? String, "Not selected", "Enabling an account is separate from choosing a recipient")
            tile.click()
            XCTAssertEqual(tile.value as? String, "Selected")
        }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Web and CLI comparison fixture")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT Web", "Claude Web", "Codex CLI", "Claude Code"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 15))
        }
        XCTAssertEqual(app.webViews.count, 2, "Website chats coexist with two separate native CLI panes")
        XCTAssertFalse(app.buttons["Switch account"].exists)
        capture(app, name: "Website and CLI replies in the same blast — synthetic replies")
        app.buttons["New Blast"].click()
        let comparison = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Web and CLI comparison fixture")).firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 5))
        comparison.click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 10))
        editor.click(); editor.typeText("Continue each saved conversation")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT Web", "Claude Web", "Codex CLI", "Claude Code"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Continue each saved conversation").waitForExistence(timeout: 15))
        }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.switches["Enable Codex CLI"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["New Blast"].click()
        XCTAssertTrue(app.buttons["Codex CLI"].exists)
        XCTAssertEqual(app.buttons["Codex CLI"].value as? String, "Set up")
        comparison.click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Recipient Codex CLI"].isEnabled)
    }

    @MainActor
    private func enableCLIFixtureAccounts(in app: XCUIApplication) -> XCUIElement {
        let settings = openSettingsPage(app, "cli")
        for name in ["Codex CLI", "Claude Code"] {
            let toggle = settings.switches["Enable \(name)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
            toggle.click()
            XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        }
        return settings
    }

    @MainActor
    private func assertJoiningReply(_ app: XCUIApplication, agent: String, original: String, shared: String,
                                    privateDetail: String, file: StaticString = #filePath, line: UInt = #line) {
        let echo = reply(app, containing: "\(agent) fixture reply: \(original)")
        guard echo.waitForExistence(timeout: 15) else {
            XCTFail("\(agent) did not receive the original ask", file: file, line: line)
            return
        }
        let text = echo.value as? String ?? echo.label
        XCTAssertTrue(text.contains(shared), file: file, line: line)
        XCTAssertFalse(text.contains(privateDetail), file: file, line: line)
    }

    @MainActor
    private func reply(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    @MainActor
    func testSignedInWebsitesSkipConnectionIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 5))
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Already signed in fixture")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT Web", "Claude Web", "Grok Web"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Already signed in fixture").waitForExistence(timeout: 15))
        }
        XCTAssertTrue(reply(app, containing: "Fixture reply: Already signed in fixture").exists)
        XCTAssertFalse(app.staticTexts["Connect your accounts"].exists)
        capture(app, name: "Signed-in websites submit without a login reminder — isolated fixture")
    }

    @MainActor
    func testSignedOutAgentOpensSetupAndKeepsPromptUntilUserSubmitsAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        app.activate()
        defer { app.terminate() }
        for name in ["Maple", "Echo", "Flint", "ChatGPT Web", "Claude Web", "Grok Web"] { app.buttons[name].click() }
        app.buttons["Muse Web"].rightClick()
        app.menuItems["Open chat"].click()
        let signOut = app.buttons["Sign out of fixture"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.click()
        XCTAssertTrue(app.buttons["Sign in to fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["New Blast"].exists, "No comparison has been saved yet")
        let agents = app.outlines.cells.containing(NSPredicate(format: "label == %@", "Agents")).firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.click()
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Keep this comparison request")
        let send = app.buttons["Send & compare"]
        XCTAssertTrue(send.isEnabled, "A signed-out agent must lead to setup, not a disabled send button")
        XCTAssertTrue(app.staticTexts["Website sign-in status"].waitForExistence(timeout: 5))
        app.activate(); send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Connect your accounts", "Connect your accounts")).firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Only signed-out Muse requires login; prompt preserved — isolated fixture")
        app.activate(); app.buttons["Start signing in"].click()
        for name in ["Cedar", "Lumen", "Orbit"] {
            XCTAssertTrue(app.staticTexts["\(name) (Demo)"].waitForExistence(timeout: 5), "Selected Messages panes remain visible while Muse needs sign-in")
        }
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.exists)
        app.activate(); app.buttons["Sign in to fixture"].click()
        XCTAssertTrue(app.buttons["Sign out of fixture"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.exists, "Signing in must not submit automatically")
        app.activate(); send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.waitForExistence(timeout: 10))
        for name in ["Cedar", "Lumen", "Orbit"] {
            XCTAssertTrue(app.textViews["Private reply to \(name)"].waitForExistence(timeout: 10), "Messages recipients become full conversation panes after sending")
        }
        XCTAssertFalse(app.staticTexts["Appeared in Muse Web"].exists)
    }

    @MainActor
    func testFailedMessagesRecipientCanRetryWithoutResendingToMuse() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        defer { app.terminate() }
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.checkBoxes["Simulate one failure"].click()
        for name in ["ChatGPT Web", "Claude Web", "Grok Web"] { app.buttons[name].click() }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Mixed failure fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Fixture reply:").waitForExistence(timeout: 10))
        let retry = app.buttons["Retry only failed recipients"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.click()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Mixed failure fixture")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        let museReplies = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Mixed failure fixture"))
        XCTAssertEqual(museReplies.count, 1)
    }

    @MainActor
    func testEmbeddedMuseAndMessagesReceiveOneSharedPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        selectWebFixtureRecipients(app)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Muse Web"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Muse Web"].value as? String, "Selected")
        XCTAssertFalse(app.staticTexts["Web services"].exists)
        XCTAssertFalse(app.staticTexts["Grok Bot · unavailable"].exists)
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        for name in ["ChatGPT Web", "Claude Web", "Grok Web"] { app.buttons[name].click() }
        XCTAssertEqual(app.buttons["Muse Web"].value as? String, "Selected")
        capture(app, name: "Muse selected beside Messages agents — local fixture")
        app.buttons["Muse Web"].rightClick()
        app.menuItems["Open chat"].click()
        XCTAssertTrue(app.buttons["Sign out of fixture"].waitForExistence(timeout: 10))
        capture(app, name: "Muse connected — local fixture")
        XCTAssertEqual(app.buttons["Recipient Cedar"].value as? String, "Selected")
        let editor = app.textViews["Shared prompt"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Compare a morning walk with an afternoon walk.")
        capture(app, name: "Shared prompt ready — synthetic content")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Fixture reply:").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Compare a morning walk")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Cedar (Demo)"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Embedded Muse and Messages replies — synthetic content")
        editor.click(); editor.typeText("Keep this shared draft")
        let privateReply = app.textViews["Private reply to Cedar"]
        XCTAssertTrue(privateReply.exists)
        privateReply.click(); privateReply.typeText("Cedar direct reply from its pane")
        privateReply.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Cedar direct reply from its pane")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(privateReply.value as? String, "")
        XCTAssertEqual(editor.value as? String, "Keep this shared draft")
        XCTAssertFalse(reply(app, containing: "Fixture reply: Cedar direct reply from its pane").exists, "Private Messages replies must not be sent to Muse Web")
        capture(app, name: "Direct Messages pane reply — simulated Messages, shared draft retained")
        app.buttons["New Blast"].click()
        XCTAssertEqual(app.buttons["Muse Web"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Cedar"].value as? String, "Selected")
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "Keep this shared draft")
        app.buttons["Muse Web"].rightClick()
        app.menuItems["Open chat"].click()
        XCTAssertFalse(app.staticTexts["Appeared in Muse Web"].exists)
        XCTAssertFalse(app.buttons["Check Muse Web connection"].exists)
    }

    /// Opens Settings and selects a sidebar page.
    @MainActor
    private func openSettingsPage(_ app: XCUIApplication, _ page: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.staticTexts["settings-page-\(page)"].click()
        return settings
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor extension XCUIApplication {
    func enableFixtureWebsites(_ providers: String...) {
        typeKey(",", modifierFlags: .command)
        let settings = windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.staticTexts["settings-page-websites"].click()
        for provider in providers {
            let toggle = settings.switches["enable-web-\(provider)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if String(describing: toggle.value ?? "") == "0" { toggle.click() }
            XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
    }
}
