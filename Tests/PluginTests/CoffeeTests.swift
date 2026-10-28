// SPDX-License-Identifier: MIT
// Ported from the accepted external Keep Awake 1.0.3 proof (4a7ab74, #90).
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class CoffeeTests: XCTestCase {
    func testLiveTimedActivityCountsSecondsAndStopsWithoutRunningThePlugin() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let recorded = RecordedKeepAwake()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let create = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: services)
        try create.open()
        try create.choose("duration", in: "mode")
        try create.type("1", into: "minutes")
        let start = PluginTestInvocation("coffee.open", event: .actionChosen("start"), state: create.state)
        let run = helper.run(start, of: plugin, answering: services)
        _ = try RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: start)
        let page = PluginTestPage("coffee.activities", of: plugin, helper: helper, answering: services)
        try page.open()
        let runCount = page.runs.count
        guard case .array(let rows) = try page.activityRows(), case .object(let row)? = rows.first else {
            return XCTFail("No live Host activity was shown")
        }
        XCTAssertEqual(row["status"], .string("1m 00s remaining"))
        guard case .string(let id)? = row["id"] else { return XCTFail("Missing Host activity ID") }
        recorded.advance(by: 1)
        guard case .array(let laterRows) = try page.activityRows(), case .object(let later)? = laterRows.first else {
            return XCTFail("Activity disappeared before expiry")
        }
        XCTAssertEqual(later["status"], .string("59s remaining"))
        XCTAssertEqual(page.runs.count, runCount)
        XCTAssertTrue(page.events.isEmpty)
        try page.stopActivity(id)
        XCTAssertEqual(try page.activityRows(), .array([]))
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(page.runs.count, runCount)
        XCTAssertTrue(page.events.isEmpty)
        _ = try RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: start)
        recorded.advance(by: 60)
        XCTAssertEqual(try page.activityRows(), .array([]))
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(page.runs.count, runCount)
        XCTAssertTrue(page.events.isEmpty)
    }

    func testChoicePageShowsOnlyFieldsRelevantToTheSelectedMode() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper)
        try page.open()
        XCTAssertFalse(page.page?.components.contains { $0.id == "minutes" } ?? true)
        XCTAssertFalse(page.page?.components.contains { $0.id == "app-policy" } ?? true)
        try page.choose("duration", in: "mode")
        XCTAssertTrue(page.page?.components.contains { $0.id == "minutes" } ?? false)
        XCTAssertFalse(page.page?.components.contains { $0.id == "app-policy" } ?? true)
        try page.type("5", into: "minutes")
        try page.choose("app_alive", in: "mode")
        XCTAssertFalse(page.page?.components.contains { $0.id == "minutes" } ?? true)
        XCTAssertTrue(page.page?.components.contains { $0.id == "app-policy" } ?? false)
        try page.choose("duration", in: "mode")
        XCTAssertEqual(page.text(of: "minutes"), "5")
    }

    func testDeniedStartReturnsHostGuidanceAndNeverRequestsAgainAutomatically() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: RecordedHostServices(keepAwake: RecordedKeepAwake()))
        page.operationOutcomes["system.keepAwake"] = .refused(.capabilityDenied)
        try page.open()
        try page.choose("duration", in: "mode")
        try page.type("5", into: "minutes")
        try page.click("start")
        XCTAssertFalse(page.isClosed)
        XCTAssertEqual(page.page?.id, "coffee")
        XCTAssertEqual(page.choice(of: "mode"), "duration")
        XCTAssertEqual(page.text(of: "minutes"), "5")
        XCTAssertEqual(page.toasts.last, "Keep Awake’s access was denied or revoked. Review its Capabilities in Privacy & Permissions.")
        XCTAssertEqual(page.performed.count, 1)
        try page.choose("manual", in: "mode")
        XCTAssertEqual(page.performed.count, 1)
        XCTAssertEqual(page.choice(of: "mode"), "manual")
    }

    func testNoCurrentAppOffersRecoveryInsteadOfStartingAnEffect() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let answer = try helper.run(PluginTestInvocation("coffee.app"), of: plugin, answering: RecordedHostServices(
            operations: ["apps.frontmost": .value(.null)], keepAwake: RecordedKeepAwake())).answer()
        XCTAssertEqual(answer.page?.id, "coffee")
        XCTAssertEqual(answer.toast, "No App in front. Switch to an ordinary App, then start again.")
        XCTAssertNil(answer.operation)
    }

    func testOptInExportOfRealHelperAnswersForPublicSchemaValidation() throws {
        guard let directory = ProcessInfo.processInfo.environment["COFFEE_ANSWERS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set COFFEE_ANSWERS_DIR to export real helper answers for a separate public-schema check")
        }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin"), helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: RecordedKeepAwake(apps: RecordedApps(front: .textEdit)))
        for command in ["coffee.open", "coffee.manual", "coffee.timed", "coffee.app", "coffee.activities"] {
            let run = helper.run(PluginTestInvocation(command), of: plugin, answering: services)
            try JSONEncoder().encode(run.result.get()).write(to: root.appendingPathComponent(command + ".json"))
        }
    }
    func testAppAccessDenialKeepsManualAndTimedModesUsable() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(operations: ["apps.frontmost": .failure(.capabilityDenied(.readFrontmostApp))],
                                            keepAwake: RecordedKeepAwake())
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: services)
        try page.open()
        try page.choose("app_alive", in: "mode")
        try page.click("start")
        XCTAssertEqual(page.page?.id, "coffee")
        XCTAssertEqual(page.toasts.last, "Keep Awake cannot read the current App. Grant Identify the App in Front in Privacy & Permissions, or choose another mode.")
        XCTAssertTrue(page.performed.isEmpty)
        try page.choose("manual", in: "mode")
        try page.click("start")
        XCTAssertEqual(page.performed.last?.input, .object(["mode": .string("manual")]))
    }
    func testActivityStopUsesHostIDAndPinnedStartShowsCurrentActivity() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let recorded = RecordedKeepAwake()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let invoke = PluginTestInvocation("coffee.manual")
        let run = helper.run(invoke, of: plugin, answering: services)
        let performer = RecordedHostOperations(keepAwake: recorded)
        let started = try XCTUnwrap(performer.perform(run, of: plugin, for: invoke))
        let completed = try helper.run(PluginTestInvocation("coffee.manual", event: started.delivery, state: run.answer().state),
                                       of: plugin, answering: services).answer()
        XCTAssertEqual(completed.page?.id, "activities")
        let page = PluginTestPage("coffee.activities", of: plugin, helper: helper, answering: services)
        try page.open()
        guard case .array(let rows) = try page.activityRows(), case .object(let row)? = rows.first,
              case .string(let id)? = row["id"] else { return XCTFail("No current Host activity was shown") }
        let runCount = page.runs.count
        try page.stopActivity(id)
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(try page.activityRows(), .array([]))
        XCTAssertEqual(page.runs.count, runCount)
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertThrowsError(try page.click("refresh"), "Host activity control updates without a Plugin refresh")
        XCTAssertThrowsError(try page.click("back"), "Read-only activities Command must not expose a start with no keep_awake scope")
    }
    func testPinnedStartShowsActivitiesDirectlyAndAllowsAnotherCreation() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper)
        page.isPinned = true
        try page.open()
        try page.choose("duration", in: "mode")
        try page.type("5", into: "minutes")
        try page.click("start")
        XCTAssertFalse(page.isClosed)
        XCTAssertEqual(page.page?.id, "activities")
        XCTAssertTrue(page.page?.components.contains { $0.id == "held" } ?? false)
        try page.click("back")
        XCTAssertEqual(page.page?.id, "coffee")
        XCTAssertEqual(page.choice(of: "mode"), "duration")
        XCTAssertEqual(page.text(of: "minutes"), "5")
        XCTAssertEqual(page.performed.count, 1)
    }

    func testInvalidDurationDoesNotRequestAnEffectAndAllowsCorrection() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper)
        try page.open()
        try page.choose("duration", in: "mode")
        for invalid in ["0", "1441", "1.5", "", "one"] {
            try page.type(invalid, into: "minutes")
            try page.click("start")
            XCTAssertTrue(page.performed.isEmpty)
            XCTAssertEqual(page.toasts.last, "Enter a whole number of minutes from 1 to 1440.")
        }
        try page.type("1", into: "minutes")
        try page.click("start")
        XCTAssertEqual(page.performed.last?.input, .object(["mode": .string("duration"), "seconds": .number(60)]))
        XCTAssertTrue(page.isClosed)
        XCTAssertEqual(page.afterClose.count, 1)
    }
    func testReadyPresetOpensChoiceFlowWithoutStartingAnEffect() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: RecordedHostServices(keepAwake: RecordedKeepAwake()))
        try page.open()
        XCTAssertEqual(page.page?.id, "coffee")
        XCTAssertEqual(page.choice(of: "mode"), "manual")
        XCTAssertEqual(page.performed.count, 0)
    }
    func testManualStartContinuesAfterHelperRetirementAndReopensWithAStop() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let recorded = RecordedKeepAwake()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let opened = try helper.run(PluginTestInvocation("coffee.open"), of: plugin, answering: services).answer()
        let start = PluginTestInvocation("coffee.open", event: .actionChosen("start"), state: opened.state)
        let run = helper.run(start, of: plugin, answering: services)
        XCTAssertEqual(try run.answer().operation?.input, .object(["mode": .string("manual")]))
        XCTAssertEqual(try RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: start)?.outcome, .succeeded)
        helper.retireHelper(of: plugin)
        XCTAssertEqual(recorded.power.count, 2)
        let reopened = PluginTestPage("coffee.activities", of: plugin, helper: helper, answering: services)
        try reopened.open()
        XCTAssertEqual(reopened.page?.id, "activities")
        guard case .array(let rows) = try reopened.activityRows() else { return XCTFail("No activity rows") }
        XCTAssertEqual(rows.count, 1)
    }
    func testDurationChoiceUsesMinutesAndHostExpiresWhileHelperIsGone() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let recorded = RecordedKeepAwake()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: services)
        try page.open()
        try page.choose("duration", in: "mode")
        try page.type("5", into: "minutes")
        let invoke = PluginTestInvocation("coffee.open", event: .actionChosen("start"), state: page.state)
        let run = helper.run(invoke, of: plugin, answering: services)
        XCTAssertEqual(try run.answer().operation?.input, .object(["mode": .string("duration"), "seconds": .number(300)]))
        _ = try RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: invoke)
        helper.shutdown()
        XCTAssertEqual(recorded.power.count, 2)
        recorded.advance(by: 299)
        XCTAssertEqual(recorded.power.count, 2)
        recorded.advance(by: 1)
        XCTAssertEqual(recorded.power.count, 0)
    }
    func testAppModeBindsAppAtStartAndEndsOnThatAppExit() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let recorded = RecordedKeepAwake(apps: apps)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let page = PluginTestPage("coffee.open", of: plugin, helper: helper, answering: services)
        try page.open()
        try page.choose("app_alive", in: "mode")
        apps.bringToFront(.safari)
        let start = PluginTestInvocation("coffee.open", event: .actionChosen("start"), state: page.state)
        let run = helper.run(start, of: plugin, answering: services)
        guard case .object(let args)? = try run.answer().operation?.input else { return XCTFail("Missing App binding") }
        XCTAssertEqual(args["mode"], .string("app_alive"))
        XCTAssertNotNil(args["target"])
        _ = try RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: start)
        helper.shutdown()
        apps.quit(.textEdit)
        XCTAssertEqual(recorded.power.count, 2)
        apps.quit(.safari)
        XCTAssertEqual(recorded.power.count, 0)
    }
    func testAlternatePresetsExecuteTheirOwnModeOnInitialAndRepeatedCalls() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let recorded = RecordedKeepAwake(apps: RecordedApps(front: .textEdit))
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        for called in [false, true] {
            for (command, mode, seconds) in [("coffee.manual", "manual", nil), ("coffee.timed", "duration", 1800), ("coffee.app", "app_alive", nil)] as [(String, String, Int?)] {
                let invoke = PluginTestInvocation(command, event: called ? .called : nil,
                    state: .object(["mode": .string("duration"), "minutes": .string("999"), "screen": .string("activities")]))
                let run = helper.run(invoke, of: plugin, answering: services)
                guard case .object(let args)? = try run.answer().operation?.input else { return XCTFail("Preset did not start: \(command)") }
                XCTAssertEqual(args["mode"], .string(mode))
                if let seconds { XCTAssertEqual(args["seconds"], .number(Double(seconds))) }
                if mode == "app_alive" { XCTAssertNotNil(args["target"]) }
            }
        }
    }
    func testAppExitingBeforeStartGivesClearFailureWithoutAcquiringPower() throws {
        let plugin = try PluginUnderTest(named: "KeepAwake.spinnetplugin")
        let apps = RecordedApps(front: .textEdit)
        let recorded = RecordedKeepAwake(apps: apps)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let services = RecordedHostServices(keepAwake: recorded)
        let start = PluginTestInvocation("coffee.app")
        let run = helper.run(start, of: plugin, answering: services)
        apps.quit(.textEdit)
        let outcome = try XCTUnwrap(RecordedHostOperations(keepAwake: recorded).perform(run, of: plugin, for: start))
        XCTAssertEqual(outcome.outcome, .failed(.hostServiceFailed))
        XCTAssertEqual(recorded.power.count, 0)
        let completed = try helper.run(PluginTestInvocation("coffee.app", event: outcome.delivery, state: run.answer().state),
            of: plugin, answering: services).answer()
        XCTAssertEqual(completed.toast, "The Host could not start the effect. No new keep-awake effect was created.")
        XCTAssertNil(completed.operation)
    }
}
