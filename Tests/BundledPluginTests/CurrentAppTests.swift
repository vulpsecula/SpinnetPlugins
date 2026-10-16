import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class CurrentAppTests: XCTestCase {
    var plugin: PluginUnderTest!
    var helper: PluginTestHelper!
    var apps: RecordedApps!
    var services: RecordedHostServices!

    override func setUpWithError() throws {
        plugin = try PluginUnderTest(named: "CurrentApp.spinnetplugin", origin: .bundled)
        helper = try PluginTestHelper()
        apps = RecordedApps(front: .textEdit, running: [.safari])
        services = RecordedHostServices(apps: apps)
    }

    override func tearDown() { helper?.shutdown() }

    func run(_ invocation: PluginTestInvocation) -> PluginTestRun {
        helper.run(invocation, of: plugin, answering: services)
    }

    func open() throws -> PluginScriptAnswer { try run(PluginTestInvocation("current.inspect")).answer() }

    func value(_ json: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let values) = json else { return nil }
        return values[key]
    }

    func text(_ json: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
    }

    func record(_ run: PluginTestRun, as name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CURRENT_APP_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run.result.get()).write(to: directory.appendingPathComponent(name + ".json"))
    }

    func choose(_ id: String, in answer: PluginScriptAnswer, command: String = "current.inspect") -> PluginTestInvocation {
        PluginTestInvocation(command, event: .pageActionChosen(page: "current", action: id,
                            values: .object([:]), selection: .object([:])),
                            state: answer.state, view: answer.pageJSON)
    }

    func testOpeningDisclosesOnlyTheWorkingAppAndPerformsNoExit() throws {
        let invocation = PluginTestInvocation("current.inspect")
        let opened = run(invocation)
        try record(opened, as: "opening")
        let answer = try opened.answer()
        XCTAssertEqual(value(value(answer.state, "app") ?? .null, "name"), .string("TextEdit"))
        XCTAssertEqual(answer.page?.id, "current")
        XCTAssertEqual(opened.performed.map(\.id), ["apps.frontmost"])
        XCTAssertNil(answer.operation)
        XCTAssertEqual(apps.exits, [])
    }

    func testCloseClosesOnlyTheDisclosedAppsWindowWithoutConfirmation() throws {
        let opened = try open()
        let invocation = choose("close", in: opened)
        let close = run(invocation)
        try record(close, as: "close")
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(close, of: plugin, for: invocation))
        XCTAssertEqual(performed.perform, "apps.close")
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertNil(performed.confirmation)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .close)])
        XCTAssertTrue(apps.isRunning(.textEdit))
    }

    func testQuitQuitsOnlyTheDisclosedAppWithoutConfirmation() throws {
        let opened = try open()
        let invocation = choose("quit", in: opened)
        let requested = run(invocation)
        try record(requested, as: "quit")
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(requested, of: plugin, for: invocation))
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertNil(performed.confirmation)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
        XCTAssertTrue(apps.isRunning(.safari))
    }

    func testForceQuitRequiresHostConfirmationAndCanBeDeclined() throws {
        let opened = try open()
        let invocation = choose("force", in: opened)
        let requested = run(invocation)
        try record(requested, as: "force")
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps, confirmation: .declined)
            .perform(requested, of: plugin, for: invocation))
        XCTAssertEqual(performed.outcome, .declined)
        XCTAssertEqual(performed.confirmation?.title, "Force Quit TextEdit?")
        XCTAssertEqual(apps.exits, [])
    }

    func testAConfirmedForceQuitEndsOnlyTheDisclosedAppEvenWithoutAccessibility() throws {
        apps.isAccessibilityTrusted = false
        let opened = try open()
        let invocation = choose("force", in: opened)
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps)
            .perform(run(invocation), of: plugin, for: invocation))
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertEqual(performed.confirmation?.title, "Force Quit TextEdit?")
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .forceQuit)])
        XCTAssertFalse(apps.isRunning(.textEdit))
        XCTAssertTrue(apps.isRunning(.safari))
    }

    func testACompletionAfterTheViewClosedDoesNotReopenItOrExitAgain() throws {
        let opened = try open()
        let finished = PluginTestInvocation("current.inspect", event: .operationFinished(
            id: "quit", perform: "apps.quit", outcome: .succeeded, viewClosed: true), state: opened.state)
        let completed = try run(finished).answer()
        XCTAssertNil(completed.page)
        XCTAssertNil(completed.operation)
        XCTAssertEqual(apps.exits, [])
    }

    func testChangingTheWorkingAppKeepsTheDisclosedTargetAndAsksBeforeQuit() throws {
        let opened = try open()
        apps.bringToFront(.safari)
        let invocation = choose("quit", in: opened)
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run(invocation), of: plugin, for: invocation))
        XCTAssertEqual(performed.confirmation?.title, "Quit TextEdit?")
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
        XCTAssertTrue(apps.isRunning(.safari))
    }

    func testRelaunchReusingTheProcessIDRefusesInsteadOfRetargeting() throws {
        let opened = try open()
        apps.relaunch(.textEdit)
        let invocation = choose("quit", in: opened)
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run(invocation), of: plugin, for: invocation))
        XCTAssertEqual(performed.outcome, .refused(.noTarget))
        XCTAssertEqual(apps.exits, [])
    }

    func testAnAppThatExitsDuringConfirmationCannotBeReplacedByAnotherApp() throws {
        let opened = try open()
        let invocation = choose("force", in: opened)
        let operations = RecordedHostOperations(apps: apps)
        operations.whileConfirming = { self.apps.quit(.textEdit); self.apps.bringToFront(.safari) }
        XCTAssertEqual(try operations.perform(run(invocation), of: plugin, for: invocation)?.outcome, .refused(.noTarget))
        XCTAssertEqual(apps.exits, [])
    }

    func testRevokingExitWhileTheHostConfirmsPreventsTheExit() throws {
        let opened = try open()
        let invocation = choose("force", in: opened)
        let operations = RecordedHostOperations(apps: apps)
        operations.whileConfirming = { operations.deniedCapabilities.insert(.quitFrontmostApp) }
        XCTAssertEqual(try operations.perform(run(invocation), of: plugin, for: invocation)?.outcome, .refused(.capabilityDenied))
        XCTAssertEqual(apps.exits, [])
    }

    func testDeniedReadAndExitAreSeparateCapabilities() throws {
        let deniedRead = RecordedHostServices(operations: ["apps.frontmost": .failure(.capabilityDenied(.readFrontmostApp))], apps: apps)
        XCTAssertThrowsError(try helper.run(PluginTestInvocation("current.inspect"), of: plugin, answering: deniedRead).answer())
        let opened = try open()
        let invocation = choose("quit", in: opened)
        let operations = RecordedHostOperations(deniedCapabilities: [.quitFrontmostApp], apps: apps)
        XCTAssertThrowsError(try operations.perform(run(invocation), of: plugin, for: invocation))
        XCTAssertEqual(apps.exits, [])
    }

    func testTheHostRechecksTheMenuAndAccessibilityBeforeClosing() throws {
        let opened = try open()
        let invocation = choose("close", in: opened)
        let requested = run(invocation)
        apps.offer([.quit], in: .textEdit)
        XCTAssertEqual(try RecordedHostOperations(apps: apps).perform(requested, of: plugin, for: invocation)?.outcome,
                       .refused(.targetProtected))
        apps.isAccessibilityTrusted = false
        XCTAssertEqual(try RecordedHostOperations(apps: apps).perform(requested, of: plugin, for: invocation)?.outcome,
                       .refused(.systemPermissionDenied))
        XCTAssertEqual(apps.exits, [])
    }

    func testNoAppAndUnavailableExitsNeverCreateRequests() throws {
        apps.bringToFront(nil)
        let none = try open()
        XCTAssertNil(try run(choose("quit", in: none)).answer().operation)
        apps.bringToFront(.finder)
        let finder = try open()
        XCTAssertNil(try run(choose("quit", in: finder)).answer().operation)
        XCTAssertEqual(apps.exits, [])
    }

    func testAnUnansweredForceQuitExpiresWithoutExiting() throws {
        let opened = try open()
        let invocation = choose("force", in: opened)
        XCTAssertEqual(try RecordedHostOperations(apps: apps, confirmation: nil)
            .perform(run(invocation), of: plugin, for: invocation)?.outcome, .expired)
        XCTAssertEqual(apps.exits, [])
    }

    func testTargetStateSurvivesHelperRetirementWithoutReadingAnotherApp() throws {
        let opened = try open()
        helper.retireHelper(of: plugin)
        let launches = helper.launchCount
        apps.bringToFront(.safari)
        let invocation = choose("close", in: opened)
        let continued = run(invocation)
        XCTAssertEqual(helper.launchCount, launches + 1)
        XCTAssertEqual(continued.performed, [])
        XCTAssertEqual(try continued.answer().operation?.input,
                       .object(["target": try XCTUnwrap(value(value(opened.state, "app") ?? .null, "target"))]))
    }

    func testACompletionNeverLoopsOrChangesTheTargetSilently() throws {
        let opened = try open()
        apps.bringToFront(.safari)
        let finished = PluginTestInvocation("current.inspect", event: .operationFinished(
            id: "force", perform: "apps.quit", outcome: .declined), state: opened.state, view: opened.pageJSON)
        let completed = run(finished)
        XCTAssertNil(try completed.answer().operation)
        XCTAssertEqual(try completed.answer().state, opened.state)
        XCTAssertEqual(completed.performed, [])
    }

    func testActualHelperPayloadAndInvocationBudgets() throws {
        var milliseconds: [Double] = []
        var maximumState = 0, maximumPage = 0
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            let answer = try open()
            milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            maximumState = max(maximumState, PluginScriptAnswer.encodedSize(of: answer.state))
            maximumPage = max(maximumPage, PluginScriptAnswer.encodedSize(of: try XCTUnwrap(answer.pageJSON)))
        }
        let cold = milliseconds.removeFirst()
        let sorted = milliseconds.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("CURRENT_APP_BUDGET version=\(plugin.manifest.version) cold_ms=\(cold) warm_p95_ms=\(p95) state_bytes=\(maximumState) page_bytes=\(maximumPage) helper_launches=\(helper.launchCount)")
        XCTAssertLessThan(cold, 4_000)
        XCTAssertLessThan(milliseconds.max() ?? .infinity, 4_000)
        XCTAssertLessThan(maximumState, 64 * 1_024)
        XCTAssertLessThan(maximumPage, 256 * 1_024)
        XCTAssertEqual(helper.launchCount, 1)
    }
}
