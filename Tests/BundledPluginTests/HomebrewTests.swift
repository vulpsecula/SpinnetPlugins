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
        XCTAssertEqual(plugin.manifest.version, "2.2.0")
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
            XCTAssertNotNil(answer.page?.component("command-empty"))
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

    private func readResult(_ helper: PluginTestHelper, command: String = "brew.open", text: String,
                            exit: Int = 0, truncated: Bool = false) throws -> PluginScriptAnswer {
        let opened = try render(helper, command: command)
        let run = try render(helper, command: command, event: press(), state: opened.state)
        let source = try XCTUnwrap(run.page?.sources.first)
        return try render(helper, command: command, event: .sourceDelivered(page: "homebrew-command", source: source.id, sequence: 1,
            result: .object(["output": .string(text), "exit_status": .number(Double(exit)), "output_truncated": .bool(truncated)]), failure: nil), state: run.state)
    }
    func testInstalledListFiltersPagesAndKeepsNativeOutputWithoutReadingAgain() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let native = (0..<350).map { "package-\($0)" }.joined(separator: "\n")
        let result = try readResult(helper, text: native)
        let list = try XCTUnwrap(result.page?.collection)
        XCTAssertEqual(list.style, .list); XCTAssertEqual(list.total, 350); XCTAssertEqual(list.items.count, 80)
        XCTAssertTrue(list.items.allSatisfy { $0.subtitle?.isEmpty == true }, "Flat native output does not identify Formulae versus Casks")
        let next = try render(helper, event: .loadRange(page: "homebrew-command", collection: list.id, start: 200, count: 100), state: result.state)
        XCTAssertEqual(next.page?.collection?.start, 200); XCTAssertEqual(next.page?.collection?.items.first?.title, "package-200")
        XCTAssertNil(next.operation); XCTAssertTrue(next.page?.sources.isEmpty == true)
        let filtered = try render(helper, event: .pageFieldChanged(page: "homebrew-command", field: "filter-1", values: .object(["filter-1": .string("package-349")])), state: next.state)
        XCTAssertEqual(filtered.page?.collection?.total, 1)
        XCTAssertEqual(filtered.page?.collection?.items.first?.id, "result-349")
        let raw = try render(helper, event: .pageFieldChanged(page: "homebrew-command", field: "display", values: .object(["display": .string("raw")])), state: filtered.state)
        XCTAssertEqual(try output(raw), native); XCTAssertNil(raw.page?.collection)
        XCTAssertNil(raw.operation); XCTAssertTrue(raw.page?.sources.isEmpty == true)
    }
    func testSearchGroupsAndUpdateVersionsBecomeReadableRows() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.search", input: .object(["package": .string("fire")]))
        let run = try render(helper, event: press(), state: opened.state)
        let source = try XCTUnwrap(run.page?.sources.first)
        let found = try render(helper, event: .sourceDelivered(page: "homebrew-command", source: source.id, sequence: 1,
            result: .object(["output": .string("==> Formulae\nfirefoxpwa  firejail ✔\n==> Casks\nfirefox ✔  firefox@beta\n"), "exit_status": .number(0)]), failure: nil), state: run.state)
        let rows = try XCTUnwrap(found.page?.collection?.items)
        XCTAssertEqual(rows.map(\.title), ["firefoxpwa", "firejail", "firefox", "firefox@beta"])
        XCTAssertEqual(rows.map(\.subtitle), ["Formula", "Formula", "Cask App", "Cask App"])
        XCTAssertEqual(rows[2].accessory, "Installed")
        let updates = try readResult(helper, command: "brew.outdated", text: "wget (1.24.5) < 1.25.0\nfirefox\n")
        XCTAssertEqual(updates.page?.collection?.items.first?.subtitle, "1.24.5 → 1.25.0")
        XCTAssertEqual(updates.page?.collection?.items.last?.accessory, "Update")
    }
    func testConfigurationServicesAndTapsUseListsAndKeepDetails() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let config = try readResult(helper, command: "brew.config", text: "HOMEBREW_VERSION: 5.0.0\nCPU: 10-core 64-bit arm64\nmacOS: 26.0-arm64\n")
        XCTAssertEqual(config.page?.collection?.items.map(\.title), ["HOMEBREW_VERSION", "CPU", "macOS"])
        XCTAssertEqual(config.page?.collection?.items[1].subtitle, "10-core 64-bit arm64")
        let services = try readResult(helper, command: "brew.services", text: "Name Status User File\nredis started zeke ~/Library/LaunchAgents/homebrew.mxcl.redis.plist\npostgresql@17 none\nmysql error 256 zeke ~/Library/LaunchAgents/mysql.plist\n")
        XCTAssertEqual(services.page?.collection?.items.map(\.accessory), ["started", "none", "error 256"])
        XCTAssertTrue(services.page?.collection?.items.first?.subtitle?.contains("LaunchAgents") == true)
        let taps = try readResult(helper, command: "brew.taps", text: "homebrew/core\nuser/custom-tap\n")
        XCTAssertEqual(taps.page?.collection?.items.map(\.title), ["homebrew/core", "user/custom-tap"])
    }
    func testDiagnosticsUnknownFormatsAndPartialReadsAlwaysRemainLiteral() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (command, text, exit, truncated) in [
            ("brew.open", "wget\nWarning: preserve this diagnostic", 0, false),
            ("brew.open", "/opt/homebrew/Cellar/wget/1.25/bin/wget", 0, false),
            ("brew.open", "wget\n", 1, false),
            ("brew.open", "wget\n", 0, true),
            ("brew.config", "CPU: arm64\n  continued native detail", 0, false),
            ("brew.services", "Name Status User File\nredis unexpected-status", 0, false)
        ] {
            let result = try readResult(helper, command: command, text: text, exit: exit, truncated: truncated)
            XCTAssertNil(result.page?.collection); XCTAssertEqual(try output(result), text)
        }
    }
    func testChangingNextCommandDoesNotReinterpretPreviousResults() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result = try readResult(helper, text: "wget\nfirefox\n")
        let changed = try render(helper, event: .pageFieldChanged(page: "homebrew-command", field: "command", values: .object(["command": .string("config"), "kind": .string("cask")])), state: result.state)
        XCTAssertEqual(changed.page?.collection?.items.map(\.title), ["wget", "firefox"])
        XCTAssertTrue(changed.page?.collection?.items.allSatisfy { $0.subtitle?.isEmpty == true } == true)
        XCTAssertNil(changed.operation); XCTAssertTrue(changed.page?.sources.isEmpty == true)
    }
    func testPackageInfoRequiresAnExplicitRowActionAndNeverStartsATask() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result = try readResult(helper, text: "wget\nfirefox\n")
        let id = try XCTUnwrap(result.page?.collection?.id)
        let inspected = try render(helper, event: .itemAction(page: "homebrew-command", collection: id, action: "package-info", item: .init(id: "result-1", section: nil, text: "firefox"), values: .object([:])), state: result.state)
        XCTAssertNil(inspected.operation)
        XCTAssertEqual(inspected.page?.sources.first?.input.value(atPointer: "/command"), .string("info"))
        XCTAssertEqual(inspected.page?.sources.first?.input.value(atPointer: "/package"), .string("firefox"))
        let stale = try render(helper, event: .itemAction(page: "homebrew-command", collection: "results-old", action: "package-info", item: .init(id: "result-1", section: nil, text: "firefox"), values: .object([:])), state: result.state)
        XCTAssertTrue(stale.page?.sources.isEmpty == true); XCTAssertNil(stale.operation)
    }
    func testEmptySuccessHasCommandSpecificEmptyState() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result = try readResult(helper, command: "brew.outdated", text: "")
        XCTAssertEqual(result.page?.collection?.total, 0)
        XCTAssertEqual(result.page?.collection?.emptyText, "All packages are up to date.")
        XCTAssertNil(result.operation)
    }
    func testReopeningAnotherShortcutResetsOnlyItsCommandInputsWithoutRunningIt() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result = try readResult(helper, text: "wget\nfirefox\n")
        let called = try render(helper, command: "brew.info", input: .object(["package": .string("wget")]), event: .called, state: result.state)
        XCTAssertEqual(called.state.value(atPointer: "/command"), .string("info"))
        XCTAssertEqual(called.state.value(atPointer: "/package"), .string("wget"))
        XCTAssertEqual(called.page?.reset, .components(["command", "package"]))
        XCTAssertEqual(called.page?.collection?.items.map(\.title), ["wget", "firefox"])
        XCTAssertNil(called.operation); XCTAssertTrue(called.page?.sources.isEmpty == true)
    }
}
