// SPDX-License-Identifier: MIT
// Ported from accepted independent Homebrew proof f6a9d91 (#93).
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewTests: XCTestCase {
    private func securityAction(_ action: String, from answer: PluginScriptAnswer, helper: PluginTestHelper, plugin: PluginUnderTest, values: JSONValue = .null) throws -> PluginScriptAnswer {
        try helper.run(.init("brew.vulnerabilities", event: .pageActionChosen(page: try XCTUnwrap(answer.page?.id), action: action, values: values, selection: .null), state: answer.state), of: plugin, answering: services()).answer()
    }
    private func securityInventory(_ names: [String], helper: PluginTestHelper, plugin: PluginUnderTest, truncated: Bool = false) throws -> PluginScriptAnswer {
        let opened = try helper.run(.init("brew.vulnerabilities"), of: plugin, answering: services()).answer()
        return try helper.run(.init("brew.vulnerabilities", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: try XCTUnwrap(opened.page?.sources.first?.id), sequence: 1, result: .object(["packages": .array(names.map { .object(["kind": .string("formula"), "name": .string($0)]) }), "truncated": .bool(truncated)]), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
    }
    private func securityReport(_ result: JSONValue, into answer: PluginScriptAnswer, helper: PluginTestHelper, plugin: PluginUnderTest, source: String? = nil) throws -> PluginScriptAnswer {
        try helper.run(.init("brew.vulnerabilities", event: .sourceDelivered(page: try XCTUnwrap(answer.page?.id), source: try XCTUnwrap(source ?? answer.page?.sources.first?.id), sequence: 1, result: result, failure: nil), state: answer.state), of: plugin, answering: services()).answer()
    }
    func testSecurityRowsVisiblyDistinguishSelectionAndClearingRestoresUnselectedAppearance() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let loaded = try securityInventory(["wget"], helper: helper, plugin: plugin)
        let row = try XCTUnwrap(loaded.page?.collection?.items.first)
        XCTAssertEqual(row.icon?.name, "circle")
        XCTAssertTrue(row.subtitle?.contains("Not selected") == true)
        let selected = try helper.run(.init("brew.vulnerabilities", event: .itemAction(page: "homebrew-security-select", collection: "security-packages", action: "toggle-security", item: .init(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.page?.collection?.items.first?.icon?.name, "checkmark.circle.fill")
        XCTAssertTrue(selected.page?.collection?.items.first?.subtitle?.hasPrefix("Selected") == true)
        XCTAssertEqual(selected.page?.collection?.items.first?.marks, ["security_selected"])
        let cleared = try securityAction("clear-security", from: selected, helper: helper, plugin: plugin)
        XCTAssertEqual(cleared.page?.collection?.items.first?.icon?.name, "circle")
        XCTAssertTrue(cleared.page?.collection?.items.first?.subtitle?.hasPrefix("Not selected") == true)
        XCTAssertTrue(cleared.page?.collection?.items.first?.marks.isEmpty == true)
    }
    func testSecurityBareHostResultsKeepQualifiedPackageIdentityAndUpgradeTarget() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory(["owner/tools/alpha", "owner/tools/legacy"], helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        XCTAssertEqual(started.page?.sources.first?.input.value(atPointer: "/names"), .array([.string("owner/tools/alpha"), .string("owner/tools/legacy")]))
        let loaded = try securityReport(.object(["checked": .number(1), "findings": .array([.object(["name": .string("alpha"), "open_count": .number(1), "upgrade_available": .bool(true), "advisories": .array([.object(["id": .string("CVE-2026-1"), "status": .string("open")])])])]), "skipped": .array([.object(["name": .string("legacy"), "reason": .string("installed_source_unavailable_or_unsupported")])])]), into: started, helper: helper, plugin: plugin)
        XCTAssertEqual(loaded.page?.collection?.items.map(\.title), ["owner/tools/alpha", "owner/tools/legacy"])
        let row = try XCTUnwrap(loaded.page?.collection?.items.first)
        let detail = try helper.run(.init("brew.vulnerabilities", event: .itemAction(page: try XCTUnwrap(loaded.page?.id), collection: "management", action: "manage-details", item: .init(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: loaded.state), of: plugin, answering: services()).answer()
        let upgrade = try securityAction("upgrade-security", from: detail, helper: helper, plugin: plugin)
        XCTAssertEqual(upgrade.operation?.input.value(atPointer: "/name"), .string("owner/tools/alpha"))
        guard case .text(let coverage)? = loaded.page?.component("security-coverage") else { return XCTFail("Expected coverage") }
        XCTAssertTrue(coverage.text.contains("1 checked"))
        XCTAssertTrue(coverage.text.contains("1 not checked"))
    }
    func testSecurityRefusesAmbiguousInstalledBasenamesEvenWhenOnlyOneConflictingToolIsSelected() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let names = ["owner/tools/shared", "other/tools/shared"] + (0..<20).map { String(format: "a-tool%02d", $0) }
        let inventory = try securityInventory(names, helper: helper, plugin: plugin)
        for filtered in ["", "owner/tools/shared"] {
            let selected = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin, values: .object(["securityFilter": .string(filtered)]))
            let refused = try securityAction("start-security", from: selected, helper: helper, plugin: plugin)
            XCTAssertEqual(refused.page?.id, "homebrew-security-select")
            XCTAssertFalse(refused.page?.sources.contains { $0.input.value(atPointer: "/operation") == .string("vulnerabilities") } == true)
            guard case .text(let reason)? = refused.page?.component("security-selection-error") else { return XCTFail("Expected an explicit ambiguous-name explanation") }
            XCTAssertTrue(reason.text.contains("same package name"))
            XCTAssertTrue(reason.text.contains("owner/tools/shared"))
            XCTAssertNil(refused.operation)
            _ = try securityAction("clear-security", from: refused, helper: helper, plugin: plugin)
        }
    }
    func testSecuritySelectionPreservesChoicesAcrossFilteringAndCollectionWindowsAndBoundsTwoThousandTools() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let names = (0..<2000).map { String(format: "tool%04d", $0) }
        let inventory = try securityInventory(names, helper: helper, plugin: plugin, truncated: true)
        let filtered = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin, values: .object(["securityFilter": .string("tool000")]))
        XCTAssertEqual(filtered.page?.collection?.total, 10)
        XCTAssertTrue(filtered.page?.collection?.items.allSatisfy { $0.marks == ["security_selected"] } == true)
        let shown = try helper.run(.init("brew.vulnerabilities", event: .pageFieldChanged(page: "homebrew-security-select", field: "securityFilter", values: .object(["securityFilter": .string("")])), state: filtered.state), of: plugin, answering: services()).answer()
        let scrolled = try helper.run(.init("brew.vulnerabilities", event: .loadRange(page: "homebrew-security-select", collection: "security-packages", start: 1990, count: 10), state: shown.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(scrolled.page?.collection?.items.first?.title, "tool1990")
        let all = try securityAction("select-security", from: scrolled, helper: helper, plugin: plugin)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(all.pageJSON), as: UTF8.self).contains("Check Selected 2000"))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(all.pageJSON), as: UTF8.self).contains("Inventory reached the Host limit"))
        XCTAssertLessThan(try JSONEncoder().encode(all.state).count, 65_536)
        let cleared = try securityAction("clear-security", from: all, helper: helper, plugin: plugin)
        XCTAssertTrue(cleared.page?.collection?.items.allSatisfy { $0.marks.isEmpty } == true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(cleared.pageJSON), as: UTF8.self).contains("start-security"))
        XCTAssertNil(cleared.operation)
    }
    func testSecurityInventoryRetryUsesANewSourceAndUnsupportedChecksStopWithoutReportingCleanResults() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(.init("brew.vulnerabilities"), of: plugin, answering: services()).answer()
        let failed = try helper.run(.init("brew.vulnerabilities", event: .sourceDelivered(page: "homebrew-security-select", source: try XCTUnwrap(opened.page?.sources.first?.id), sequence: 1, result: nil, failure: .init(category: .hostServiceFailed, message: "Homebrew unavailable")), state: opened.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(failed.page?.sources.isEmpty == true)
        let retry = try securityAction("retry-security-inventory", from: failed, helper: helper, plugin: plugin)
        XCTAssertNotEqual(retry.page?.sources.first?.id, opened.page?.sources.first?.id)
        let stale = try securityReport(.object(["packages": .array([.object(["kind": .string("formula"), "name": .string("stale")])])]), into: retry, helper: helper, plugin: plugin, source: try XCTUnwrap(opened.page?.sources.first?.id))
        XCTAssertEqual(stale.page?.collection?.total, 0)
        let loaded = try securityReport(.object(["packages": .array([.object(["kind": .string("formula"), "name": .string("wget")])])]), into: stale, helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: loaded, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        let unsupported = try securityReport(.object(["available": .bool(false), "reason": .string("requires_homebrew_7")]), into: started, helper: helper, plugin: plugin)
        XCTAssertTrue(unsupported.page?.sources.isEmpty == true)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(unsupported.pageJSON), as: UTF8.self).contains("cannot perform Security Check"))
        guard case .text(let coverage)? = unsupported.page?.component("security-coverage") else { return XCTFail("Expected unsupported coverage") }
        XCTAssertEqual(coverage.title, "Incomplete Check")
        XCTAssertTrue(coverage.text.contains("0/1"))
    }
    func testLargeSelectedSecurityReportsStayBoundedAndNeverClaimCompleteReviewAfterOmittingDetails() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory((0..<120).map { String(format: "tool%03d", $0) }, helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        var answer = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        for _ in 0..<6 {
            guard case .array(let values)? = answer.page?.sources.first?.input.value(atPointer: "/names") else { return XCTFail("Expected next named batch") }
            let findings = values.map { name -> JSONValue in
                .object(["name": name, "unknown_count": .number(40), "advisories": .array((0..<40).map { .object(["id": .string("CVE-2026-\($0)"), "summary": .string(String(repeating: "a", count: 200)), "status": .string("unknown")]) })])
            }
            answer = try securityReport(.object(["checked": .number(20), "findings": .array(findings), "skipped": .array([])]), into: answer, helper: helper, plugin: plugin)
            XCTAssertLessThan(try JSONEncoder().encode(answer.state).count, 65_536)
            XCTAssertLessThan(try JSONEncoder().encode(answer.pageJSON).count, 262_144)
        }
        XCTAssertTrue(answer.page?.sources.isEmpty == true)
        guard case .text(let coverage)? = answer.page?.component("security-coverage") else { return XCTFail("Expected bounded report coverage") }
        XCTAssertEqual(coverage.title, "Incomplete Check")
        XCTAssertTrue(coverage.text.contains("120 checked"))
        XCTAssertTrue(coverage.text.contains("limit"))
        XCTAssertLessThan(answer.page?.collection?.total ?? 200, 120)
    }
    func testSecurityFailureRetainsCompletedResultsRetriesOnlyFailedBatchAndCanStopOrStartANewCheck() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory((0..<21).map { String(format: "tool%02d", $0) }, helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        let next = try securityReport(.object(["checked": .number(20), "findings": .array([]), "skipped": .array([])]), into: started, helper: helper, plugin: plugin)
        let failed = try helper.run(.init("brew.vulnerabilities", event: .sourceDelivered(page: try XCTUnwrap(next.page?.id), source: try XCTUnwrap(next.page?.sources.first?.id), sequence: 1, result: nil, failure: .init(category: .hostServiceFailed, message: "OSV unavailable")), state: next.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(failed.page?.sources.isEmpty == true)
        let retry = try securityAction("retry-security", from: failed, helper: helper, plugin: plugin)
        XCTAssertEqual(retry.page?.sources.first?.input.value(atPointer: "/names"), .array([.string("tool20")]))
        XCTAssertNotEqual(retry.page?.sources.first?.id, next.page?.sources.first?.id)
        let stopped = try securityAction("stop-security", from: retry, helper: helper, plugin: plugin)
        XCTAssertTrue(stopped.page?.sources.isEmpty == true)
        XCTAssertNil(stopped.operation)
        let stale = try securityReport(.object(["checked": .number(1), "findings": .array([])]), into: stopped, helper: helper, plugin: plugin, source: try XCTUnwrap(retry.page?.sources.first?.id))
        guard case .text(let coverage)? = stale.page?.component("security-coverage") else { return XCTFail("Expected retained coverage") }
        XCTAssertTrue(coverage.text.contains("20/21"))
        let selection = try securityAction("choose-security", from: stopped, helper: helper, plugin: plugin)
        XCTAssertEqual(selection.page?.id, "homebrew-security-select")
        let restarted = try securityAction("start-security", from: selection, helper: helper, plugin: plugin)
        XCTAssertNotEqual(restarted.page?.sources.first?.id, started.page?.sources.first?.id)
        let old = try securityReport(.object(["checked": .number(20), "findings": .array([])]), into: restarted, helper: helper, plugin: plugin, source: try XCTUnwrap(started.page?.sources.first?.id))
        XCTAssertEqual(old.page?.sources.first?.id, restarted.page?.sources.first?.id)
        guard case .text(let newCoverage)? = old.page?.component("security-coverage") else { return XCTFail("Expected new check coverage") }
        XCTAssertTrue(newCoverage.text.contains("0/21"))
    }
    func testSecurityAutomaticallyChecksFrozenSelectionInBoundedBatchesAndAggregatesCoverage() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let loaded = try securityInventory((0..<21).map { String(format: "tool%02d", $0) }, helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: loaded, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        if case .array(let names)? = started.page?.sources.first?.input.value(atPointer: "/names") { XCTAssertEqual(names.count, 20) } else { XCTFail("Expected a bounded named batch") }
        let firstID = try XCTUnwrap(started.page?.sources.first?.id)
        let report: JSONValue = .object(["checked": .number(20), "findings": .array([.object(["name": .string("tool00"), "open_count": .number(1), "advisories": .array([.object(["id": .string("CVE-2026-1"), "status": .string("open")])])])]), "skipped": .array([])])
        let next = try securityReport(report, into: started, helper: helper, plugin: plugin)
        XCTAssertNotEqual(next.page?.sources.first?.id, firstID)
        XCTAssertEqual(next.page?.sources.first?.input.value(atPointer: "/names"), .array([.string("tool20")]))
        XCTAssertEqual(next.page?.collection?.items.first?.title, "tool00")
        let stale = try securityReport(report, into: next, helper: helper, plugin: plugin, source: firstID)
        XCTAssertEqual(stale.page?.sources.first?.id, next.page?.sources.first?.id)
        XCTAssertEqual(stale.page?.collection?.total, 1)
        // The selected package disappeared before this read. It cannot count as clean.
        let done = try securityReport(.object(["checked": .number(0), "findings": .array([]), "skipped": .array([])]), into: stale, helper: helper, plugin: plugin)
        XCTAssertTrue(done.page?.sources.isEmpty == true)
        guard case .text(let coverage)? = done.page?.component("security-coverage") else { return XCTFail("Expected aggregate coverage") }
        XCTAssertTrue(coverage.text.contains("20 checked"))
        XCTAssertTrue(coverage.text.contains("1 not accounted for"))
        XCTAssertTrue(coverage.title?.contains("Incomplete") == true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(done.pageJSON), as: UTF8.self).contains("Next Group"))
    }
    func testSecuritySelectionReadsOnlyLocalFormulaeAndRequiresAnExplicitSelection() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(.init("brew.vulnerabilities"), of: plugin, answering: services()).answer()
        XCTAssertEqual(opened.page?.id, "homebrew-security-select")
        XCTAssertEqual(opened.page?.sources.first?.input, .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")]))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(opened.pageJSON), as: UTF8.self).contains("start-security"))
        let result: JSONValue = .object(["packages": .array([
            .object(["name": .string("wget"), "kind": .string("formula"), "installed_version": .string("1")]),
            .object(["name": .string("firefox"), "kind": .string("cask")])
        ])])
        let loaded = try helper.run(.init("brew.vulnerabilities", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: try XCTUnwrap(opened.page?.sources.first?.id), sequence: 1, result: result, failure: nil), state: opened.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(loaded.page?.collection?.items.map(\.title), ["wget"])
        XCTAssertTrue(loaded.page?.sources.isEmpty == true)
        let row = try XCTUnwrap(loaded.page?.collection?.items.first)
        let selected = try helper.run(.init("brew.vulnerabilities", event: .itemAction(page: try XCTUnwrap(loaded.page?.id), collection: "security-packages", action: "toggle-security", item: .init(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.page?.collection?.items.first?.marks, ["security_selected"])
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(selected.pageJSON), as: UTF8.self).contains("Check Selected 1"))
        let started = try helper.run(.init("brew.vulnerabilities", event: .pageActionChosen(page: try XCTUnwrap(selected.page?.id), action: "start-security", values: .null, selection: .null), state: selected.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(started.page?.sources.first?.input, .object(["tool": .string("homebrew"), "operation": .string("vulnerabilities"), "names": .array([.string("wget")])]))
        XCTAssertNil(started.operation)
    }
    func testCompletedSecuritySelectionsSeparateProcessedCoverageFromRemainingSelection() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        for count in [20, 40] {
            let inventory = try securityInventory((0..<count).map { String(format: "tool%02d", $0) }, helper: helper, plugin: plugin)
            let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
            let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
            let answer = try securityReport(.object(["checked": .number(20), "findings": .array([]), "skipped": .array([])]), into: started, helper: helper, plugin: plugin)
            guard case .text(let coverage)? = answer.page?.component("security-coverage") else { return XCTFail("Expected selected coverage") }
            XCTAssertEqual(coverage.title, count == 20 ? "Check Complete" : "Checking Selected Tools…")
            XCTAssertTrue(coverage.text.contains("20/\(count) processed"))
            XCTAssertEqual(answer.page?.sources.count, count == 20 ? 0 : 1)
        }
    }

    func testFreshSecurityWindowRequiresNewSelectionAndNeverResumesCachedNetworkChecks() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory(["wget"], helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        _ = try securityReport(.object(["checked": .number(1), "findings": .array([])]), into: started, helper: helper, plugin: plugin)
        let fresh = try helper.run(.init("brew.vulnerabilities"), of: plugin, answering: services()).answer()
        XCTAssertEqual(fresh.page?.id, "homebrew-security-select")
        XCTAssertEqual(fresh.page?.sources.first?.input.value(atPointer: "/operation"), .string("installed"))
        XCTAssertNil(fresh.operation)
        let late = try securityReport(.object(["checked": .number(1), "findings": .array([])]), into: fresh, helper: helper, plugin: plugin, source: try XCTUnwrap(started.page?.sources.first?.id))
        XCTAssertEqual(late.page?.id, "homebrew-security-select")
        XCTAssertEqual(late.page?.collection?.total, 0)
    }

    func testAutoremoveCancellationIsVisibleAndRefreshingWithdrawsThePreviousRemovalOffer() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(PluginTestInvocation("brew.autoremove"), of: plugin, answering: services()).answer()
        let result: JSONValue = .object(["available": .bool(true), "dry_run": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false), "packages": .array([.object(["kind": .string("formula"), "name": .string("unused")])])])
        let loaded = try helper.run(PluginTestInvocation("brew.autoremove", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: "manage", sequence: 1, result: result, failure: nil), state: opened.state), of: plugin, answering: services()).answer()
        let cancelled = try helper.run(PluginTestInvocation("brew.autoremove", event: .operationFinished(id: nil, perform: "tools.startTask", outcome: .cancelled), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertNotNil(cancelled.page?.component("autoremove-task-message"))
        let refreshed = try helper.run(PluginTestInvocation("brew.autoremove", event: .pageActionChosen(page: try XCTUnwrap(loaded.page?.id), action: "refresh", values: .null, selection: .null), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(refreshed.pageJSON), as: UTF8.self).contains("review-autoremove"))
        XCTAssertEqual(refreshed.page?.collection?.total, 0)
    }

    func testAutoremovePreviewsCandidatesBeforeOfferingAConfirmedTaskAndRefusesEmptyOrIncompletePlans() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(PluginTestInvocation("brew.autoremove"), of: plugin, answering: services()).answer()
        XCTAssertEqual(opened.page?.sources.first?.input, .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")]))
        XCTAssertNil(opened.operation)
        let successful: [String: JSONValue] = ["available": .bool(true), "dry_run": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false), "packages": .array([.object(["kind": .string("formula"), "name": .string("unused-tool")])]), "stdout": .string("Would remove unused-tool"), "exit_status": .number(0)]
        let loaded = try helper.run(PluginTestInvocation("brew.autoremove", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: "manage", sequence: 1, result: .object(successful), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(loaded.page?.collection?.items.first?.title, "unused-tool")
        XCTAssertNil(loaded.operation)
        let requested = try helper.run(PluginTestInvocation("brew.autoremove", event: .pageActionChosen(page: try XCTUnwrap(loaded.page?.id), action: "review-autoremove", values: .null, selection: .null), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(requested.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("autoremove")]))
        for fields in [["complete": JSONValue.bool(false)], ["succeeded": .bool(false)], ["no_op": .bool(true)], ["packages": .array([])]] {
            let unavailable = try helper.run(PluginTestInvocation("brew.autoremove", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: "manage", sequence: 2, result: .object(successful.merging(fields) { _, new in new }), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(unavailable.pageJSON), as: UTF8.self).contains("review-autoremove"))
            let refused = try helper.run(PluginTestInvocation("brew.autoremove", event: .pageActionChosen(page: try XCTUnwrap(unavailable.page?.id), action: "review-autoremove", values: .null, selection: .null), state: unavailable.state), of: plugin, answering: services()).answer()
            XCTAssertNil(refused.operation)
        }
    }

    func testPackageSecurityUsesAnAdvisoryListAndOpensOnlyTheChosenAdvisory() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("vulnerabilities"), "manageDetail": .object(["name": .string("example"), "unknown_count": .number(1), "advisories": .array([.object(["id": .string("CVE-2026-42"), "summary": .string("Example advisory"), "status": .string("unknown")])])])])
        let listed = try helper.run(PluginTestInvocation("brew.vulnerabilities", state: state), of: plugin, answering: services()).answer()
        XCTAssertEqual(listed.page?.collection?.id, "security-advisories")
        let row = try XCTUnwrap(listed.page?.collection?.items.first)
        XCTAssertEqual(row.title, "CVE-2026-42")
        let selected = try helper.run(PluginTestInvocation("brew.vulnerabilities", event: .itemAction(page: try XCTUnwrap(listed.page?.id), collection: "security-advisories", action: "read-advisory", item: PluginPageItemSnapshot(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: listed.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.page?.id, "homebrew-advisory")
        XCTAssertEqual(selected.page?.sources.first?.input.value(atPointer: "/id"), .string("CVE-2026-42"))
        XCTAssertNil(selected.operation)
    }

    func testSecurityResultsSeparateReviewPatchedAndSkippedPackagesAndNewCheckClearsOldResults() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory(["alpha", "beta", "legacy"], helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        let result: JSONValue = .object(["checked": .number(2), "findings": .array([
            .object(["name": .string("alpha"), "open_count": .number(1), "advisories": .array([.object(["id": .string("CVE-2026-1"), "status": .string("open")])])]),
            .object(["name": .string("beta"), "patched_count": .number(1), "advisories": .array([.object(["id": .string("CVE-2026-2"), "status": .string("patched")])])])
        ]), "skipped": .array([.object(["name": .string("legacy"), "reason": .string("installed_source_unavailable_or_unsupported")])])])
        let loaded = try securityReport(result, into: started, helper: helper, plugin: plugin)
        XCTAssertEqual(loaded.page?.collection?.sections.compactMap(\.title), ["Needs Review", "Patched by Homebrew", "Not Checked"])
        let row = try XCTUnwrap(loaded.page?.collection?.items.last)
        XCTAssertEqual(row.title, "legacy")
        let detail = try helper.run(.init("brew.vulnerabilities", event: .itemAction(page: try XCTUnwrap(loaded.page?.id), collection: "management", action: "manage-details", item: .init(id: row.id, section: "skipped", text: row.text ?? row.title), values: .null), state: loaded.state), of: plugin, answering: services()).answer()
        XCTAssertNotNil(detail.page?.component("security-skip-reason"))
        XCTAssertNil(detail.page?.component("security-coverage"))
        XCTAssertTrue(detail.page?.sources.isEmpty == true)
        let selection = try securityAction("choose-security", from: loaded, helper: helper, plugin: plugin)
        let next = try securityAction("start-security", from: selection, helper: helper, plugin: plugin)
        XCTAssertEqual(next.page?.collection?.total, 0)
        let stale = try securityReport(result, into: next, helper: helper, plugin: plugin, source: try XCTUnwrap(started.page?.sources.first?.id))
        XCTAssertEqual(stale.page?.collection?.total, 0)
        XCTAssertEqual(stale.page?.sources.first?.id, next.page?.sources.first?.id)
        XCTAssertNil(next.operation)
    }

    func testSecurityCheckExplainsCoverageBeforeAnExplicitReadAndStartsOnlyOnRequest() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(.init("brew.vulnerabilities"), of: plugin, answering: services()).answer()
        XCTAssertEqual(opened.page?.sources.first?.input.value(atPointer: "/operation"), .string("installed"))
        let text = String(decoding: try JSONEncoder().encode(opened.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("Cask Apps are not checked"))
        XCTAssertTrue(text.contains("OSV receives upstream repository names and installed source versions"))
        let refused = try securityAction("start-security", from: opened, helper: helper, plugin: plugin)
        XCTAssertEqual(refused.page?.id, "homebrew-security-select")
        XCTAssertFalse(refused.page?.sources.contains { $0.input.value(atPointer: "/operation") == .string("vulnerabilities") } == true)
        XCTAssertNil(refused.operation)
    }

    func testServicesAndTapsReportLoadingEmptyResultsAndLoadedCountsOutsideTheCollection() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (command, key, records, expected) in [("brew.services", "services", [JSONValue](), "No services found"), ("brew.taps", "taps", [JSONValue.object(["name": .string("example/tools")])], "1 package source")] {
            let opened = try helper.run(PluginTestInvocation(command), of: plugin, answering: services()).answer()
            guard case .text(let loading)? = opened.page?.component("management-status") else { return XCTFail("Expected visible management read status") }
            XCTAssertTrue(loading.text.contains("Loading"))
            let loaded = try helper.run(PluginTestInvocation(command, event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: "manage", sequence: 1, result: .object([key: .array(records)]), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
            guard case .text(let status)? = loaded.page?.component("management-status") else { return XCTFail("Expected result count outside the list") }
            XCTAssertTrue(status.text.contains(expected))
            XCTAssertEqual(loaded.page?.collection?.total, records.count)
        }
    }

    func testHomeAndPackageDetailsUseTheDeclaredResponsiveLayoutAndKeepAllDestinationsReachable() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        XCTAssertEqual(plugin.manifest.apiLevel, 3)
        XCTAssertTrue(plugin.manifest.candidateContracts.isEmpty)
        let page = PluginTestPage("brew.open", of: plugin, helper: helper, answering: services())
        try page.open()
        let destinations = try XCTUnwrap(page.page?.collection)
        XCTAssertEqual(destinations.id, "destinations")
        XCTAssertEqual(destinations.items.count, 11)
        XCTAssertEqual(destinations.sections.compactMap(\.title), ["Packages", "Manage Homebrew", "Activity"])
        XCTAssertNotNil(page.pageJSON?.value(atPointer: "/resizable"))
        XCTAssertNil(page.page?.component("home-sections"))
        for mode in ["installed", "search", "outdated", "services", "taps", "vulnerabilities", "doctor", "adopt", "cleanup", "autoremove", "activity"] {
            try page.choose(itemAction: "navigate", on: mode)
            XCTAssertNotEqual(page.page?.id, "homebrew-home")
            XCTAssertNil(try page.lastAnswer().operation)
            try page.click("home")
        }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1"), "installed_version": .string("1")]), "detailLoaded": .bool(true)])
        let detail = try helper.run(PluginTestInvocation("brew.open", state: state), of: plugin, answering: services()).answer()
        guard case .adaptive(let facts)? = detail.page?.component("package-facts") else { return XCTFail("Expected responsive package facts") }
        XCTAssertEqual(facts.content.count, 2)
        XCTAssertEqual(facts.maximumColumns, 2)
    }

    func testDoctorRowsShowSingleLineSummariesAndDetailsRetainTheFullFinding() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let finding = "Unlinked tools were found:\n  first\n  second\nReview the links before repairing."
        let opened = try helper.run(PluginTestInvocation("brew.doctor"), of: plugin, answering: services()).answer()
        let listed = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: try XCTUnwrap(opened.page?.id), source: "manage", sequence: 1, result: .object(["findings": .array([.object(["id": .string("finding-0"), "text": .string(finding)])])]), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
        let row = try XCTUnwrap(listed.page?.collection?.items.first)
        XCTAssertEqual(row.title, "Unlinked tools were found:")
        let detail = try helper.run(PluginTestInvocation("brew.doctor", event: .itemAction(page: try XCTUnwrap(listed.page?.id), collection: "management", action: "manage-details", item: PluginPageItemSnapshot(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: listed.state), of: plugin, answering: services()).answer()
        guard case .text(let title)? = detail.page?.component("detail-title") else { return XCTFail("Expected a concise heading") }
        XCTAssertEqual(title.text, "Unlinked tools were found:")
        guard case .text(let text)? = detail.page?.component("doctor-explanation") else { return XCTFail("Expected the full finding") }
        XCTAssertEqual(text.text, finding)
        XCTAssertNil(detail.operation)
    }

    func testLargeDoctorFindingKeepsDetailsOutsideStateAndRemainsNavigable() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let affected = (0..<100).map { JSONValue.string(String(repeating: "🧩", count: 197) + String($0)) }
        let finding: JSONValue = .object(["id": .string("finding-large"), "text": .string("Large report\n\nPreserve the explanation."), "affects": .array(affected), "guidance": .string("Review the affected items.\n\nThen decide how to proceed."), "links": .array((0..<8).map { .string("https://docs.brew.sh/example/\($0)") }), "commands": .array((0..<8).map { .string("brew link package\($0)") }), "repairs": .array((0..<8).map { .object(["target": .string("fix_package\($0)"), "title": .string("Link package\($0)")]) })])
        let listed = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: "homebrew-manage-doctor", source: "manage", sequence: 1, result: .object(["findings": .array([finding])]), failure: nil)), of: plugin, answering: services()).answer()
        let row = try XCTUnwrap(listed.page?.collection?.items.first)
        let detail = try helper.run(PluginTestInvocation("brew.doctor", event: .itemAction(page: "homebrew-manage-doctor", collection: "management", action: "manage-details", item: PluginPageItemSnapshot(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: listed.state), of: plugin, answering: services()).answer()
        XCTAssertLessThan(try JSONEncoder().encode(detail.state).count, 4096)
        guard case .text(let text)? = detail.page?.component("doctor-affected") else { return XCTFail("Missing affected items") }
        XCTAssertTrue(text.text.contains(String(repeating: "🧩", count: 197) + "99"))
        let copy = try helper.run(PluginTestInvocation("brew.doctor", event: .pageActionChosen(page: try XCTUnwrap(detail.page?.id), action: "copy-7", values: .null, selection: .null), state: detail.state), of: plugin, answering: services()).answer()
        XCTAssertNotNil(copy.page?.component("doctor-affected"))
        let back = try helper.run(PluginTestInvocation("brew.doctor", event: .pageActionChosen(page: try XCTUnwrap(detail.page?.id), action: "manage-back", values: .null, selection: .null), state: detail.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(back.page?.collection?.items.first?.title, "Large report")
        XCTAssertNil(back.operation)
    }

    func testDoctorGroupsActionableFindingsAndDisclosesIncompleteHostContext() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let report: JSONValue = .object(["context": .object(["scope": .string("host"), "shell_path": .string("not_checked"), "directory_access": .string("reported_paths_rechecked"), "unverified_directory_checks": .number(1)]), "findings": .array([
            .object(["text": .string("Deprecated formulae"), "affects": .array([.string("ruby@3.1")]), "repairs": .array([])]),
            .object(["text": .string("Unlinked keg"), "affects": .array([.string("wget")]), "repairs": .array([.object(["title": .string("Link wget"), "target": .string("fix_wget")])])])
        ])])
        let listed = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: "homebrew-manage-doctor", source: "manage", sequence: 1, result: report, failure: nil)), of: plugin, answering: services()).answer()
        XCTAssertEqual(listed.page?.collection?.sections.map(\.title), ["Available Repairs", "Manual Review"])
        XCTAssertEqual(listed.page?.collection?.items.first?.title, "Unlinked keg")
        let text = String(decoding: try JSONEncoder().encode(listed.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("Incomplete Check"))
        XCTAssertTrue(text.contains("terminal"))
        XCTAssertNil(listed.operation)
    }

    func testDoctorDetailUsesNewReportImmediatelyAndDropsRemovedFinding() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        func report(_ guidance: String) -> JSONValue { .object(["findings": .array([.object(["text": .string("Unlinked keg"), "guidance": .string(guidance), "repairs": .array([])])])]) }
        let listed = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: "homebrew-manage-doctor", source: "manage", sequence: 1, result: report("Old advice"), failure: nil)), of: plugin, answering: services()).answer()
        let row = try XCTUnwrap(listed.page?.collection?.items.first)
        let detail = try helper.run(PluginTestInvocation("brew.doctor", event: .itemAction(page: "homebrew-manage-doctor", collection: "management", action: "manage-details", item: PluginPageItemSnapshot(id: row.id, section: nil, text: row.text ?? row.title), values: .null), state: listed.state), of: plugin, answering: services()).answer()
        let updated = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: try XCTUnwrap(detail.page?.id), source: "manage", sequence: 2, result: report("New advice"), failure: nil), state: detail.state), of: plugin, answering: services()).answer()
        guard case .text(let advice)? = updated.page?.component("recommendation-guidance") else { return XCTFail("Missing updated advice") }
        XCTAssertEqual(advice.text, "New advice")
        let removed = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: try XCTUnwrap(updated.page?.id), source: "manage", sequence: 3, result: .object(["findings": .array([])]), failure: nil), state: updated.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(removed.page?.id, "homebrew-manage-doctor")
        XCTAssertNil(removed.page?.component("recommendation-guidance"))
        XCTAssertNil(removed.operation)
    }

    func testTaskLoadingFailureAndEmptyResultsRemainDistinctAndFailedRefreshKeepsKnownDetail() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opened = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-home", action: "task-details", values: .null, selection: .null)), of: plugin, answering: services()).answer()
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(opened.pageJSON), as: UTF8.self).contains("Loading tasks"))
        let empty = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 1, result: .array([]), failure: nil), state: opened.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(empty.pageJSON), as: UTF8.self).contains("No Homebrew tasks yet"))
        let failure = PluginViewEvent.sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 2, result: nil, failure: .init(category: .hostServiceFailed, message: "Runner unavailable"))
        let failed = try helper.run(PluginTestInvocation("brew.open", event: failure, state: empty.state), of: plugin, answering: services()).answer()
        let failedText = String(decoding: try JSONEncoder().encode(failed.pageJSON), as: UTF8.self)
        XCTAssertTrue(failedText.contains("Runner unavailable"))
        XCTAssertFalse(failedText.contains("No Homebrew tasks yet"))
        let known: JSONValue = .object(["progress": .bool(true), "taskID": .string("activity_known"), "tasks": .array([.object(["id": .string("activity_known"), "kind": .string("task"), "name": .string("install wget"), "status": .string("running"), "stage": .string("fetching"), "log": .array([.string("Known log")])])])])
        let stale = try helper.run(PluginTestInvocation("brew.open", event: failure, state: known), of: plugin, answering: services()).answer()
        let staleText = String(decoding: try JSONEncoder().encode(stale.pageJSON), as: UTF8.self)
        XCTAssertEqual(stale.page?.id, "homebrew-task-activity_known")
        XCTAssertTrue(staleText.contains("Known log"))
        XCTAssertTrue(staleText.contains("Runner unavailable"))
        XCTAssertNil(stale.operation)
    }

    func testPreviewCanOpenTasksAndReturnToTheSamePreviewWithoutStartingWork() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let initial: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget")]), "detailLoaded": .bool(true)])
        let preview = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "previewInstall", values: .null, selection: .null), state: initial), of: plugin, answering: services()).answer()
        let tasks = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(preview.page?.id), action: "task-details", values: .null, selection: .null), state: preview.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(tasks.page?.id, "homebrew-progress")
        XCTAssertNil(tasks.operation)
        let returned = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(tasks.page?.id), action: "browse", values: .null, selection: .null), state: tasks.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(returned.page?.id, preview.page?.id)
        XCTAssertEqual(returned.page?.sources.first?.input, preview.page?.sources.first?.input)
        XCTAssertNil(returned.operation)
    }

    func testPackageSectionsKeepTheirOwnFiltersAndHideAdvancedFiltersUntilRequested() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("brew.installed", of: try plugin(), helper: helper, answering: services())
        try page.open()
        XCTAssertNil(page.page?.component("sort"))
        try page.type("wget", into: "filter")
        try page.click("filter-options")
        XCTAssertNotNil(page.page?.component("sort"))
        try page.choose("outdated", in: "browse")
        XCTAssertEqual(page.text(of: "filter"), "")
        XCTAssertEqual(page.state.value(atPointer: "/filter"), .string(""))
        try page.choose("installed", in: "browse")
        XCTAssertEqual(page.text(of: "filter"), "wget")
        XCTAssertEqual(page.state.value(atPointer: "/filter"), .string("wget"))
        XCTAssertNil(try page.lastAnswer().operation)
    }

    func testPackageDetailsKeepAdvancedControlsBehindAnExplicitOptionsStep() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let initial: JSONValue = .object(["detail": .object(["kind": .string("cask"), "name": .string("example"), "installed_version": .string("1"), "languages": .array([.string("en"), .string("zh")])]), "detailLoaded": .bool(true)])
        let detail = try helper.run(PluginTestInvocation("brew.open", state: initial), of: plugin, answering: services()).answer()
        XCTAssertNil(detail.page?.component("zap"))
        XCTAssertNil(detail.page?.component("language"))
        let options = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(detail.page?.id), action: "package-options", values: .null, selection: .null), state: detail.state), of: plugin, answering: services()).answer()
        XCTAssertNotEqual(options.page?.id, detail.page?.id)
        XCTAssertNotNil(options.page?.component("zap"))
        XCTAssertNotNil(options.page?.component("language"))
        XCTAssertNil(options.operation)
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(options.page?.id), action: "package-options-back", values: .null, selection: .null), state: options.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(back.page?.id, detail.page?.id)
        XCTAssertNil(back.page?.component("zap"))
        XCTAssertNil(back.operation)
    }

    func testTasksOpenOneResultAndReturnToTheTaskListWithoutReplayingWork() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let tasks: [JSONValue] = [
            .object(["id": .string("activity_first"), "kind": .string("task"), "name": .string("install wget"), "status": .string("ended"), "stage": .string("finished"), "result": .object(["outcome": .string("completed")]), "log": .array([.string("Wget installed")])]),
            .object(["id": .string("activity_second"), "kind": .string("task"), "name": .string("upgrade curl"), "status": .string("running"), "stage": .string("fetching"), "log": .array([.string("Downloading curl")])])
        ]
        let list = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 1, result: .array(tasks), failure: nil), state: .object(["progress": .bool(true)])), of: plugin, answering: services()).answer()
        XCTAssertEqual(list.page?.collection?.items.count, 2)
        let listedJSON = String(decoding: try JSONEncoder().encode(list.pageJSON), as: UTF8.self)
        XCTAssertFalse(listedJSON.contains("Wget installed"))
        let selected = try helper.run(PluginTestInvocation("brew.open", event: .itemAction(page: try XCTUnwrap(list.page?.id), collection: "tasks", action: "show-task", item: PluginPageItemSnapshot(id: "activity_first", section: nil, text: "install wget"), values: .null), state: list.state), of: plugin, answering: services()).answer()
        let selectedJSON = String(decoding: try JSONEncoder().encode(selected.pageJSON), as: UTF8.self)
        XCTAssertNotEqual(selected.page?.id, list.page?.id)
        XCTAssertTrue(selectedJSON.contains("Wget installed"))
        XCTAssertFalse(selectedJSON.contains("Downloading curl"))
        XCTAssertNil(selected.operation)
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(selected.page?.id), action: "tasks-back", values: .null, selection: .null), state: selected.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(back.page?.id, list.page?.id)
        XCTAssertEqual(back.page?.collection?.items.count, 2)
        XCTAssertNil(back.operation)
    }

    func testWorkflowNavigationSeparatesManagementDetailsAndPreservesPackageSearchOnReturn() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let servicesPage = PluginTestPage("brew.services", of: plugin, helper: helper, answering: services())
        try servicesPage.open()
        let listID = try XCTUnwrap(servicesPage.page?.id)
        let delivered = try helper.run(PluginTestInvocation("brew.services", event: .sourceDelivered(page: listID, source: "manage", sequence: 1,
            result: .object(["services": .array([.object(["name": .string("redis"), "status": .string("stopped"), "user_owned": .bool(true)])])]), failure: nil), state: servicesPage.state), of: plugin, answering: services()).answer()
        let item = try XCTUnwrap(delivered.page?.collection?.items.first)
        let detail = try helper.run(PluginTestInvocation("brew.services", event: .itemAction(page: listID, collection: "management", action: "manage-details",
            item: PluginPageItemSnapshot(id: item.id, section: nil, text: item.text ?? item.title), values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertNotEqual(detail.page?.id, listID)
        XCTAssertNil(detail.page?.component("browse"))
        let back = try helper.run(PluginTestInvocation("brew.services", event: .pageActionChosen(page: try XCTUnwrap(detail.page?.id), action: "manage-back", values: .null, selection: .null), state: detail.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(back.page?.id, listID)
        XCTAssertEqual(back.page?.collection?.items.first?.id, item.id)
        let packagePage = PluginTestPage("brew.search", of: plugin, helper: helper, answering: services())
        try packagePage.open()
        try packagePage.type("wget", into: "query")
        try packagePage.click("home")
        try packagePage.choose(itemAction: "navigate", on: "installed")
        let installedID = packagePage.page?.id
        XCTAssertNil(packagePage.page?.component("query"))
        try packagePage.click("home")
        try packagePage.choose(itemAction: "navigate", on: "search")
        XCTAssertNotEqual(packagePage.page?.id, installedID)
        XCTAssertEqual(packagePage.text(of: "query"), "wget")
    }

    func testHomeNavigationExplainsWorkflowsAndDirectActionsStillOpenTheirDestination() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("brew.open", of: plugin, helper: helper, answering: services())
        try page.open()
        XCTAssertEqual(page.page?.id, "homebrew-home")
        XCTAssertNil(page.pageJSON?.value(atPointer: "/sources"))
        XCTAssertNotNil(page.page?.component("destinations"))
        XCTAssertTrue(page.page?.collection?.items.contains { $0.id == "installed" } == true)
        XCTAssertTrue(page.page?.collection?.items.contains { $0.id == "activity" } == true)
        try page.choose(itemAction: "navigate", on: "installed")
        XCTAssertEqual(page.page?.sources.first?.input.value(atPointer: "/operation"), .string("installed"))
        try page.click("home")
        XCTAssertEqual(page.page?.id, "homebrew-home")
        let direct = try helper.run(PluginTestInvocation("brew.outdated"), of: plugin, answering: services()).answer()
        XCTAssertEqual(direct.page?.sources.first?.input.value(atPointer: "/operation"), .string("outdated"))
        XCTAssertNil(direct.operation)
    }

    func testLinkGesturesPreviewConcreteChangesBeforeOfferingAHostTask() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("libtommath"), "installed_version": .string("1.3.0"), "linked": .bool(false), "linkable": .bool(true)]), "detailLoaded": .bool(true)])
        let requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "link", values: .null, selection: .null), state: state), of: plugin, answering: services()).answer()
        XCTAssertNil(requested.operation)
        XCTAssertEqual(requested.page?.id, "homebrew-preview")
        XCTAssertEqual(requested.page?.sources.first?.input.value(atPointer: "/operation"), .string("previewLink"))
    }
    func testLinkPreviewRefusalsNoopsAndStaleDeliveriesCannotOfferTasksWhileCompletePlansPageAllChanges() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("example"), "installed_version": .string("1")]), "detailLoaded": .bool(true)])
        var requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "link", values: .null, selection: .null), state: state), of: plugin, answering: services()).answer()
        let changes: [JSONValue] = (0..<200).map { .object(["action": .string("link"), "path": .string("/opt/homebrew/bin/example-\($0)"), "source": .string("/opt/homebrew/Cellar/example/1/bin/example-\($0)")]) }
        let success: [String: JSONValue] = ["available": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false), "truncated": .bool(false),
            "kind": .string("formula"), "name": .string("example"), "package": .object(["kind": .string("formula"), "name": .string("example")]),
            "paths_fingerprint": .string(String(repeating: "a", count: 64)), "changes": .array(changes), "summary": .string("Concrete links and metadata"), "warnings": .array([.string("Related formula also unlinked")])]
        let source = try XCTUnwrap(requested.page?.sources.first?.id)
        for invalid in [["succeeded": JSONValue.bool(false)], ["complete": .bool(false)], ["no_op": .bool(true)], ["truncated": .bool(true)]] {
            let refused = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: source, sequence: 1, result: .object(success.merging(invalid) { _, new in new }), failure: nil), state: requested.state), of: plugin, answering: services()).answer()
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(refused.pageJSON), as: UTF8.self).contains("\"id\":\"review-link\""))
            let forged = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-preview", action: "review-link", values: .null, selection: .null), state: refused.state), of: plugin, answering: services()).answer()
            XCTAssertNil(forged.operation)
        }
        let ready = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: source, sequence: 2, result: .object(success), failure: nil), state: requested.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(ready.page?.collection?.total, 201)
        let last = try helper.run(PluginTestInvocation("brew.open", event: .loadRange(page: "homebrew-preview", collection: "preview-lines", start: 180, count: 40), state: ready.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(last.page?.collection?.items.contains { $0.text?.contains("example-199") == true } == true)
        let task = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-preview", action: "review-link", values: .null, selection: .null), state: ready.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(task.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("example")]))
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-preview", action: "preview-back", values: .null, selection: .null), state: ready.state), of: plugin, answering: services()).answer()
        requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "link", values: .null, selection: .null), state: back.state), of: plugin, answering: services()).answer()
        XCTAssertNotEqual(requested.page?.sources.first?.id, source)
        let stale = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: source, sequence: 3, result: .object(success), failure: nil), state: requested.state), of: plugin, answering: services()).answer()
        XCTAssertNil(stale.operation)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(stale.pageJSON), as: UTF8.self).contains("\"id\":\"review-link\""))
    }

    private var storage: PluginStorage!
    private var storageDirectory: URL!
    override func setUpWithError() throws {
        storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = PluginStorage(directory: storageDirectory)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: storageDirectory) }
    private func services(operations: [String: RecordedHostServices.Answer] = [:]) -> RecordedHostServices {
        RecordedHostServices(operations: operations, storage: storage)
    }
    private func plugin() throws -> PluginUnderTest {
        try PluginUnderTest(named: "Homebrew.spinnetplugin", origin: .bundled)
    }
    func testInstalledActionBrowsesPackagesAndSearchOnlyShowsRelevantInput() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("brew.installed", of: try plugin(), helper: helper, answering: services(operations: ["activities.list": .value(.array([]))]))
        try page.open()
        XCTAssertEqual(page.pageJSON?.value(atPointer: "/sources/0/input/operation"), .string("installed"))
        XCTAssertNil(page.page?.component("query"))
        try page.choose("search", in: "browse")
        XCTAssertEqual(page.state.value(atPointer: "/mode"), .string("search"))
        XCTAssertNil(page.pageJSON?.value(atPointer: "/sources"))
        try page.type("wget", into: "query")
        XCTAssertEqual(page.pageJSON?.value(atPointer: "/sources/0/input/query"), .string("wget"))
    }
    func testDeliveredPackagesOpenExactDetailAndPreserveBrowseOnBack() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result: JSONValue = .object(["packages": .array([.object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1.25")])])])
        let delivered = helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: result, failure: nil)), of: plugin, answering: services())
        let browse = try delivered.answer()
        let shown = try XCTUnwrap(browse.page?.collection?.items.first)
        let item = PluginPageItemSnapshot(id: shown.id, section: nil, text: shown.text ?? shown.title)
        let detailRun = helper.run(PluginTestInvocation("brew.open", event: .itemAction(page: "homebrew-browse", collection: "packages", action: "details", item: item, values: .null), state: browse.state ?? .null), of: plugin, answering: services())
        let detail = try detailRun.answer()
        XCTAssertEqual(detail.page?.sources.first?.input, .object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("wget")])]))
    }
    func testPackageInstallRequestsTrustedHostTaskAndProgressComesFromOwnActivities() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1.25"), "tap": .string("homebrew/core")]), "detailLoaded": .bool(true)])
        let event = PluginViewEvent.pageActionChosen(page: "homebrew-detail", action: "install", values: .null, selection: .null)
        let invocation = PluginTestInvocation("brew.open", event: event, state: state)
        let run = helper.run(invocation, of: plugin, answering: services())
        let answer = try run.answer()
        XCTAssertEqual(answer.operation?.perform, "tools.startTask")
        XCTAssertEqual(answer.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        XCTAssertTrue(answer.operation?.notify == true)
        let operations = RecordedHostOperations()
        XCTAssertEqual(try operations.perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
    }
    func testVisibleTaskStateProvidesBoundedProgressAndCancellationAndDeniedStartIsRefused() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let id = "activity_00000000000000000000000000000001"
        let result: JSONValue = .array([.object(["id": .string(id), "kind": .string("task"), "name": .string("install wget"), "status": .string("running"), "stage": .string("fetching"), "elapsed_seconds": .number(12), "log": .array([.string("Downloading wget")])])])
        let state: JSONValue = .object(["progress": .bool(true), "taskID": .string(id)])
        let delivered = helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 1, result: result, failure: nil), state: state), of: plugin, answering: services())
        let answer = try delivered.answer()
        guard case .progress(let progress)? = answer.page?.component("progress-" + id) else { return XCTFail("Expected selected task progress") }
        XCTAssertEqual(progress.state, .running)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(answer.pageJSON), as: UTF8.self).contains("Downloading wget"))
        helper.retireHelper(of: plugin)
        let cancelEvent = PluginViewEvent.pageActionChosen(page: "homebrew-progress", action: "cancel-" + id, values: .null, selection: .null)
        let cancelled = helper.run(PluginTestInvocation("brew.open", event: cancelEvent, state: answer.state), of: plugin, answering: services())
        XCTAssertEqual(try cancelled.answer().operation?.input, .object(["id": .string(id)]))
        XCTAssertEqual(helper.launchCount, 2)
        let installState: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget")])])
        let invocation = PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "install", values: .null, selection: .null), state: installState)
        let start = helper.run(invocation, of: plugin, answering: services())
        let denied = RecordedHostOperations(deniedCapabilities: [.runReviewedToolTasks])
        XCTAssertThrowsError(try denied.perform(start, of: plugin, for: invocation)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.runReviewedToolTasks)) }
    }
    func testLargePackageResultsUseWindowedCollectionAndKeepStateBounded() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let packages = (0..<500).map { JSONValue.object(["kind": .string("formula"), "name": .string("package\($0)")]) }
        let delivered = helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: .object(["packages": .array(packages)]), failure: nil)), of: plugin, answering: services())
        let answer = try delivered.answer()
        XCTAssertEqual(answer.page?.collection?.total, 500)
        XCTAssertLessThan(try JSONEncoder().encode(answer.state).count, 65536)
        let next = helper.run(PluginTestInvocation("brew.open", event: .loadRange(page: "homebrew-browse", collection: "packages", start: 400, count: 40), state: answer.state), of: plugin, answering: services())
        XCTAssertEqual(try next.answer().page?.collection?.items.first?.title, "package400")
    }
    func testManagementRefreshChangesSourceIdentityAndTapPackagesOpenDetails() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let opening = helper.run(PluginTestInvocation("brew.taps"), of: plugin, answering: services())
        let opened = try opening.answer()
        XCTAssertEqual(opened.page?.sources.first?.input.value(atPointer: "/operation"), .string("taps"))
        let refresh = helper.run(PluginTestInvocation("brew.taps", event: .pageActionChosen(page: "homebrew-manage-taps", action: "refresh", values: .null, selection: .null), state: opened.state), of: plugin, answering: services())
        let refreshed = try refresh.answer()
        XCTAssertNotEqual(refreshed.page?.sources.first?.id, opened.page?.sources.first?.id)
        let state: JSONValue = .object(["mode": .string("taps"), "manageDetail": .object(["name": .string("acme/tools"), "trusted": .bool(true)])])
        let result: JSONValue = .object(["taps": .array([.object(["name": .string("acme/tools"), "packages": .array([.object(["name": .string("acme/tools/wget"), "kind": .string("formula")])])])])])
        let delivered = helper.run(PluginTestInvocation("brew.taps", event: .sourceDelivered(page: "homebrew-manage-taps", source: "tap-packages", sequence: 1, result: result, failure: nil), state: state), of: plugin, answering: services())
        let answer = try delivered.answer()
        XCTAssertEqual(answer.page?.collection?.items.first?.title, "acme/tools/wget")
        let detail = helper.run(PluginTestInvocation("brew.taps", event: .itemAction(page: "homebrew-manage-taps", collection: "tap-packages", action: "tap-package", item: PluginPageItemSnapshot(id: try XCTUnwrap(answer.page?.collection?.items.first?.id), section: nil, text: "acme/tools/wget"), values: .null), state: answer.state), of: plugin, answering: services())
        XCTAssertEqual(try detail.answer().page?.sources.first?.input.value(atPointer: "/names/0"), .string("acme/tools/wget"))
    }

    func testEveryCommandOpensValidWorkflowAndManagementActionsStayTyped() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        for command in ["brew.installed", "brew.search", "brew.outdated", "brew.vulnerabilities", "brew.doctor", "brew.adopt", "brew.upgrade", "brew.services", "brew.taps", "brew.cleanup", "brew.clear-cache"] {
            let run = helper.run(PluginTestInvocation(command), of: plugin, answering: services())
            XCTAssertNotNil(try run.answer().page, command)
        }
        let cases: [(String, JSONValue, String, String)] = [
            ("services", .object(["name": .string("redis"), "status": .string("stopped"), "user_owned": .bool(true)]), "serviceStart", "serviceStart"),
            ("taps", .object(["name": .string("acme/tools"), "trusted": .bool(false)]), "trust", "trust"),
            ("doctor", .object(["text": .string("Broken link"), "repairs": .array([.object(["title": .string("Link Package"), "target": .string("fix_123")])])]), "fix-0", "doctorFix"),
            ("adopt", .object(["name": .string("Firefox"), "bundle_id": .string("org.mozilla.firefox"), "version": .string("1"), "target": .string("app_123")]), "adopt", "adopt")
        ]
        for (mode, selected, action, expected) in cases {
            if mode == "doctor" {
                _ = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: "homebrew-manage-doctor", source: "manage", sequence: 1, result: .object(["findings": .array([selected])]), failure: nil)), of: plugin, answering: services()).answer()
            }
            var fields: [String: JSONValue] = ["mode": .string(mode), "manageDetail": selected]
            if mode == "adopt" {
                fields["caskName"] = .string("firefox")
                fields["adoptionRequest"] = .object(["tool": .string("homebrew"), "operation": .string("adoptionPreview"), "target": .string("app_123"), "name": .string("firefox")])
                fields["adoption"] = .object(["succeeded": .bool(true), "summary": .string("Adopt Firefox"), "target": .string("adoption_123")])
            }
            let invocation = PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-manage-" + mode, action: action, values: .null, selection: .null), state: .object(fields))
            let run = helper.run(invocation, of: plugin, answering: services())
            XCTAssertEqual(try run.answer().operation?.input.value(atPointer: "/operation"), .string(expected))
            XCTAssertEqual(try RecordedHostOperations().perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
        }
    }
    func testFailedManagementReadShowsMessageAndAdoptionNeedsVerifiedPreviewTarget() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("adopt"), "manageDetail": .object(["name": .string("Firefox"), "target": .string("app_123"), "version": .string("1")]), "caskName": .string("firefox")])
        let preview = helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "preview-adoption", values: .null, selection: .null), state: state), of: plugin, answering: services())
        let answer = try preview.answer()
        XCTAssertEqual(answer.page?.sources.last?.input.value(atPointer: "/target"), .string("app_123"))
        let beforeReview = helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "adopt", values: .null, selection: .null), state: state), of: plugin, answering: services())
        XCTAssertNil(try beforeReview.answer().operation)
    }

    func testServicesMenuOpensControlledHostSurface() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let invocation = PluginTestInvocation("brew.services-menu")
        let run = helper.run(invocation, of: plugin, answering: services())
        XCTAssertEqual(try run.answer().operation?.perform, "tools.showServices")
        XCTAssertEqual(try run.answer().operation?.input.value(atPointer: "/presentation"), .string("menu"))
        XCTAssertEqual(try RecordedHostOperations().perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
    }

    func testCaskDetailOffersHostPathAndVerifiedLanguageReinstall() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("cask"), "name": .string("firefox"), "installed_version": .string("1"), "installed_path": .string("/opt/homebrew/Caskroom/firefox"), "languages": .array([.string("en-US"), .string("en-GB")])]), "detailLoaded": .bool(true), "language": .string("en-GB")])
        let invocation = PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "change-language", values: .null, selection: .null), state: state)
        let run = helper.run(invocation, of: plugin, answering: services())
        let answer = try run.answer()
        XCTAssertEqual(answer.operation?.input.value(atPointer: "/operation"), .string("changeLanguage"))
        XCTAssertEqual(answer.operation?.input.value(atPointer: "/language"), .string("en-GB"))
        XCTAssertEqual(try RecordedHostOperations().perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
    }

    func testMaximumBoundedHostResultCachesAcrossStorageValueBudget() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let packages = (0..<2000).map { JSONValue.object(["kind": .string("formula"), "name": .string("package\($0)"), "description": .string(String(repeating: "d", count: 240))]) }
        let result: JSONValue = .object(["packages": .array(packages)])
        XCTAssertGreaterThan(try JSONEncoder().encode(result).count, PluginStorageBudgets.maximumValueBytes)
        let run = helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: result, failure: nil)), of: plugin, answering: services())
        XCTAssertEqual(try run.answer().page?.collection?.total, 2000)
    }

}

extension HomebrewTests {
    func testMaximumPreviewKeepsStateBoundedAndFullDiagnosticReachable() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["previewPage": .bool(true), "previewInput": .object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("wget")])])])
        let output = String(repeating: "Actual Homebrew dependency and download details.\n", count: 1800)
        let result: JSONValue = .object(["available": .bool(true), "dry_run": .bool(true), "succeeded": .bool(true), "summary": .string("Actual dry-run"), "stages": .array([.object(["title": .string("Dependencies"), "lines": .array([.string(output)])])]), "stderr": .string("Warning: final download size is unknown")])
        let delivered = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: "preview", sequence: 1, result: result, failure: nil), state: state), of: plugin, answering: services()).answer()
        XCTAssertLessThan(try JSONEncoder().encode(delivered.state).count, 65536)
        XCTAssertGreaterThan(delivered.page?.collection?.total ?? 0, 20)
        let count = delivered.page?.collection?.total ?? 0
        let selected = try helper.run(PluginTestInvocation("brew.open", event: .itemAction(page: "homebrew-preview", collection: "preview-lines", action: "preview-line", item: PluginPageItemSnapshot(id: String(count - 1), section: nil, text: "Diagnostics"), values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        guard case .text(let diagnostic)? = selected.page?.component("preview-line-text") else { return XCTFail("Expected full preview step") }
        XCTAssertEqual(diagnostic.text, "Warning: final download size is unknown")
        XCTAssertNil(selected.operation)
    }

    func testBatchPreviewsHonorKindSelectionAndGreedyWithoutStartingTasks() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("outdated"), "kind": .string("both"), "greedy": .string("on"), "selectedUpgrades": .object(["formula": .array([.string("wget")]), "cask": .array([.string("spotify")])])])
        for (action, expected) in [("preview-upgrade-all", "previewUpgradeAll"), ("preview-selected-formula", "previewUpgrade"), ("preview-selected-cask", "previewUpgrade")] {
            let invocation = PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-browse", action: action, values: .null, selection: .null), state: state)
            let answer = try helper.run(invocation, of: plugin, answering: services()).answer()
            XCTAssertEqual(answer.page?.id, "homebrew-preview")
            XCTAssertEqual(answer.page?.sources.first?.input.value(atPointer: "/operation"), .string(expected))
            XCTAssertNil(answer.operation)
            if action != "preview-selected-formula" { XCTAssertEqual(answer.page?.sources.first?.input.value(atPointer: "/greedy"), .bool(true)) }
            if action == "preview-upgrade-all" { XCTAssertNil(answer.page?.sources.first?.input.value(atPointer: "/kind")) }
            else { XCTAssertNotNil(answer.page?.sources.first?.input.value(atPointer: "/names/0")) }
        }
    }

    func testActualPreviewUsesDedicatedBoundedPageAndPreservesRefusalDiagnostics() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget")]), "detailLoaded": .bool(true)])
        let requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "previewInstall", values: .null, selection: .null), state: state), of: plugin, answering: services()).answer()
        XCTAssertEqual(requested.page?.id, "homebrew-preview")
        XCTAssertNil(requested.operation)
        XCTAssertEqual(requested.page?.sources.first?.input.value(atPointer: "/operation"), .string("previewInstall"))
        let result: JSONValue = .object(["available": .bool(true), "estimated": .bool(false), "dry_run": .bool(true), "succeeded": .bool(false), "exit_status": .number(1), "summary": .string("Homebrew refused the dry-run."),
            "stages": .array([.object(["title": .string("Would install 1 formula:"), "lines": .array([.string("wget 1.25.0 (2 MB)")])])]), "stderr": .string("Error: wget is pinned"), "warnings": .array([.string("Warning: size unavailable for libidn2")])])
        let delivered = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: "preview", sequence: 1, result: result, failure: nil), state: requested.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(delivered.page?.id, "homebrew-preview")
        let json = String(decoding: try JSONEncoder().encode(delivered.pageJSON), as: UTF8.self)
        XCTAssertTrue(json.contains("wget 1.25.0 (2 MB)"))
        XCTAssertTrue(json.contains("Error: wget is pinned"))
        XCTAssertTrue(json.contains("Warning: size unavailable for libidn2"))
        XCTAssertTrue(json.contains("Exit status: 1"))
        XCTAssertNil(delivered.operation)
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-preview", action: "preview-back", values: .null, selection: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(back.page?.id.hasPrefix("homebrew-detail-") == true)
        XCTAssertEqual(back.state.value(atPointer: "/detail/name"), .string("wget"))
    }

    func testBatchUpgradeButtonsReturnConcreteHostOperations() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("outdated"), "kind": .string("both"), "greedy": .string("on"),
            "selectedUpgrades": .object(["formula": .array([.string("wget")]), "cask": .array([.string("spotify")])])])
        for (action, expected) in [("upgrade-all", "upgradeAll"), ("upgrade-selected-formula", "upgradeSelected"), ("upgrade-selected-cask", "upgradeSelected")] {
            let invocation = PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-browse", action: action, values: .null, selection: .null), state: state)
            let run = helper.run(invocation, of: plugin, answering: services())
            let answer = try run.answer()
            XCTAssertEqual(answer.operation?.perform, "tools.startTask")
            XCTAssertEqual(answer.operation?.input.value(atPointer: "/operation"), .string(expected))
            if action == "upgrade-all" { XCTAssertEqual(answer.operation?.input.value(atPointer: "/greedy"), .bool(true)) }
            else { XCTAssertNotNil(answer.operation?.input.value(atPointer: "/names/0")); if action == "upgrade-selected-cask" { XCTAssertEqual(answer.operation?.input.value(atPointer: "/greedy"), .bool(true)) } }
            XCTAssertEqual(try RecordedHostOperations().perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
        }
    }
}

extension HomebrewTests {
    func testReopenedActivityIncludesEndedTaskLogsWithoutMutationReplay() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let open = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-browse", action: "task-details", values: .null, selection: .null)), of: plugin, answering: services()).answer()
        XCTAssertEqual(open.page?.id, "homebrew-progress")
        XCTAssertEqual(open.page?.sources.first?.perform, "activities.list")
        let task: JSONValue = .object(["kind": .string("task"), "id": .string("activity_01234567890123456789012345678901"), "name": .string("Install wget"), "status": .string("ended"), "stage": .string("completed"), "log": .array([.string("Installed successfully")]), "result": .object(["outcome": .string("completed")])])
        let done = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 1, result: .array([task]), failure: nil), state: open.state), of: plugin, answering: services()).answer()
        let details = try helper.run(PluginTestInvocation("brew.open", event: .itemAction(page: "homebrew-progress", collection: "tasks", action: "show-task", item: PluginPageItemSnapshot(id: "activity_01234567890123456789012345678901", section: nil, text: "Install wget"), values: .null), state: done.state), of: plugin, answering: services()).answer()
        guard case .progress(let progress)? = details.page?.component("progress-activity_01234567890123456789012345678901") else { return XCTFail("Expected completed task progress") }
        XCTAssertEqual(progress.state, .succeeded)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(details.pageJSON), as: UTF8.self).contains("Installed successfully"))
        XCTAssertNil(details.operation)
        XCTAssertNil(done.operation)
    }
}

extension HomebrewTests {
    func testVulnerabilityCoverageAndSkippedPackagesNeverAppearAsCleanInventory() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let inventory = try securityInventory(["legacy"], helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        let result: JSONValue = .object(["available": .bool(true), "checked": .number(0), "truncated": .bool(true), "findings": .array([]), "skipped": .array([.object(["name": .string("legacy"), "reason": .string("installed_source_unavailable_or_unsupported")])])])
        let answer = try securityReport(result, into: started, helper: helper, plugin: plugin)
        let text = String(decoding: try JSONEncoder().encode(answer.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("0 checked"))
        XCTAssertTrue(text.contains("1 not checked"))
        XCTAssertTrue(text.contains("legacy"))
        XCTAssertTrue(text.contains("Incomplete"))
        XCTAssertTrue(text.contains("Choose Tools"))
        XCTAssertTrue(answer.page?.sources.isEmpty == true)
    }

}

extension HomebrewTests {
    func testDoctorGuidanceLinksAndFixAllKeepOpaqueHostAuthority() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let report: JSONValue = .object(["available": .bool(true), "context": .object(["scope": .string("host"), "shell_path": .string("not_checked"), "directory_access": .string("reported_paths_rechecked"), "unverified_directory_checks": .number(0)]), "fix_all": .object(["target": .string("fix_reviewedset"), "title": .string("Review two supported repairs"), "count": .number(2), "repairs": .array([.object(["title": .string("Link wget")]), .object(["title": .string("Clean stale downloads")])])]), "findings": .array([.object(["id": .string("0"), "text": .string("Unlinked keg"), "guidance": .string("Review these recommendations"), "links": .array([.string("https://docs.brew.sh/Troubleshooting")]), "commands": .array([]), "repairs": .array([])])])])
        let delivered = try helper.run(PluginTestInvocation("brew.doctor", event: .sourceDelivered(page: "homebrew-manage-doctor", source: "manage", sequence: 1, result: report, failure: nil)), of: plugin, answering: services()).answer()
        let fix = try helper.run(PluginTestInvocation("brew.doctor", event: .pageActionChosen(page: "homebrew-manage-doctor", action: "fix-all", values: .null, selection: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertNil(fix.operation)
        XCTAssertEqual(fix.page?.id, "homebrew-doctor-repairs")
        let previewText = String(decoding: try JSONEncoder().encode(fix.pageJSON), as: UTF8.self)
        XCTAssertTrue(previewText.contains("Link wget"))
        XCTAssertTrue(previewText.contains("Clean stale downloads"))
        let confirm = try helper.run(PluginTestInvocation("brew.doctor", event: .pageActionChosen(page: "homebrew-doctor-repairs", action: "confirm-doctor-repairs", values: .null, selection: .null), state: fix.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(confirm.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("doctorFix"), "target": .string("fix_reviewedset")]))
        let detail = try helper.run(PluginTestInvocation("brew.doctor", event: .itemAction(page: "homebrew-manage-doctor", collection: "management", action: "manage-details", item: PluginPageItemSnapshot(id: try XCTUnwrap(delivered.page?.collection?.items.first?.id), section: nil, text: "Unlinked keg"), values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        let text = String(decoding: try JSONEncoder().encode(detail.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("Review these recommendations"))
        XCTAssertTrue(text.contains("docs.brew.sh"))
    }
}

extension HomebrewTests {
    func testAutomaticAdoptionMatchesAreGroupedAndWrongMatchesCanBeIgnoredAndRestored() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let app: JSONValue = .object(["target": .string("app_123"), "name": .string("Example"), "bundle_id": .string("org.example.app"), "version": .string("2.0"), "candidates": .array([.object(["name": .string("example"), "confidence": .string("ready"), "reason": .string("Bundle identifier matches")])])])
        let delivered = try helper.run(PluginTestInvocation("brew.adopt", event: .sourceDelivered(page: "homebrew-manage-adopt", source: "manage", sequence: 1, result: .object(["applications": .array([app])]), failure: nil)), of: plugin, answering: services()).answer()
        XCTAssertEqual(delivered.page?.collection?.sections.first?.title, "Ready to Adopt")
        let snapshot = PluginPageItemSnapshot(id: try XCTUnwrap(delivered.page?.collection?.items.first?.id), section: "ready", text: "Example")
        let detail = try helper.run(PluginTestInvocation("brew.adopt", event: .itemAction(page: "homebrew-manage-adopt", collection: "management", action: "manage-details", item: snapshot, values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(detail.state.value(atPointer: "/caskName"), .string("example"))
        let ignored = try helper.run(PluginTestInvocation("brew.adopt", event: .itemAction(page: "homebrew-manage-adopt", collection: "management", action: "ignore-adoption", item: snapshot, values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(ignored.page?.collection?.total, 0)
        let showIgnored = try helper.run(PluginTestInvocation("brew.adopt", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "refresh", values: .object(["adoptionFilter": .string("ignored")]), selection: .null), state: ignored.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(showIgnored.page?.collection?.total, 1)
        let restored = try helper.run(PluginTestInvocation("brew.adopt", event: .itemAction(page: "homebrew-manage-adopt", collection: "management", action: "ignore-adoption", item: snapshot, values: .null), state: showIgnored.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(restored.page?.collection?.total, 0)
        XCTAssertNil(restored.operation)
    }
}

extension HomebrewTests {
    func testMaximumSecurityReportAndReferenceDetailRemainNavigableWithinPageLimits() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let advisories = (0..<40).map { JSONValue.object(["id": .string("CVE-2026-\($0)"), "summary": .string("Issue \($0)"), "status": .string("unknown")]) }
        let selected: JSONValue = .object(["name": .string("example"), "advisories": .array(advisories), "unknown_count": .number(40)])
        let skipped = (0..<20).map { JSONValue.object(["name": .string("skipped\($0)"), "reason": .string("Unsupported installed source")]) }
        let state: JSONValue = .object(["mode": .string("vulnerabilities"), "manageDetail": selected, "advisoryID": .string("CVE-2026-0"), "securitySession": .string("fixture-session"), "securityStatus": .string("complete"), "manageResult": .object(["checked": .number(20), "total": .number(40), "skipped": .array(skipped), "findings": .array([selected])])])
        let refs = (0..<20).map { JSONValue.string("https://security.example/reference/\($0)") }
        let result: JSONValue = .object(["advisory": .object(["id": .string("CVE-2026-0"), "details": .string("Detailed advisory"), "fixed_versions": .array([.string("2.0")]), "references": .array(refs)])])
        let detail = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-manage-vulnerabilities", source: "advisory", sequence: 1, result: result, failure: nil), state: state), of: plugin, answering: services()).answer()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(detail.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("https://security.example/reference/19"))
        XCTAssertTrue(text.contains("2.0"))
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-advisory", action: "advisory-back", values: .null, selection: .null), state: detail.state), of: plugin, answering: services()).answer()
        let backText = String(decoding: try JSONEncoder().encode(back.pageJSON), as: UTF8.self)
        XCTAssertTrue(backText.contains("CVE-2026-9"))
        XCTAssertNil(back.page?.component("security-coverage"))
        let overview = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: try XCTUnwrap(back.page?.id), action: "manage-back", values: .null, selection: .null), state: back.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(overview.page?.collection?.items.contains { $0.title == "skipped19" } == true)
    }
    func testSecurityDetailsExposeAllAdvisoriesReferencesAndUpstreamFixesWithoutIneligibleUpgrade() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let advisories = (1...12).map { JSONValue.object(["id": .string("CVE-2026-\($0)"), "status": .string("unknown"), "summary": .string("Issue \($0)")]) }
        let state: JSONValue = .object(["mode": .string("vulnerabilities"), "manageDetail": .object(["name": .string("example"), "upgrade_available": .bool(false), "unknown_count": .number(12), "advisories": .array(advisories)])])
        let more = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-manage-vulnerabilities", action: "next-advisories", values: .null, selection: .null), state: state), of: plugin, answering: services()).answer()
        var text = String(decoding: try JSONEncoder().encode(more.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("CVE-2026-11"))
        XCTAssertFalse(text.contains("upgrade-security"))
        let detail: JSONValue = .object(["advisory": .object(["id": .string("CVE-2026-11"), "details": .string("Full advisory"), "fixed_versions": .array([.string("2.0")]), "references": .array([.string("https://security.example/advisory")])])])
        let delivered = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-manage-vulnerabilities", source: "advisory", sequence: 1, result: detail, failure: nil), state: more.state), of: plugin, answering: services()).answer()
        text = String(decoding: try JSONEncoder().encode(delivered.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("2.0"))
        XCTAssertTrue(text.contains("security.example"))
        XCTAssertTrue(text.contains("Needs Review"))
    }
}

extension HomebrewTests {
    func testQualifiedPackageWorkflowRequiresSeparateTypedTapTrustAndInstallGestures() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("search"), "kind": .string("formula"), "query": .string("acme/tools/example")])
        let open = try helper.run(PluginTestInvocation("brew.open", state: state), of: plugin, answering: services()).answer()
        XCTAssertEqual(open.page?.id, "homebrew-qualified")
        XCTAssertNil(open.operation)
        for (action, operation) in [("qualified-tap", "tap"), ("qualified-trust", "trust")] {
            let answer = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-qualified", action: action, values: .null, selection: .null), state: open.state), of: plugin, answering: services()).answer()
            XCTAssertEqual(answer.operation?.input, .object(["tool": .string("homebrew"), "operation": .string(operation), "tap": .string("acme/tools")]))
        }
        let detail = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-qualified", action: "qualified-inspect", values: .null, selection: .null), state: open.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(detail.page?.sources.first?.input.value(atPointer: "/names/0"), .string("acme/tools/example"))
        XCTAssertNil(detail.operation)
    }
}

extension HomebrewTests {
    func testPackageGroupingPinnedWarningsAndSingleUpdateCheckKeepAvailableActionsTruthful() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let packages: JSONValue = .array([.object(["name": .string("wget"), "kind": .string("formula"), "installed_version": .string("1"), "pinned": .bool(false)]), .object(["name": .string("example"), "kind": .string("cask"), "installed_version": .string("2"), "pinned": .bool(true), "auto_updates": .bool(true)])])
        let browse = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: .object(["packages": packages]), failure: nil)), of: plugin, answering: services()).answer()
        XCTAssertEqual(browse.page?.collection?.sections.first?.title, "Pinned Apps")
        let detailState: JSONValue = .object(["detail": .object(["name": .string("example"), "kind": .string("cask"), "installed_version": .string("2"), "pinned": .bool(true), "auto_updates": .bool(true)])])
        let detail = try helper.run(PluginTestInvocation("brew.open", state: detailState), of: plugin, answering: services()).answer()
        let text = String(decoding: try JSONEncoder().encode(detail.pageJSON), as: UTF8.self)
        XCTAssertFalse(text.contains("\"id\":\"uninstall\""))
        XCTAssertTrue(text.contains("may update itself"))
        let refreshed = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "check-updates", values: .null, selection: .null), state: detail.state), of: plugin, answering: services(operations: ["activities.list": .value(.array([]))])).answer()
        XCTAssertEqual(refreshed.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("update")]))
    }
}

extension HomebrewTests {
    func testUpdateReviewInitiallySelectsEligiblePackagesAndPinsStayLocked() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let result: JSONValue = .object(["packages": .array([.object(["name": .string("wget"), "kind": .string("formula"), "outdated": .bool(true)]), .object(["name": .string("example"), "kind": .string("cask"), "outdated": .bool(true), "pinned": .bool(true)])])])
        let answer = try helper.run(PluginTestInvocation("brew.outdated", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: result, failure: nil)), of: plugin, answering: services()).answer()
        XCTAssertEqual(answer.state.value(atPointer: "/selectedUpgrades/formula/0"), .string("wget"))
        XCTAssertNil(answer.state.value(atPointer: "/selectedUpgrades/cask/0"))
    }
}

extension HomebrewTests {
    func testPopularityRanksOnlyExplicitWindowAndShowsKnownCoverage() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let initial: JSONValue = .object(["mode": .string("installed"), "kind": .string("formula"), "sort": .string("popularity")])
        let packages: JSONValue = .object(["packages": .array([.object(["name": .string("wget"), "kind": .string("formula")]), .object(["name": .string("curl"), "kind": .string("formula")]), .object(["name": .string("unknown"), "kind": .string("formula")])])])
        let browse = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: 1, result: packages, failure: nil), state: initial), of: plugin, answering: services()).answer()
        XCTAssertEqual(browse.page?.sources.count, 1)
        let request = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-browse", action: "rank-packages", values: .null, selection: .null), state: browse.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(request.page?.sources.last?.input.value(atPointer: "/operation"), .string("packageAnalytics"))
        let result: JSONValue = .object(["rankings": .array([.object(["name": .string("wget"), "analytics": .object(["install": .object(["30d": .number(12)])])]), .object(["name": .string("curl"), "analytics": .object(["install": .object(["30d": .number(500)])])])])])
        let ranked = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-browse", source: "rankings", sequence: 1, result: result, failure: nil), state: request.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(ranked.page?.collection?.items.first?.title, "curl")
        let text = String(decoding: try JSONEncoder().encode(ranked.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("2 of 3"))
        XCTAssertTrue(text.contains("unknown"))
        XCTAssertNil(ranked.operation)
    }
}


extension HomebrewTests {
    func testPackageIdentityAndQueuedGestureSurviveRefreshWithoutSelectingAnotherPackage() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        func package(_ name: String) -> JSONValue { .object(["kind": .string("formula"), "name": .string(name), "outdated": .bool(true)]) }
        func deliver(_ packages: [JSONValue], state: JSONValue = .null, sequence: Int) throws -> PluginScriptAnswer {
            try helper.run(PluginTestInvocation("brew.outdated", event: .sourceDelivered(page: "homebrew-browse", source: "packages", sequence: sequence, result: .object(["packages": .array(packages)]), failure: nil), state: state), of: plugin, answering: services()).answer()
        }
        let first = try deliver([package("wget"), package("git")], sequence: 1)
        let shown = try XCTUnwrap(first.page?.collection?.items.first)
        let snapshot = PluginPageItemSnapshot(id: shown.id, section: nil, text: shown.text ?? "wget")
        var selection = PluginPageMemory()
        selection.show(try XCTUnwrap(first.page)); selection.select(shown.id)
        let reordered = try deliver([package("git"), package("wget")], state: first.state, sequence: 2)
        selection.show(try XCTUnwrap(reordered.page))
        XCTAssertEqual(selection.selectedItem?.title, "wget", "The real Host selection must retain the original entity")
        XCTAssertEqual(reordered.page?.collection?.items.last?.id, shown.id, "Selection must follow wget across reorder")
        let selected = try helper.run(PluginTestInvocation("brew.outdated", event: .itemAction(page: "homebrew-browse", collection: "packages", action: "details", item: snapshot, values: .null), state: reordered.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.state.value(atPointer: "/detail/name"), .string("wget"))
        let removed = try deliver([package("git")], state: reordered.state, sequence: 3)
        let refused = try helper.run(PluginTestInvocation("brew.outdated", event: .itemAction(page: "homebrew-browse", collection: "packages", action: "details", item: snapshot, values: .null), state: removed.state), of: plugin, answering: services()).answer()
        XCTAssertNil(refused.state.value(atPointer: "/detail/name"), "A disappeared wget must never resolve to git")
        XCTAssertTrue(refused.pageJSON?.value(atPointer: "/title") != .string("git"))
    }
}


extension HomebrewTests {
    func testManagementGestureKeepsItsServiceIdentityAfterRefresh() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        func service(_ name: String) -> JSONValue { .object(["name": .string(name), "status": .string("started"), "user_owned": .bool(true)]) }
        func deliver(_ names: [String], state: JSONValue = .null, sequence: Int) throws -> PluginScriptAnswer {
            try helper.run(PluginTestInvocation("brew.services", event: .sourceDelivered(page: "homebrew-manage-services", source: "manage", sequence: sequence, result: .object(["services": .array(names.map(service))]), failure: nil), state: state), of: plugin, answering: services()).answer()
        }
        let first = try deliver(["redis", "postgresql"], sequence: 1)
        let shown = try XCTUnwrap(first.page?.collection?.items.first)
        let snapshot = PluginPageItemSnapshot(id: shown.id, section: nil, text: shown.text ?? shown.title)
        let reordered = try deliver(["postgresql", "redis"], state: first.state, sequence: 2)
        XCTAssertEqual(reordered.page?.collection?.items.last?.id, shown.id)
        let selected = try helper.run(PluginTestInvocation("brew.services", event: .itemAction(page: "homebrew-manage-services", collection: "management", action: "manage-details", item: snapshot, values: .null), state: reordered.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.state.value(atPointer: "/manageDetail/name"), .string("redis"))
        let removed = try deliver(["postgresql"], state: reordered.state, sequence: 3)
        let refused = try helper.run(PluginTestInvocation("brew.services", event: .itemAction(page: "homebrew-manage-services", collection: "management", action: "manage-details", item: snapshot, values: .null), state: removed.state), of: plugin, answering: services()).answer()
        XCTAssertNil(refused.state.value(atPointer: "/manageDetail/name"))
    }
}


extension HomebrewTests {
    func testSameNamedAppCopiesRemainSeparateAdoptionTargets() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let apps: [JSONValue] = ["one", "two"].map { .object(["identity": .string("app_identity_" + $0), "target": .string("app_target_" + $0), "name": .string("Example"), "bundle_id": .string("org.example.app"), "version": .string("2")]) }
        let delivered = try helper.run(PluginTestInvocation("brew.adopt", event: .sourceDelivered(page: "homebrew-manage-adopt", source: "manage", sequence: 1, result: .object(["applications": .array(apps)]), failure: nil)), of: plugin, answering: services()).answer()
        let items = try XCTUnwrap(delivered.page?.collection?.items)
        XCTAssertEqual(items.count, 2); XCTAssertNotEqual(items[0].id, items[1].id)
        let selected = try helper.run(PluginTestInvocation("brew.adopt", event: .itemAction(page: "homebrew-manage-adopt", collection: "management", action: "manage-details", item: PluginPageItemSnapshot(id: items[1].id, section: nil, text: items[1].text ?? items[1].title), values: .null), state: delivered.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(selected.state.value(atPointer: "/manageDetail/target"), .string("app_target_two"))
    }
}


extension HomebrewTests {
    func testSecurityOverviewShowsFindingsAndTwentySkippedPackagesAcrossAutomaticBatches() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let skipped = (0..<20).map { JSONValue.object(["name": .string(String(format: "a-skipped%02d", $0)), "reason": .string("Unsupported installed source")]) }
        let inventory = try securityInventory((0..<20).map { String(format: "a-skipped%02d", $0) } + ["example"], helper: helper, plugin: plugin)
        let chosen = try securityAction("select-security", from: inventory, helper: helper, plugin: plugin)
        let started = try securityAction("start-security", from: chosen, helper: helper, plugin: plugin)
        let next = try securityReport(.object(["checked": .number(0), "skipped": .array(skipped), "findings": .array([])]), into: started, helper: helper, plugin: plugin)
        let finding: JSONValue = .object(["name": .string("example"), "advisories": .array([.object(["id": .string("CVE-2026-1"), "status": .string("unknown")])])])
        let answer = try securityReport(.object(["checked": .number(1), "findings": .array([finding]), "skipped": .array([])]), into: next, helper: helper, plugin: plugin)
        XCTAssertEqual(answer.page?.collection?.items.first?.title, "example")
        XCTAssertEqual(answer.page?.collection?.total, 21)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(answer.pageJSON), as: UTF8.self).contains("a-skipped19"))
    }

}


extension HomebrewTests {
    func testFailedAdoptionPreviewCannotOfferOrRequestAdoptionAndChangingCaskClearsOldTarget() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["mode": .string("adopt"), "manageDetail": .object(["name": .string("Firefox"), "target": .string("app_123"), "version": .string("1")]), "caskName": .string("firefox"), "adoptionRequest": .object(["tool": .string("homebrew"), "operation": .string("adoptionPreview"), "target": .string("app_123"), "name": .string("firefox")])])
        let failed = try helper.run(PluginTestInvocation("brew.adopt", event: .sourceDelivered(page: "homebrew-manage-adopt", source: "adoption", sequence: 1, result: .object(["succeeded": .bool(false), "summary": .string("App cannot be adopted"), "stderr": .string("Version mismatch")]), failure: nil), state: state), of: plugin, answering: services()).answer()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(failed.pageJSON), as: UTF8.self).contains("Adopt This App"))
        let refused = try helper.run(PluginTestInvocation("brew.adopt", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "adopt", values: .null, selection: .null), state: failed.state), of: plugin, answering: services()).answer()
        XCTAssertNil(refused.operation)
        let reviewed = try helper.run(PluginTestInvocation("brew.adopt", event: .sourceDelivered(page: "homebrew-manage-adopt", source: "adoption", sequence: 2, result: .object(["succeeded": .bool(true), "summary": .string("Adopt Firefox"), "target": .string("adoption_123")]), failure: nil), state: state), of: plugin, answering: services()).answer()
        let adopted = try helper.run(PluginTestInvocation("brew.adopt", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "adopt", values: .null, selection: .null), state: reviewed.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(adopted.operation?.input.value(atPointer: "/target"), .string("adoption_123"))
        let changed = try helper.run(PluginTestInvocation("brew.adopt", event: .pageActionChosen(page: "homebrew-manage-adopt", action: "adopt", values: .object(["caskName": .string("firefox-esr")]), selection: .null), state: reviewed.state), of: plugin, answering: services()).answer()
        XCTAssertNil(changed.operation)
        XCTAssertNil(changed.state.value(atPointer: "/adoption/target"))
    }
}


extension HomebrewTests {
    func testCatalogUpdateFinishingOnPreviewPageClosesStalePreviewAndReloadsMetadata() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1")]),
            "detailLoaded": .bool(true), "catalogUpdateWaiting": .bool(true), "catalogUpdateBaseline": .array([]),
            "previewPage": .bool(true), "previewInput": .object(["tool": .string("homebrew"), "operation": .string("previewUpgrade"), "kind": .string("formula"), "names": .array([.string("wget")])])])
        let task: JSONValue = .object(["id": .string("activity_01234567890123456789012345678901"), "kind": .string("task"), "name": .string("Update Homebrew"), "operation": .string("update"), "status": .string("ended"), "stage": .string("completed"), "result": .object(["outcome": .string("completed")])])
        let fresh = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-preview", source: "activities", sequence: 1, result: .array([task]), failure: nil), state: state), of: plugin, answering: services()).answer()
        XCTAssertTrue(fresh.page?.id.hasPrefix("homebrew-detail-") == true)
        XCTAssertEqual(fresh.state.value(atPointer: "/previewPage"), .bool(false))
        XCTAssertNil(fresh.state.value(atPointer: "/detail/version"))
        XCTAssertTrue(fresh.page?.sources.contains { $0.input.value(atPointer: "/operation") == .string("version") } == true)
        XCTAssertNil(fresh.operation)
    }

    func testCheckForUpdatesRequestsGlobalHostTaskAndReloadsMetadataOnlyAfterTaskEnds() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1")]), "detailLoaded": .bool(true)])
        let requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "check-updates", values: .null, selection: .null), state: state), of: plugin, answering: services(operations: ["activities.list": .value(.array([]))])).answer()
        XCTAssertEqual(requested.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("update")]))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(requested.pageJSON), as: UTF8.self).contains("all taps"))
        let started = try helper.run(PluginTestInvocation("brew.open", event: .operationFinished(id: "catalog-update", perform: "tools.startTask", outcome: .succeeded), state: requested.state), of: plugin, answering: services()).answer()
        XCTAssertEqual(started.page?.id, "homebrew-progress")
        let task: JSONValue = .object(["id": .string("activity_01234567890123456789012345678901"), "kind": .string("task"), "name": .string("Update Homebrew"), "operation": .string("update"), "status": .string("ended"), "stage": .string("completed"), "result": .object(["outcome": .string("completed")])])
        let ended = try helper.run(PluginTestInvocation("brew.open", event: .sourceDelivered(page: "homebrew-progress", source: "activities", sequence: 1, result: .array([task]), failure: nil), state: started.state), of: plugin, answering: services()).answer()
        XCTAssertNil(ended.operation)
        let back = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-progress", action: "browse", values: .null, selection: .null), state: ended.state), of: plugin, answering: services()).answer()
        XCTAssertTrue(back.page?.id.hasPrefix("homebrew-detail-") == true)
        XCTAssertEqual(back.page?.sources.first?.id, "detail-1")
        XCTAssertTrue(back.page?.sources.contains { $0.input.value(atPointer: "/operation") == .string("version") } == true)
        XCTAssertNil(back.state.value(atPointer: "/detail/version"))
        XCTAssertNil(back.operation)
    }
}


extension HomebrewTests {
    func testPackageLinksUseHostVerifiedOfficialSourceAndExposeHomepageCopy() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        func detail(official: Bool?) throws -> PluginScriptAnswer {
            var fields: [String: JSONValue] = ["name": .string("wget"), "kind": .string("formula"), "tap": .string("homebrew/core"), "homepage": .string("https://www.gnu.org/software/wget/")]
            if let official { fields["official"] = .bool(official) }
            return try helper.run(PluginTestInvocation("brew.open", state: .object(["detail": .object(fields), "detailLoaded": .bool(true), "packageOptions": .bool(true)])), of: plugin, answering: services()).answer()
        }
        let verified = try detail(official: true)
        let text = String(decoding: try JSONEncoder().encode(verified.pageJSON), as: UTF8.self)
        XCTAssertTrue(text.contains("Open Homebrew Package Page"))
        XCTAssertTrue(text.contains("Copy Homebrew Package URL"))
        XCTAssertTrue(text.contains("Copy Homepage URL"))
        for official in [Optional<Bool>.none, .some(false)] {
            let unknown = String(decoding: try JSONEncoder().encode(detail(official: official).pageJSON), as: UTF8.self)
            XCTAssertFalse(unknown.contains("formulae.brew.sh"))
        }
    }
}


extension HomebrewTests {
    func testUpdateOutcomeAfterViewClosesStaysViewlessAndReopeningObservesThePendingTask() throws {
        let plugin = try plugin(), helper = try PluginTestHelper(); defer { helper.shutdown() }
        let state: JSONValue = .object(["detail": .object(["kind": .string("formula"), "name": .string("wget")]), "detailLoaded": .bool(true)])
        let requested = try helper.run(PluginTestInvocation("brew.open", event: .pageActionChosen(page: "homebrew-detail", action: "check-updates", values: .null, selection: .null), state: state), of: plugin, answering: services(operations: ["activities.list": .value(.array([]))])).answer()
        let closed = try helper.run(PluginTestInvocation("brew.open", event: .operationFinished(id: "catalog-update", perform: "tools.startTask", outcome: .succeeded, viewClosed: true), state: requested.state), of: plugin, answering: services()).answer()
        XCTAssertNil(closed.page)
        XCTAssertNil(closed.operation)
        let reopened = try helper.run(PluginTestInvocation("brew.open"), of: plugin, answering: services()).answer()
        XCTAssertTrue(reopened.page?.sources.contains { $0.perform == "activities.list" } == true)
        XCTAssertNil(reopened.operation)
    }
}


extension HomebrewTests {
    func testNormalInstallationKeepsAllReadAndMutationGrantsUndecidedAndRunsTheInstalledCopy() throws {
        let source = try plugin()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let installer = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: {})
        let review = try installer.review(source.package.rootURL)
        XCTAssertTrue(review.requestedAccess.contains(.readReviewedTools))
        XCTAssertTrue(review.requestedAccess.contains(.runReviewedToolTasks))
        let manifest = try installer.install(from: source.package.rootURL)
        let installed = try XCTUnwrap(registry.package(for: manifest.id))
        XCTAssertEqual(installed.origin, .installed)
        XCTAssertEqual(manifest.apiLevel, 3)
        XCTAssertTrue(manifest.candidateContracts.isEmpty)
        XCTAssertEqual(manifest.commands.count, 14)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: source.package.rootURL.path)
        XCTAssertEqual(filenames.count, 17)
        for filename in filenames {
            XCTAssertEqual(try Data(contentsOf: source.package.rootURL.appendingPathComponent(filename)),
                try Data(contentsOf: installed.rootURL.appendingPathComponent(filename)))
        }
        for capability in manifest.capabilities {
            XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: capability,
                scope: manifest.scope(for: capability)), .notDetermined)
        }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let installedPlugin = try PluginUnderTest(packageAt: installed.rootURL)
        let answer = try helper.run(PluginTestInvocation("brew.open"), of: installedPlugin,
            answering: services(operations: ["activities.list": .value(.array([]))])).answer()
        XCTAssertEqual(answer.page?.id, "homebrew-home")
        XCTAssertNil(answer.operation)
    }
}
