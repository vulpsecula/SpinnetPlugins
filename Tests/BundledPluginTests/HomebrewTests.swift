// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewTests: XCTestCase {
    private func plugin() throws -> PluginUnderTest { try PluginUnderTest(named: "Homebrew.spinnetplugin", origin: .bundled) }
    private func render(_ helper: PluginTestHelper, command: String = "brew.open", input: JSONValue = .null,
                        event: PluginViewEvent? = nil, state: JSONValue = .null) throws -> PluginScriptAnswer {
        let run = helper.run(.init(command, input: input, event: event, state: state), of: try plugin(), answering: RecordedHostServices())
        XCTAssertTrue(run.requests.isEmpty, "A launcher must not fetch inventory, manage Tasks, read caches or execute a synchronous shell call")
        return try run.answer()
    }
    func testEveryShortcutShowsTheCommandWithoutRunningOrReadingHomebrew() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try plugin()
        XCTAssertEqual(plugin.manifest.version, "2.0.0")
        XCTAssertEqual(plugin.manifest.apiLevel, 5)
        XCTAssertEqual(plugin.manifest.capabilities, [.controlExternalApp])
        XCTAssertEqual(plugin.manifest.scope(for: .controlExternalApp)?.externalApps.first?.bundleID, "com.apple.Terminal")
        for command in plugin.manifest.commands {
            let answer = try render(helper, command: command.id.rawValue)
            XCTAssertEqual(answer.page?.id, "homebrew-terminal")
            XCTAssertTrue(answer.page?.sources.isEmpty == true)
            XCTAssertNil(answer.operation)
            XCTAssertNotNil(answer.page?.component("command-preview"))
            XCTAssertNil(answer.page?.collection)
            XCTAssertFalse(answer.page?.components.contains { if case .activityList = $0 { return true }; return false } == true)
        }
    }
    func testUpgradeHandoffIsTypedAndOnlyRunsAfterTheExplicitButton() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.upgrade", input: .object(["package": .string("firefox")]))
        let run = try render(helper, command: "brew.upgrade", event: .pageActionChosen(page: "homebrew-terminal", action: "run-terminal",
            values: .object(["kind": .string("cask"), "package": .string("firefox")]), selection: .null), state: opened.state)
        XCTAssertEqual(run.operation?.perform, "apps.perform")
        XCTAssertEqual(run.operation?.input, .object(["bundle_id": .string("com.apple.Terminal"), "operation": .string("homebrew"),
            "arguments": .object(["command": .string("upgrade"), "kind": .string("cask"), "package": .string("firefox")])]))
        XCTAssertTrue(run.operation?.notify == true)
        let finished = try render(helper, command: "brew.upgrade", event: .operationFinished(id: "terminal-handoff", perform: "apps.perform", outcome: .succeeded), state: run.state)
        XCTAssertNil(finished.operation)
        guard case .text(let text)? = finished.page?.component("handoff-status") else { return XCTFail("Show the handoff outcome") }
        XCTAssertTrue(text.text.contains("Sent to Terminal"))
        XCTAssertFalse(text.text.contains("upgrade completed"))
    }
    func testMissingOrInvalidPackageNeverBuildsAnOperation() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for package in ["", "foo; touch /tmp/should-not-run", "--force", "x\ny"] {
            let opened = try render(helper, command: "brew.install", input: .object(["package": .string(package)]))
            XCTAssertNotNil(opened.page?.component("input-help"))
            XCTAssertNil(opened.page?.component("execute"))
            let answer = try render(helper, command: "brew.install", event: .pageActionChosen(page: "homebrew-terminal", action: "run-terminal", values: .null, selection: .null), state: opened.state)
            XCTAssertNil(answer.operation)
        }
    }
    func testCatalogUpdateIsANativeCommandAndSourceDeliveriesCannotRunIt() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.update")
        guard case .text(let preview)? = opened.page?.component("command-preview") else { return XCTFail("Show command") }
        XCTAssertEqual(preview.text, "brew update")
        let background = try render(helper, command: "brew.update", event: .sourceDelivered(page: "homebrew-terminal", source: "old-activities", sequence: 1, result: .null, failure: nil), state: opened.state)
        XCTAssertNil(background.operation)
        XCTAssertTrue(background.page?.sources.isEmpty == true)
    }
    func testLegacyMenuCommandsRemainPresentWithoutPretendingToProvideSecurityChecksOrCaches() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for command in ["brew.vulnerabilities", "brew.clear-cache"] {
            let opened = try render(helper, command: command)
            XCTAssertNotNil(opened.page?.component("legacy-command"))
            XCTAssertNil(opened.operation)
        }
        let ids = Set(try plugin().manifest.commands.map(\.id.rawValue))
        XCTAssertTrue(ids.isSuperset(of: ["brew.open", "brew.installed", "brew.search", "brew.outdated", "brew.vulnerabilities", "brew.doctor", "brew.adopt", "brew.upgrade", "brew.services", "brew.taps", "brew.services-menu", "brew.cleanup", "brew.clear-cache", "brew.autoremove"]))
    }
    func testNativeSearchTextStaysADataArgumentAndPreviewQuotesIt() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try render(helper, command: "brew.search", input: .object(["package": .string("it's $(echo example)")]))
        let answer = try render(helper, command: "brew.search", event: .pageActionChosen(page: "homebrew-terminal", action: "run-terminal", values: .null, selection: .null), state: opened.state)
        XCTAssertEqual(answer.operation?.input.value(atPointer: "/arguments/package"), .string("it's $(echo example)"))
        guard case .text(let preview)? = answer.page?.component("command-preview") else { return XCTFail("Show command") }
        XCTAssertEqual(preview.text, "brew search -- 'it'\\''s $(echo example)'")
    }
}
