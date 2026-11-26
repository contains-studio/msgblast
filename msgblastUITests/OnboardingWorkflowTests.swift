import XCTest

final class OnboardingWorkflowTests: XCTestCase {
    @MainActor
    private func launch(contactsDenied: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        if contactsDenied { app.launchArguments.append("--contacts-access-preview") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func attachScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func chooseAgents(in app: XCUIApplication, skippingIncompletePermissions: Bool = false) {
        let next = app.buttons[skippingIncompletePermissions ? "skip-permissions" : "continue-permissions"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        next.click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func revealChoice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 10000)
        let choice = app.buttons["Choose \(name)"]
        for _ in 0..<16 where !choice.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(choice.isHittable)
        return choice
    }

    @MainActor
    private func selectChoice(_ name: String, in app: XCUIApplication) {
        revealChoice(name, in: app).click()
    }

    @MainActor
    func testSettingsOffersWebAlternativesDisabledForNewUsers() {
        let app = launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        app.staticTexts["settings-page-websites"].click()
        let chatgpt = app.switches["enable-web-chatgpt"]
        XCTAssertTrue(chatgpt.waitForExistence(timeout: 5))
        for provider in ["muse", "chatgpt", "claude", "dots", "grok"] {
            let toggle = app.switches["enable-web-\(provider)"]
            XCTAssertTrue(toggle.exists)
            let value = toggle.value
            let enabled = (value as? NSNumber)?.boolValue ?? (value as? String).flatMap {
                ["1", "on"].contains($0) ? true : ["0", "off"].contains($0) ? false : nil
            }
            XCTAssertEqual(enabled, false, "New installations must opt into web agents")
        }
    }

    @MainActor
    func testNativeChoicesReplaceWebAlternativesInOnboarding() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        for provider in ["muse", "chatgpt", "claude", "dots", "grok", "grokbot"] {
            XCTAssertFalse(app.buttons["onboarding-choice-\(provider)"].exists)
        }
        for name in ["Muse", "ChatGPT", "Claude", "Dots", "Grok Bot", "Wabi"] {
            XCTAssertTrue(app.buttons["Choose \(name)"].exists)
        }
    }

    @MainActor
    func testUnifiedPermissionsPrecedeAllAgentGroupsAndSelectionIsRequired() {
        let app = launch(contactsDenied: true)
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["check-onboarding-permissions"].exists)
        XCTAssertEqual(app.scrollViews.count, 0, "Permission setup fits without scrolling")
        XCTAssertFalse(app.staticTexts["System Settings · Privacy & Security"].exists)
        XCTAssertFalse(app.switches["enable-cua-driver-permission"].exists)
        XCTAssertFalse(app.staticTexts["CuaDriver"].exists)
        XCTAssertFalse(app.buttons["Manage"].exists)
        XCTAssertFalse(app.staticTexts["Messages Agents"].exists)
        XCTAssertFalse(app.staticTexts["App agents"].exists)
        for identifier in ["messages-history", "messages-contacts", "messages-automation", "cua-host", "cua-capture"] {
            XCTAssertTrue(app.switches["enable-\(identifier)-permission"].exists)
        }
        XCTAssertFalse(app.buttons["Choose ChatGPT"].exists)
        XCTAssertFalse(app.buttons["continue-permissions"].isEnabled)
        chooseAgents(in: app, skippingIncompletePermissions: true)
        XCTAssertFalse(app.buttons["Continue setup"].isEnabled)
        XCTAssertFalse(app.buttons["Choose Fo"].exists)
        for provider in ["instinct", "fo", "szn", "poke"] {
            XCTAssertTrue(app.images["locked-message-avatar-\(provider)"].exists)
        }
        XCTAssertTrue(app.links["Enable permissions"].exists)
        for name in ["ChatGPT", "Codex CLI", "Claude Code", "OpenClaw", "Hermes"] {
            XCTAssertTrue(revealChoice(name, in: app).exists)
        }
        for provider in ["muse", "chatgpt", "claude", "dots", "grok", "grokbot"] {
            XCTAssertFalse(app.buttons["onboarding-choice-\(provider)"].exists, "Web alternatives are enabled in Settings")
        }
        selectChoice("ChatGPT", in: app)
        XCTAssertTrue(app.buttons["Continue setup"].isEnabled)
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        chooseAgents(in: app, skippingIncompletePermissions: true)
        XCTAssertEqual(app.buttons["Choose ChatGPT"].value as? String, "Installed. Selected")
    }

    @MainActor
    func testSkippingIncompletePermissionsKeepsOnlyCompletedSection() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview", "--onboarding-permissions-preview", "--contacts-access-preview"]
        app.launch()
        defer { app.terminate() }
        let next = app.buttons["continue-permissions"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let host = app.switches["enable-cua-host-permission"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: host)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(next.isEnabled)
        XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertFalse(app.switches["enable-cua-driver-permission"].exists)
        XCTAssertFalse(app.staticTexts["CuaDriver"].exists)
        XCTAssertTrue(host.isHittable)
        attachScreenshot("Host permissions incomplete — Continue disabled", in: app)
        host.click()
        XCTAssertEqual((app.switches["enable-cua-host-permission"].value as? NSNumber)?.boolValue, true)
        XCTAssertFalse(next.isEnabled, "One Accessibility grant does not complete App access")
        let capture = app.switches["enable-cua-capture-permission"]
        XCTAssertTrue(capture.isHittable)
        capture.click()
        XCTAssertEqual((capture.value as? NSNumber)?.boolValue, true)
        XCTAssertFalse(next.isEnabled, "Continue requires both permission sections")
        XCTAssertEqual((app.switches["enable-messages-contacts-permission"].value as? NSNumber)?.boolValue, false)
        attachScreenshot("App access complete — remaining permissions can be skipped", in: app)
        chooseAgents(in: app, skippingIncompletePermissions: true)
        XCTAssertFalse(app.buttons["Choose Fo"].exists)
        for provider in ["instinct", "fo", "szn", "poke"] {
            XCTAssertTrue(app.images["locked-message-avatar-\(provider)"].exists)
        }
        XCTAssertTrue(app.links["Enable permissions"].exists)
        XCTAssertFalse(app.staticTexts["Agents from your existing Messages conversations have been added. You can deselect any you don’t want."].exists)
        attachScreenshot("Apps enabled and Messages unavailable", in: app)
        XCTAssertTrue(revealChoice("ChatGPT", in: app).isEnabled)
    }

    @MainActor
    func testUnavailableGeminiIsHiddenInOnboarding() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        XCTAssertTrue(app.buttons["Choose Wabi"].exists)
        XCTAssertFalse(app.buttons["onboarding-choice-geminiApp"].exists)
    }

    @MainActor
    func testWabiOnboardingConfirmsDedicatedChatBeforeFirstPrompt() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        let wabi = app.buttons["Choose Wabi"]
        XCTAssertTrue(wabi.waitForExistence(timeout: 5))
        selectChoice("Wabi", in: app)
        expectation(for: NSPredicate(format: "value == %@", "Installed. Selected"), evaluatedWith: wabi)
        waitForExpectations(timeout: 5)
        let next = app.buttons["Continue setup"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        next.click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["permission-status-cua-host"].exists)
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists)
        let check = app.buttons["Connect Wabi"]
        for _ in 0..<6 where !check.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(check.isHittable)
        check.click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        let confirmation = "Your first prompt in a new comparison starts a dedicated AI chat in Wabi. Follow-ups stay in that chat. This check didn’t send a message."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", confirmation)).firstMatch.exists)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testGrokBotIsChosenInsideMsgblastAndConnectsWithoutAnExtraCheck() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        selectChoice("Grok Bot", in: app)
        app.buttons["Continue setup"].click()
        let picker = app.popUpButtons["grok-bot-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<6 where !picker.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertTrue(app.buttons["Connect Grok Bot"].exists)
        picker.click()
        app.menuItems["Research Bot"].click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Research Bot")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testMuseChecksConnectionAfterGlobalPermissionsWithoutBrowserImport() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        for name in ["Muse", "Grok Bot", "Wabi"] {
            let installedApp = app.buttons["Choose \(name)"]
            XCTAssertTrue(installedApp.waitForExistence(timeout: 5))
            XCTAssertTrue(installedApp.isEnabled)
            XCTAssertEqual(installedApp.value as? String, "Installed. Not selected")
        }
        let muse = app.buttons["Choose Muse"]
        selectChoice("Muse", in: app)
        expectation(for: NSPredicate(format: "value == %@", "Installed. Selected"), evaluatedWith: muse)
        waitForExpectations(timeout: 5)
        let continueSetup = app.buttons["Continue setup"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: continueSetup)
        waitForExpectations(timeout: 5)
        continueSetup.click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["permission-status-cua-host"].exists)
        XCTAssertEqual(app.webViews.count, 0, "A desktop app must not open a website sign-in flow")
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists)
        let connect = app.buttons["Connect Muse"]
        for _ in 0..<6 where !connect.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(connect.isHittable)
        connect.click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your first prompt in a new comparison starts a new side chat in Muse. This check didn’t send a message."].exists)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        app.buttons["Back"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].exists, "A saved binding still requires an explicit live check")
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists, "A cached check must not show a new confirmation")
        let reconnect = app.buttons["Connect Muse"]
        for _ in 0..<6 where !reconnect.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        reconnect.click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativeConnectionsShareOneChecklistAndShowWhichAppsWillBeSkipped() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        for name in ["ChatGPT", "Dots", "Claude"] { selectChoice(name, in: app) }
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertFalse(app.switches["Enable ChatGPT"].exists)
        app.buttons["Connect ChatGPT"].click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        let skipNotice = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "will be skipped")).firstMatch
        XCTAssertTrue(skipNotice.exists)
        let firstNotice = skipNotice.value as? String
        XCTAssertTrue(firstNotice?.contains("Dots") == true)
        XCTAssertTrue(firstNotice?.contains("Claude") == true)
        attachScreenshot("Checklist identifies unchecked apps that Continue will skip", in: app)
        for name in ["ChatGPT", "Dots", "Claude"] {
            XCTAssertFalse(app.buttons["Skip \(name)"].exists)
        }
        app.buttons["Connect Dots"].click()
        expectation(for: NSPredicate(format: "value == %@", "Claude will be skipped. You can connect later."), evaluatedWith: skipNotice)
        waitForExpectations(timeout: 5)
        app.buttons["Connect Claude"].click()
        XCTAssertTrue(skipNotice.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5), "Native apps complete in one batch")
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["ChatGPT"].waitForExistence(timeout: 5))
        app.buttons["ChatGPT"].click()
        app.buttons["Claude"].click()
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeText("Clean native conversation fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.textViews["Message ChatGPT"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ChatGPT fixture reply: Clean native conversation fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Claude fixture reply: Clean native conversation fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Sending…"].exists, "Completed replies must retire the outgoing sending status")
        XCTAssertFalse(app.staticTexts["desktop-app-installation"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["desktop-connection-confirmation"].exists)
        XCTAssertFalse(app.switches["Enable ChatGPT"].exists)
        XCTAssertFalse(app.buttons["Check installation"].exists)
        app.buttons["ChatGPT options"].click()
        XCTAssertTrue(app.staticTexts["desktop-app-installation"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        XCTAssertFalse(app.staticTexts["desktop-app-installation"].exists)

        assertGridDraftStaysOutOfComparison(in: app)
    }

    @MainActor
    private func assertGridDraftStaysOutOfComparison(in app: XCUIApplication) {
        // The Agents grid is a new workspace, even when reached from a
        // comparison instead of the New Blast button.
        app.buttons["Agents"].click()
        let gridDraft = app.textViews["Shared prompt"]
        XCTAssertTrue(gridDraft.waitForExistence(timeout: 5))
        gridDraft.click(); gridDraft.typeText("A draft for a different conversation")
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Clean native conversation fixture")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        XCTAssertTrue(app.textViews["Message ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "", "The grid draft must not be saved in the previous conversation")
        app.buttons["Agents"].click()
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "A draft for a different conversation")
    }

    @MainActor
    func testIncompleteMessagingSectionLocksItsAgentsWhileAppsCanContinue() {
        let app = launch(contactsDenied: true)
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["continue-permissions"].isEnabled)
        chooseAgents(in: app, skippingIncompletePermissions: true)
        XCTAssertFalse(app.buttons["Choose Fo"].exists)
        XCTAssertTrue(app.buttons["Choose ChatGPT"].isEnabled)
        app.buttons["Back"].click()
        let contacts = app.switches["enable-messages-contacts-permission"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 5))
        contacts.click()
        chooseAgents(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Selected"), evaluatedWith: app.buttons["Choose Fo"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Choose Fo"].isEnabled)
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["Continue setup"].isEnabled, "Granting Messaging access adds existing agents automatically")
    }

    @MainActor
    func testMessagesAreAddedWithoutDiscoveryOrConversationPicker() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Selected"), evaluatedWith: app.buttons["Choose Fo"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Choose Instinct"].value as? String, "Selected")
        XCTAssertFalse(app.staticTexts["Agents we found"].exists)
        XCTAssertFalse(app.buttons["Search for more agents in Messages"].exists)
        XCTAssertFalse(app.textFields["Find onboarding contact"].exists)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start chatting"].exists)
    }

    @MainActor
    func testFinishedSetupShowsChosenAgentsWithoutSelectingRecipients() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Selected"), evaluatedWith: app.buttons["Choose Fo"])
        waitForExpectations(timeout: 5)
        selectChoice("Fo", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Not selected")
        app.buttons["Continue setup"].click()
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Fo"].exists)
        XCTAssertEqual(app.buttons["Instinct"].value as? String, "Not selected")
        XCTAssertFalse(app.buttons["Add Messages agents"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Edit agents"].click()
        XCTAssertFalse(app.buttons["Restore setup agents"].exists)
        app.buttons["Done editing agents"].click()
        app.buttons["Instinct"].click()
        XCTAssertEqual(app.buttons["Instinct"].value as? String, "Selected")
        app.textViews["Shared prompt"].click()
        app.textViews["Shared prompt"].typeText("Local fixture recipient check")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.textViews["Private reply to Instinct"].waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 10))
        app.buttons["New Blast"].click()
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Blast"].exists, "A saved conversation makes New Blast available")
        XCTAssertFalse(app.buttons["Connect agents"].exists)
    }

    @MainActor
    func testPokeBusinessFixtureMatchesButRequiresExplicitRecipientSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview", "--business-messages-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        chooseAgents(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Selected"), evaluatedWith: app.buttons["Choose Poke"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["Choose Poke"].value as? String, "Selected")
        XCTAssertFalse(app.buttons["Choose conversation"].exists)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["Poke 🌴"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Poke 🌴"].value as? String, "Not selected")
        app.buttons["Poke 🌴"].click()
        XCTAssertEqual(app.buttons["Poke 🌴"].value as? String, "Selected")
    }

    @MainActor
    func testAppsKeepBrowserImportAndManualConnection() {
        let app = launch()
        defer { app.terminate() }
        chooseAgents(in: app)
        selectChoice("Hark Web", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Use your existing logins"].waitForExistence(timeout: 5))
        app.buttons["Skip for now"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect Hark Web"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
    }
}
