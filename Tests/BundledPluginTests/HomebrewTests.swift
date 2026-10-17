// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewTests: XCTestCase {
    private func plugin() throws -> PluginUnderTest { try PluginUnderTest(named: "Homebrew.spinnetplugin", origin: .bundled) }
    private func render(_ helper: PluginTestHelper, command: String = "brew.open", input: JSONValue = .null,
                        event: PluginViewEvent? = nil, state: JSONValue = .null, activities: [JSONValue] = []) throws -> PluginScriptAnswer {
        let services = RecordedHostServices(operations: ["activities.list": .value(.array(activities))])
        let run = helper.run(.init(command, input: input, event: event, state: state), of: try plugin(), answering: services)
        XCTAssertTrue(run.requests.allSatisfy { $0.operation == "activities.list" }, "Only an explicit mutation gesture may snapshot own Tasks; command reads are once-only visible sources")
        return try run.answer()
    }
    private func press(_ action: String = "run-command", values: JSONValue = .null) -> PluginViewEvent {
        .pageActionChosen(page: "homebrew-command", action: action, values: values, selection: .null)
    }
    private func output(_ answer: PluginScriptAnswer) throws -> String {
        guard case .text(let text)? = answer.page?.component("command-output") else { throw NSError(domain: "missing-output", code: 1) }
        XCTAssertTrue(text.isOutput)
        return text.text
    }
    func testEveryShortcutShowsLiteralOutputWithoutOpeningTerminalOrStartingWork() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try plugin()
        XCTAssertEqual(plugin.manifest.version, "2.1.0")
        XCTAssertEqual(plugin.manifest.apiLevel, 6)
        XCTAssertEqual(Set(plugin.manifest.capabilities), [.readReviewedTools, .runReviewedToolTasks])
        XCTAssertNil(plugin.manifest.scope(for: .controlExternalApp))
        for command in plugin.manifest.commands {
            let answer = try render(helper, command: command.id.rawValue)
            XCTAssertEqual(answer.page?.id, "homebrew-command")
            XCTAssertTrue(answer.page?.sources.isEmpty == true)
            XCTAssertNil(answer.operation)
            XCTAssertNotNil(answer.page?.component("command-preview"))
            XCTAssertNil(answer.page?.collection)
            _ = try output(answer)
        }
    }
    func testReadRunsOnceAndShowsNativeTextAndTheRealExitStatusInsideThePage() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.version")
        let run = try render(helper, command: "brew.version", event: press(), state: opened.state)
        XCTAssertNil(run.operation)
        let source = try XCTUnwrap(run.page?.sources.first)
        XCTAssertEqual(source.input, .object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")]))
        let raw = "Homebrew native output\n**literal** [not a link](https://example.com)\n  Warning: diagnostic"
        let result: JSONValue = .object(["output": .string(raw), "exit_status": .number(1), "output_truncated": .bool(false)])
        let finished = try render(helper, command: "brew.version", event: .sourceDelivered(page: "homebrew-command", source: source.id, sequence: 1, result: result, failure: nil), state: run.state)
        XCTAssertEqual(try output(finished), raw)
        XCTAssertNil(finished.operation); XCTAssertTrue(finished.page?.sources.isEmpty == true)
        guard case .text(let status)? = finished.page?.component("command-status") else { return XCTFail("Native exit status is required") }
        XCTAssertTrue(status.text.contains("status 1"))
    }
    func testUpgradeUsesTheReviewedTaskAndStreamsItsOwnNativeTextWithoutPackageComponents() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let old: JSONValue = .object(["id": .string("old"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string("old output")])
        let opened = try render(helper, command: "brew.upgrade", input: .object(["package": .string("firefox")]))
        let run = try render(helper, command: "brew.upgrade", event: press(values: .object(["kind": .string("cask")])), state: opened.state, activities: [old])
        XCTAssertEqual(run.operation?.perform, "tools.startTask")
        XCTAssertEqual(run.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("firefox")]))
        let admitted = try render(helper, event: .operationFinished(id: "command-task", perform: "tools.startTask", outcome: .succeeded), state: run.state)
        let raw = "==> Downloading firefox\n[########            ] 40%\n" + String(repeating: "original text ", count: 70)
        let current: JSONValue = .object(["id": .string("activity_0123456789abcdef0123456789abcdef"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("running"), "output": .string(raw), "log": .array([.string("short summary")])])
        let streaming = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: "command-tasks", sequence: 1, result: .array([old, current]), failure: nil), state: admitted.state)
        XCTAssertEqual(try output(streaming), raw)
        XCTAssertNil(streaming.operation); XCTAssertNotNil(streaming.page?.component("stop"))
        XCTAssertNil(streaming.page?.collection)
        let stop = try render(helper, event: press("stop-command"), state: streaming.state)
        XCTAssertEqual(stop.operation?.perform, "activities.stop")
        XCTAssertEqual(stop.operation?.input, .object(["id": .string("activity_0123456789abcdef0123456789abcdef")]))
        let ended: JSONValue = .object(["id": .string("activity_0123456789abcdef0123456789abcdef"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string(raw + "\nDone"), "result": .object(["outcome": .string("completed"), "exit_status": .number(0)])])
        let finished = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: "command-tasks", sequence: 2, result: .array([old, ended]), failure: nil), state: streaming.state)
        XCTAssertTrue(try output(finished).hasSuffix("Done"))
        XCTAssertNil(finished.operation); XCTAssertTrue(finished.page?.sources.isEmpty == true)
        XCTAssertNil(finished.page?.component("stop"))
    }
    func testDeclinedTaskNeverAttachesToAnotherTaskOrReplaysTheCommand() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.update")
        let run = try render(helper, command: "brew.update", event: press(), state: opened.state)
        let finished = try render(helper, event: .operationFinished(id: "command-task", perform: "tools.startTask", outcome: .declined), state: run.state)
        XCTAssertNil(finished.operation); XCTAssertTrue(finished.page?.sources.isEmpty == true)
        let unrelated: JSONValue = .object(["id": .string("unrelated"), "tool": .string("homebrew"), "kind": .string("task"), "status": .string("running"), "output": .string("unrelated output")])
        let stale = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: "command-tasks", sequence: 1, result: .array([unrelated]), failure: nil), state: finished.state)
        XCTAssertFalse(try output(stale).contains("unrelated output"))
        XCTAssertNil(stale.operation)
    }
    func testCancelReadRemovesTheSourceAndLateResultsCannotReplaceOutput() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.version")
        let run = try render(helper, command: "brew.version", event: press(), state: opened.state)
        let source = try XCTUnwrap(run.page?.sources.first)
        let cancelled = try render(helper, event: press("cancel-read"), state: run.state)
        XCTAssertNil(cancelled.operation); XCTAssertTrue(cancelled.page?.sources.isEmpty == true)
        let late = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: source.id, sequence: 1, result: .object(["output": .string("late output"), "exit_status": .number(0)]), failure: nil), state: cancelled.state)
        XCTAssertFalse(try output(late).contains("late output"))
    }
    func testInvalidInputAndSourceDeliveriesNeverStartAMutation() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for package in ["", "foo; touch /tmp/should-not-run", "--force", "x\ny"] {
            let opened = try render(helper, command: "brew.install", input: .object(["package": .string(package)]))
            XCTAssertNotNil(opened.page?.component("input-help")); XCTAssertNil(opened.page?.component("execute"))
            XCTAssertNil(try render(helper, event: press(), state: opened.state).operation)
        }
        let opened = try render(helper, command: "brew.update")
        let background = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: "old-source", sequence: 1, result: .null, failure: nil), state: opened.state)
        XCTAssertNil(background.operation); XCTAssertTrue(background.page?.sources.isEmpty == true)
    }
    func testAdoptionNeedsAReviewedPreviewAndAnotherExplicitRunBeforeStarting() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.adopt", input: .object(["package": .string("firefox")]))
        let run = try render(helper, command: "brew.adopt", event: press(), state: opened.state)
        XCTAssertNil(run.operation)
        let candidatesSource = try XCTUnwrap(run.page?.sources.first)
        let candidates: JSONValue = .object(["applications": .array([.object(["target": .string("app_candidate"), "candidates": .array([.object(["name": .string("firefox"), "confidence": .string("ready")])])])])])
        let preview = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: candidatesSource.id, sequence: 1, result: candidates, failure: nil), state: run.state)
        XCTAssertNil(preview.operation)
        let previewSource = try XCTUnwrap(preview.page?.sources.first)
        XCTAssertEqual(previewSource.input.value(atPointer: "/operation"), .string("adoptionPreview"))
        let ready = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: previewSource.id, sequence: 1, result: .object(["succeeded": .bool(true), "target": .string("adoption_reviewed"), "stdout": .string("Original adoption preview")]), failure: nil), state: preview.state)
        XCTAssertNil(ready.operation); XCTAssertEqual(try output(ready), "Original adoption preview")
        let confirmed = try render(helper, event: press(), state: ready.state)
        XCTAssertEqual(confirmed.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("adopt"), "target": .string("adoption_reviewed")]))
    }
    func testLargeUnicodeOutputStaysWithinStateBudgetAndDisclosesTruncation() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.version")
        let run = try render(helper, event: press(), state: opened.state)
        let source = try XCTUnwrap(run.page?.sources.first)
        let finished = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: source.id, sequence: 1, result: .object(["output": .string(String(repeating: "下载🙂\n", count: 10000)), "exit_status": .number(0)]), failure: nil), state: run.state)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(finished.state).count, ScriptedActionBudgets.viewStateBytes)
        XCTAssertNotNil(finished.page?.component("output-limit"))
    }
    func testLegacyMenuCommandsRemainPresentWithExplicitRetirementGuidance() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for command in ["brew.vulnerabilities", "brew.clear-cache"] {
            let opened = try render(helper, command: command)
            XCTAssertNotNil(opened.page?.component("legacy-command")); XCTAssertNil(opened.operation)
        }
        let ids = Set(try plugin().manifest.commands.map(\.id.rawValue))
        XCTAssertTrue(ids.isSuperset(of: ["brew.open","brew.installed","brew.search","brew.outdated","brew.vulnerabilities","brew.doctor","brew.adopt","brew.upgrade","brew.services","brew.taps","brew.services-menu","brew.cleanup","brew.clear-cache","brew.autoremove"]))
    }
}
