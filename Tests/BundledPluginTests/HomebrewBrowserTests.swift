// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewTests: XCTestCase {
    private var helper: PluginTestHelper!
    private var storage: PluginStorage!
    private var directory: URL!
    override func setUpWithError() throws {
        helper = try PluginTestHelper()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("brew-browser-" + UUID().uuidString)
        storage = PluginStorage(directory: directory)
    }
    override func tearDownWithError() throws {
        helper?.shutdown()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func plugin() throws -> PluginUnderTest { try PluginUnderTest(named: "Homebrew.spinnetplugin", origin: .bundled) }
    private func render(_ command: String = "brew.installed", input: JSONValue = .null, event: PluginViewEvent? = nil,
                     state: JSONValue = .null, activities: [JSONValue] = []) throws -> PluginScriptAnswer {
        let services = RecordedHostServices(operations: ["activities.list": .value(.array(activities))], storage: storage)
        let result = helper.run(.init(command, input: input, event: event, state: state), of: try plugin(), answering: services)
        XCTAssertTrue(result.requests.allSatisfy { ["storage.get", "storage.set", "activities.list"].contains($0.operation ?? "") },
                      "Reads must be visible Sources; mutations require a returned Host operation")
        return try result.answer()
    }
    private func press(_ answer: PluginScriptAnswer, _ action: String, activities: [JSONValue] = []) throws -> PluginScriptAnswer {
        try render(event: .pageActionChosen(page: try XCTUnwrap(answer.page?.id), action: action, values: .object([:]), selection: .null), state: answer.state, activities: activities)
    }
    private func field(_ answer: PluginScriptAnswer, _ name: String, _ value: String) throws -> PluginScriptAnswer {
        try finishCatalogRefresh(render(event: .pageFieldChanged(page: try XCTUnwrap(answer.page?.id), field: name, values: .object([name: .string(value)])), state: answer.state))
    }
    private func source(_ answer: PluginScriptAnswer) throws -> PluginPageSource {
        try XCTUnwrap(answer.page?.sources.first(where: { $0.perform == "tools.read" }))
    }
    private func deliver(_ answer: PluginScriptAnswer, _ result: JSONValue) throws -> PluginScriptAnswer {
        let pending = try source(answer)
        return try render(event: .sourceDelivered(page: try XCTUnwrap(answer.page?.id), source: pending.id, sequence: 1, result: result, failure: nil), state: answer.state)
    }
    private func data(_ operation: String, _ packages: [JSONValue]) -> JSONValue {
        .object(["tool": .string("homebrew"), "operation": .string(operation), "packages": .array(packages)])
    }
    private func package(_ name: String, _ kind: String = "formula", _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["kind": .string(kind), "name": .string(name)].merging(extra) { _, new in new })
    }
    private func loaded(_ command: String = "brew.installed", packages: [JSONValue]) throws -> PluginScriptAnswer {
        let opened = try open(command)
        guard case .string(let operation)? = try source(opened).input.value(atPointer: "/operation") else { throw NSError(domain: "missing-operation", code: 1) }
        return try deliver(opened, data(operation, packages))
    }
    private func row(_ answer: PluginScriptAnswer, named title: String, action: String = "activate", activities: [JSONValue] = []) throws -> PluginScriptAnswer {
        let list = try XCTUnwrap(answer.page?.collection), item = try XCTUnwrap(list.items.first(where: { $0.title == title }))
        return try render(event: .itemAction(page: try XCTUnwrap(answer.page?.id), collection: list.id, action: action,
            item: .init(id: item.id, section: list.section(of: item.id), text: item.title), values: .object([:])), state: answer.state, activities: activities)
    }
    private func text(_ answer: PluginScriptAnswer, _ id: String) throws -> String {
        guard case .text(let value)? = answer.page?.component(id) else { throw NSError(domain: "missing " + id, code: 1) }
        return value.text
    }

    private func open(_ command: String = "brew.installed", input: JSONValue = .null) throws -> PluginScriptAnswer {
        try finishCatalogRefresh(render(command, input: input))
    }
    private func finishCatalogRefresh(_ answer: PluginScriptAnswer) throws -> PluginScriptAnswer {
        guard answer.operation?.input.value(atPointer: "/operation") == .string("refreshCatalog") else { return answer }
        return try completeCatalog(answer, outcome: "completed")
    }
    private func completeCatalog(_ answer: PluginScriptAnswer, outcome: String) throws -> PluginScriptAnswer {
        let admitted = try render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .succeeded), state: answer.state)
        let task: JSONValue = .object(["id": .string("catalog-" + UUID().uuidString), "kind": .string("task"), "tool": .string("homebrew"),
            "status": .string("ended"), "output": .string("Catalog fixture output"), "result": .object(["outcome": .string(outcome)])])
        return try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([task]), failure: nil), state: admitted.state)
    }

    func testNineEntrypointsRefreshCatalogBeforeRelatedReads() throws {
        let manifest = try plugin().manifest
        XCTAssertEqual(manifest.version, "2.5.6"); XCTAssertEqual(manifest.hostCompatibility.rawValue, "^1.0.0")
        XCTAssertEqual(manifest.commands.count, 9)
        XCTAssertNil(manifest.scope(for: .controlExternalApp))
        for command in manifest.commands {
            let answer = try render(command.id.rawValue)
            if ["brew.outdated","brew.adopt","brew.taps"].contains(command.id.rawValue) {
                XCTAssertEqual(answer.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("refreshCatalog")]))
                XCTAssertFalse(answer.page?.sources.contains { $0.perform == "tools.read" } == true)
                let completed = try finishCatalogRefresh(answer)
                XCTAssertNil(completed.operation); XCTAssertEqual(try source(completed).perform, "tools.read")
                continue
            }
            XCTAssertNil(answer.operation)
            if command.id.rawValue == "brew.update" {
                XCTAssertTrue(answer.page?.sources.isEmpty == true)
            } else {
                XCTAssertEqual(try source(answer).perform, "tools.read")
            }
        }
        for retired in ["brew.upgrade", "brew.open", "brew.vulnerabilities", "brew.services-menu", "brew.clear-cache", "brew.autoremove", "brew.install", "brew.uninstall", "brew.info", "brew.config", "brew.version", "brew.untap"] {
            let target = try XCTUnwrap(manifest.migrations.renamedCommands[CommandID(retired)])
            XCTAssertTrue(manifest.commands.contains { $0.id == target })
        }
    }
    func testCleanupChecksUnusedDependenciesBeforeOfferingRemoval() throws {
        let opened = try open("brew.cleanup")
        XCTAssertEqual(try source(opened).input.value(atPointer: "/operation"), .string("previewAutoremove"))
        let request = try HomebrewReadInput(source(opened).input)
        let scope = try XCTUnwrap(plugin().manifest.scope(for: .readReviewedTools))
        XCTAssertNoThrow(try request.authorize(in: scope))
        XCTAssertNil(opened.operation)
        XCTAssertNil(try press(opened, "autoremove").operation)
        for count in [0, 2] {
            let preview: JSONValue = .object(["available": .bool(true), "succeeded": .bool(true), "complete": .bool(true),
                "no_op": .bool(count == 0), "packages": .array((0..<count).map { package("unused-\($0)") })])
            let ready = try deliver(opened, preview)
            XCTAssertNil(ready.operation, "Read completion must never queue a mutation")
            if count == 0 {
                XCTAssertEqual(try text(ready, "cleanup-status"), "No unused dependencies to remove.")
                XCTAssertNil(ready.page?.component("autoremove-actions"))
                XCTAssertNil(try press(ready, "autoremove").operation)
            } else {
                XCTAssertNotNil(ready.page?.component("autoremove-actions"))
                XCTAssertEqual(try press(ready, "autoremove").operation?.input.value(atPointer: "/operation"), .string("autoremove"))
                let refreshing = try press(ready, "refresh")
                XCTAssertNil(refreshing.page?.component("autoremove-actions"))
                XCTAssertNil(try press(refreshing, "autoremove").operation)
            }
        }
        let failed = try deliver(opened, .object(["available": .bool(true), "succeeded": .bool(false), "complete": .bool(false), "packages": .array([])]))
        XCTAssertNotEqual(try text(failed, "cleanup-status"), "No unused dependencies to remove.")
        XCTAssertNil(failed.page?.component("autoremove-actions"))
        XCTAssertNil(try press(failed, "autoremove").operation)
    }

    func testInstalledInventoryGroupsPinsAndDependenciesWithStableKindQualifiedIdentity() throws {
        let result = try loaded(packages: [
            package("same", "formula", ["installed_version": .string("1"), "pinned": .bool(true)]),
            package("same", "cask", ["installed_version": .string("2")]),
            package("lib", "formula", ["installed_as_dependency": .bool(true)]),
            package("user/tap/tool", "formula", ["installed_on_request": .bool(true)])
        ])
        let list = try XCTUnwrap(result.page?.collection)
        XCTAssertEqual(list.total, 4); XCTAssertEqual(Set(list.items.map(\.id)).count, 4)
        XCTAssertEqual(Set(list.sections.compactMap(\.title)), ["Pinned Formulae", "Cask Apps", "Dependencies", "Formulae"])
        let filtered = try field(result, "query-list", "user/tap")
        XCTAssertEqual(filtered.page?.collection?.total, 1)
        XCTAssertNil(filtered.operation); XCTAssertTrue(filtered.page?.sources.isEmpty == true)
    }
    func testCurrentInstalledPrimaryOpensDetailsAndBackPreservesFilter() throws {
        let listed = try loaded(packages: [package("wget", "formula", ["installed_version": .string("1")])])
        let filtered = try field(listed, "query-list", "wget")
        let detail = try row(filtered, named: "wget")
        XCTAssertEqual(detail.page?.id, "homebrew-details"); XCTAssertNil(detail.operation)
        XCTAssertEqual(try source(detail).input.value(atPointer: "/names"), .array([.string("wget")]))
        let ready = try deliver(detail, data("info", [package("wget", "formula", ["installed_version": .string("1"), "version": .string("1"), "description": .string("A **literal** description")])]))
        XCTAssertNotNil(ready.page?.component("package-actions"))
        XCTAssertTrue(try text(ready, "package-description").contains("\\*\\*literal\\*\\*"))
        let back = try press(ready, "back")
        XCTAssertEqual(back.page?.id, "homebrew-list"); XCTAssertEqual(back.state.value(atPointer: "/query"), .string("wget"))
        XCTAssertNil(back.operation); XCTAssertTrue(back.page?.sources.isEmpty == true)
    }
    func testSearchOnTypingMergesInstalledStateAndUninstalledPrimaryStartsConfirmedInstall() throws {
        let opened = try open("brew.search")
        let inventory = try deliver(opened, data("installed", [package("old", "formula", ["installed_version": .string("1"), "outdated": .bool(true)])]))
        let search = try field(inventory, "query-search", "fire")
        XCTAssertEqual(try source(search).input.value(atPointer: "/query"), .string("fire"))
        let found = try deliver(search, data("search", [package("firefox", "cask"), package("old")]))
        XCTAssertEqual(found.page?.collection?.items.first?.accessory, "Install")
        let install = try row(found, named: "firefox")
        XCTAssertEqual(install.operation?.perform, "tools.startTask")
        XCTAssertEqual(install.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("firefox")]))
        XCTAssertEqual(install.page?.id, "homebrew-task")
        let upgrade = try row(found, named: "old")
        XCTAssertEqual(upgrade.operation?.input.value(atPointer: "/operation"), .string("upgrade"))
    }
    func testSearchCancellationRejectsLateQueryResultsAndNeverUsesFlagsOrShellText() throws {
        let opened = try open("brew.search")
        let inventory = try deliver(opened, data("installed", []))
        let old = try field(inventory, "query-search", "fire")
        let oldSource = try source(old)
        let newest = try field(old, "query-search", "chrome")
        let late = try render(event: .sourceDelivered(page: "homebrew-search", source: oldSource.id, sequence: 1, result: data("search", [package("firefox", "cask")]), failure: nil), state: newest.state)
        XCTAssertEqual(try source(late).input.value(atPointer: "/query"), .string("chrome"))
        XCTAssertEqual(late.page?.collection?.total, 0)
        for invalid in ["--force", "$(touch /tmp/no)", "foo bar", String(repeating: "a", count: 65)] {
            let answer = try field(late, "query-search", invalid)
            XCTAssertNil(answer.operation); XCTAssertTrue(answer.page?.sources.isEmpty == true)
            XCTAssertNotNil(answer.page?.component("error"))
        }
    }
    func testOutdatedPrimaryUpgradesAndPinsAreExcludedFromSelection() throws {
        let listed = try loaded("brew.outdated", packages: [package("wget", "formula", ["installed_version": .string("1"), "version": .string("2")]), package("firefox", "cask", ["pinned": .bool(true)])])
        let list = try XCTUnwrap(listed.page?.collection)
        XCTAssertTrue(list.items.first(where: { $0.title == "wget" })?.marks.contains("included") == true)
        XCTAssertTrue(list.items.first(where: { $0.title == "firefox" })?.marks.isEmpty == true)
        XCTAssertFalse(list.items.first(where: { $0.title == "firefox" })?.actions?.contains("include") == true)
        let upgrade = try row(listed, named: "wget")
        XCTAssertEqual(upgrade.operation?.input.value(atPointer: "/operation"), .string("upgrade"))
        let pinned = try row(listed, named: "firefox")
        XCTAssertEqual(pinned.operation?.input.value(atPointer: "/operation"), .string("unpin"))
    }
    func testSelectiveUpgradesKeepKindsSeparateAndDoNotIncludeDeselectedOrPinnedPackages() throws {
        let listed = try loaded("brew.outdated", packages: [package("one"), package("two"), package("pinned", "formula", ["pinned": .bool(true)]), package("one", "cask")])
        let narrowed = try row(listed, named: "two", action: "include")
        let formulae = try press(narrowed, "upgrade-formula")
        XCTAssertEqual(formulae.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string("formula"), "names": .array([.string("one")])]))
        let casks = try press(narrowed, "upgrade-cask")
        XCTAssertEqual(casks.operation?.input.value(atPointer: "/kind"), .string("cask"))
        XCTAssertEqual(casks.operation?.input.value(atPointer: "/names"), .array([.string("one")]))
        let none = try press(narrowed, "select-none")
        XCTAssertNil(try press(none, "upgrade-formula").operation)
    }
    func testRetiredGlobalUpgradeCannotStartFromNavigationOrStaleActions() throws {
        let manifest = try plugin().manifest
        XCTAssertFalse(manifest.commands.contains { $0.id.rawValue == "brew.upgrade" })
        XCTAssertEqual(manifest.migrations.renamedCommands[CommandID("brew.upgrade")], CommandID("brew.outdated"))
        XCTAssertFalse(manifest.scope(for: .runReviewedToolTasks)?.reviewedTools.first?.operations.contains("upgradeAll") == true)
        let listed = try loaded("brew.outdated", packages: [package("wget")])
        XCTAssertNil(listed.page?.component("upgrade-all-controls"))
        guard case .choiceField(let section)? = listed.page?.component("section") else { return XCTFail("Missing navigation") }
        XCTAssertFalse(section.choices.contains { $0.value == "upgrade" })
        XCTAssertFalse(section.choices.contains { $0.title == "Upgrade All" })
        XCTAssertNil(try press(listed, "upgrade-all").operation)
        guard case .object(var legacy) = listed.state else { return XCTFail("Missing browser state") }
        legacy["screen"] = .string("upgrade"); legacy["section"] = .string("upgrade")
        let restored = try render(event: .sourceDelivered(page: "homebrew-upgrade", source: "retired", sequence: 1, result: .null, failure: nil), state: .object(legacy))
        XCTAssertEqual(restored.page?.id, "homebrew-outdated")
        XCTAssertNil(restored.page?.component("upgrade-all-controls"))
        XCTAssertNil(restored.operation)
    }
    func testSilentCleanupCompletionDoesNotKeepWaitingForOutput() throws {
        let opened = try open("brew.cleanup")
        let run = try press(opened, "cleanup")
        let admitted = try render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .succeeded), state: run.state)
        let task: JSONValue = .object(["id": .string("silent-cleanup"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string(""), "log": .array([]), "result": .object(["outcome": .string("completed")])])
        let finished = try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([task]), failure: nil), state: admitted.state)
        XCTAssertEqual(try text(finished, "task-status"), "completed")
        XCTAssertEqual(try text(finished, "task-output"), "Completed with no output.")
        XCTAssertNil(finished.operation, "Rendering a silent completion must not retry cleanup")
    }
    func testEmptyTaskTranscriptFollowsTheLifecycleAndPreservesNativeOutput() throws {
        let opened = try open("brew.cleanup")
        let run = try press(opened, "cleanup")
        XCTAssertEqual(try text(run, "task-output"), "Waiting for output…")
        let admitted = try render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .succeeded), state: run.state)
        let running: JSONValue = .object(["id": .string("quiet-task"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("running"), "output": .string("")])
        let live = try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([running]), failure: nil), state: admitted.state)
        XCTAssertEqual(try text(live, "task-output"), "Waiting for output…")
        for outcome in ["failed", "stopped", "refused", "unknown"] {
            let ended: JSONValue = .object(["id": .string("quiet-task"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string(""), "result": .object(["outcome": .string(outcome)])])
            let finished = try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 2, result: .array([ended]), failure: nil), state: live.state)
            XCTAssertEqual(try text(finished, "task-output"), "No output was produced.", outcome)
            XCTAssertNil(finished.operation)
        }
        let raw = "==> Removing cached download\n  12.3MB reclaimed"
        let ended: JSONValue = .object(["id": .string("quiet-task"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string(raw), "result": .object(["outcome": .string("completed")])])
        let finished = try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 2, result: .array([ended]), failure: nil), state: live.state)
        XCTAssertEqual(try text(finished, "task-output"), raw)
        XCTAssertNil(finished.operation)
    }
    func testTaskStreamsOnlyItsOwnLiteralOutputAndCompletionRefreshesWithoutReplay() throws {
        let listed = try loaded("brew.outdated", packages: [package("wget")])
        let old: JSONValue = .object(["id": .string("old"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended")])
        let run = try row(listed, named: "wget", activities: [old])
        let admitted = try self.render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .succeeded), state: run.state)
        let raw = "==> Downloading\n[#####     ] 50%\n**literal** [url](https://example.com)"
        let task: JSONValue = .object(["id": .string("activity_0123456789abcdef0123456789abcdef"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("running"), "output": .string(raw)])
        let streaming = try self.render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([old,task]), failure: nil), state: admitted.state)
        XCTAssertEqual(try text(streaming,"task-output"), raw)
        let stop = try press(streaming, "stop")
        XCTAssertEqual(stop.operation?.perform, "activities.stop")
        let ended: JSONValue = .object(["id": .string("activity_0123456789abcdef0123456789abcdef"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "output": .string(raw + "\nDone"), "result": .object(["outcome": .string("completed"), "exit_status": .number(0)])])
        let finished = try self.render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 2, result: .array([ended]), failure: nil), state: streaming.state)
        XCTAssertNil(finished.operation)
        XCTAssertEqual(try source(finished).input.value(atPointer: "/operation"), .string("outdated"))
        XCTAssertFalse(finished.page?.sources.contains(where: { $0.perform == "activities.list" }) == true)
        XCTAssertTrue(try text(finished,"task-output").hasSuffix("Done"))
    }
    func testDeclinedTaskDoesNotAttachToUnrelatedTaskOrRetry() throws {
        let opened = try open("brew.update")
        let run = try press(opened, "update-catalog")
        let declined = try self.render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .declined), state: run.state)
        XCTAssertNil(declined.operation); XCTAssertTrue(declined.page?.sources.isEmpty == true)
        let unrelated: JSONValue = .object(["id": .string("other"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("running"), "output": .string("unrelated")])
        let late = try self.render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([unrelated]), failure: nil), state: declined.state)
        XCTAssertFalse(try text(late,"task-output").contains("unrelated")); XCTAssertNil(late.operation)
    }
    func testServicesPrimaryUsesStatusAndRefreshesThroughTypedUserOwnedOperations() throws {
        let opened = try open("brew.services")
        let result: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("services"), "services": .array([
            .object(["name": .string("redis"), "status": .string("started"), "user_owned": .bool(true)]),
            .object(["name": .string("postgresql"), "status": .string("none"), "user_owned": .bool(true)])])])
        let listed = try deliver(opened,result)
        XCTAssertEqual(Set(listed.page?.collection?.sections.compactMap(\.title) ?? []), ["Running", "Stopped"])
        XCTAssertEqual(try row(listed,named:"redis").operation?.input.value(atPointer:"/operation"), .string("serviceStop"))
        XCTAssertEqual(try row(listed,named:"postgresql").operation?.input.value(atPointer:"/operation"), .string("serviceStart"))
        XCTAssertEqual(try row(listed,named:"redis",action:"restart").operation?.input.value(atPointer:"/operation"), .string("serviceRestart"))
    }
    func testTapsExposeContainerActionsWithoutInferringSourceTrust() throws {
        let opened = try open("brew.taps")
        let listed = try deliver(opened,.object(["operation": .string("taps"), "taps": .array([
            .object(["name": .string("user/repo"), "official": .bool(false), "trusted": .bool(false), "formula_count": .number(2), "cask_count": .number(1)])])]))
        let browse = try row(listed,named:"user/repo")
        XCTAssertNil(browse.operation); XCTAssertEqual(try source(browse).input.value(atPointer:"/tap"), .string("user/repo"))
        let trust = try row(listed,named:"user/repo",action:"trust")
        XCTAssertEqual(trust.operation?.input.value(atPointer:"/operation"), .string("trust"))
        let remove = try row(listed,named:"user/repo",action:"remove")
        XCTAssertEqual(remove.operation?.input.value(atPointer:"/operation"), .string("untap"))
        let filled = try field(listed,"tap-name","new/repo")
        XCTAssertEqual(try press(filled,"add-tap").operation?.input.value(atPointer:"/tap"), .string("new/repo"))
    }
    func testAdoptionUsesAppCandidateThenPreviewTargetAndASeparateConfirmGesture() throws {
        let opened = try open("brew.adopt")
        let app: JSONValue = .object(["identity": .string("app-copy"), "target": .string("app_candidate"), "name": .string("Firefox"), "version": .string("1"), "candidates": .array([.object(["name": .string("firefox"), "confidence": .string("likely"), "reason": .string("Name and version match")])])])
        let listed = try deliver(opened,.object(["operation": .string("adoptionCandidates"), "applications": .array([app])]))
        let preview = try row(listed,named:"Firefox")
        XCTAssertNil(preview.operation); XCTAssertEqual(try source(preview).input.value(atPointer:"/target"), .string("app_candidate"))
        let ready = try deliver(preview,.object(["succeeded": .bool(true), "target": .string("adoption_reviewed"), "name": .string("firefox"), "stdout": .string("Native preview")]))
        XCTAssertNil(ready.operation)
        let adopted = try press(ready,"confirm-preview")
        XCTAssertEqual(adopted.operation?.input, .object(["tool": .string("homebrew"), "operation": .string("adopt"), "target": .string("adoption_reviewed")]))
    }
    func testFailedNewPreviewCannotReuseAnotherPackagesOldReviewTarget() throws {
        let listed = try loaded("brew.outdated",packages:[package("one"),package("two")])
        let first = try row(listed,named:"one",action:"preview")
        let ready = try deliver(first,.object(["succeeded": .bool(true), "stdout": .string("First preview")]))
        let back = try press(ready,"back")
        let next = try row(back,named:"two",action:"preview")
        let pending = try source(next)
        let failed = try render(event:.sourceDelivered(page:"homebrew-preview",source:pending.id,sequence:1,result:.null,failure:.init(category:.toolFailed,message:"Preview failed")),state:next.state)
        XCTAssertNil(failed.page?.component("preview-actions"))
        XCTAssertNil(try press(failed,"confirm-preview").operation)
    }
    func testLargeInventoryUsesStorageAndWindowingInsteadOfOverflowingViewState() throws {
        let packages = (0..<1000).map { package("package-\($0)","formula",["description":.string(String(repeating:"description ",count:10)),"installed_version":.string("1")]) }
        let listed = try loaded(packages:packages)
        let list = try XCTUnwrap(listed.page?.collection)
        XCTAssertEqual(list.total,1000); XCTAssertEqual(list.items.count,80)
        XCTAssertLessThan(try JSONEncoder().encode(listed.state).count,8192)
        let window = try render(event:.loadRange(page:"homebrew-list",collection:list.id,start:300,count:600),state:listed.state)
        XCTAssertEqual(window.page?.collection?.start,300); XCTAssertEqual(window.page?.collection?.items.count,600)
        XCTAssertNil(window.operation); XCTAssertTrue(window.page?.sources.isEmpty == true)
    }
    func testUnknownReadFailureIsNotAnEmptySuccessfulInventory() throws {
        let opened = try open()
        let pending = try source(opened)
        let failed = try render(event:.sourceDelivered(page:"homebrew-list",source:pending.id,sequence:1,result:.null,failure:.init(category:.toolFailed,message:"Catalog unavailable")),state:opened.state)
        XCTAssertEqual(try text(failed,"error"),"Catalog unavailable")
        XCTAssertTrue(failed.page?.collection?.emptyText.contains("unavailable") == true)
        XCTAssertNil(failed.operation)
    }
    func testLargeUnicodeTaskOutputStaysInsideStateBudgetAndDisclosesTail() throws {
        let opened = try open("brew.update")
        let started = try press(opened,"update-catalog")
        let admitted = try render(event:.operationFinished(id:"brew-task",perform:"tools.startTask",outcome:.succeeded),state:started.state)
        let task: JSONValue = .object(["id":.string("task"),"kind":.string("task"),"tool":.string("homebrew"),"status":.string("running"),"output":.string(String(repeating:"下载🙂\n",count:10000))])
        let stream = try render(event:.sourceDelivered(page:"homebrew-task",source:"brew-activities",sequence:1,result:.array([task]),failure:nil),state:admitted.state)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(stream.state).count,ScriptedActionBudgets.viewStateBytes)
        XCTAssertNotNil(stream.page?.component("output-limit"))
    }
    func testRawOutputRemainsLiteralAndBackRestoresTheObjectList() throws {
        let listed = try loaded(packages:[package("wget")])
        let raw = try press(listed,"raw-output")
        XCTAssertEqual(try source(raw).input.value(atPointer:"/command"),.string("list"))
        let native = "**literal** [not a link](https://example.com)\nWarning: native diagnostic"
        let ready = try deliver(raw,.object(["output":.string(native),"exit_status":.number(1)]))
        XCTAssertEqual(try text(ready,"raw-output"),native)
        XCTAssertEqual(try text(ready,"raw-status"),"Exit status 1")
        let back = try press(ready,"back")
        XCTAssertEqual(back.page?.collection?.items.first?.title,"wget")
        XCTAssertNil(back.operation)
    }
    func testSelectedPreviewKeepsTheExactKindAndNamesUntilAnotherConfirmGesture() throws {
        let listed = try loaded("brew.outdated",packages:[package("one"),package("two"),package("one","cask")])
        let narrowed = try row(listed,named:"two",action:"include")
        let preview = try press(narrowed,"preview-formula")
        XCTAssertNil(preview.operation)
        XCTAssertEqual(try source(preview).input.value(atPointer:"/names"),.array([.string("one")]))
        let ready = try deliver(preview,.object(["succeeded":.bool(true),"stdout":.string("Native planned change")]))
        XCTAssertNil(ready.operation)
        let started = try press(ready,"confirm-preview")
        XCTAssertEqual(started.operation?.input,.object(["tool":.string("homebrew"),"operation":.string("upgradeSelected"),"kind":.string("formula"),"names":.array([.string("one")])]))
    }
    func testAdoptionIgnoreAndRestorePersistAcrossViewSessions() throws {
        let application: JSONValue = .object(["identity":.string("copy-identity"),"target":.string("app_transient"),"name":.string("Example"),"candidates":.array([.object(["name":.string("example"),"confidence":.string("likely")])])])
        let result: JSONValue = .object(["applications":.array([application])])
        let listed = try deliver(open("brew.adopt"),result)
        let ignored = try row(listed,named:"Example",action:"ignore")
        XCTAssertEqual(ignored.page?.collection?.total,0); XCTAssertNil(ignored.operation)
        let reopened = try deliver(open("brew.adopt"),result)
        XCTAssertEqual(reopened.page?.collection?.total,0)
        let showIgnored = try field(reopened,"adoption-filter","ignored")
        XCTAssertEqual(showIgnored.page?.collection?.total,1)
        let restored = try row(showIgnored,named:"Example")
        XCTAssertNil(restored.operation)
        XCTAssertEqual(restored.page?.collection?.total,0)
        let available = try field(restored,"adoption-filter","available")
        XCTAssertEqual(available.page?.collection?.total,1)
    }
    func testTapPackageBrowsingUsesTheSameObjectActionsAndBackContext() throws {
        let opened = try open("brew.taps")
        let taps: JSONValue = .object(["taps":.array([.object(["name":.string("user/repo"),"official":.bool(false),"trusted":.bool(true),"formula_count":.number(1),"cask_count":.number(0)])])])
        let listed = try deliver(opened,taps)
        let browse = try row(listed,named:"user/repo")
        let withPackages = try deliver(browse,.object(["taps":.array([.object(["name":.string("user/repo"),"packages":.array([package("user/repo/tool")])])])]))
        let ready = try deliver(withPackages,data("installed",[]))
        XCTAssertEqual(ready.page?.collection?.items.first?.accessory,"Install")
        let detail = try row(ready,named:"user/repo/tool",action:"details")
        let rich = try deliver(detail,data("info",[package("user/repo/tool","formula",["version":.string("1")])]))
        let back = try press(rich,"back")
        XCTAssertEqual(back.page?.id,"homebrew-tap-details")
        XCTAssertEqual(back.page?.collection?.items.first?.title,"user/repo/tool")
        XCTAssertNil(back.operation)
    }
    func testPartialInventoryNeverAssumesAnUnmatchedSearchPackageIsUninstalled() throws {
        let opened = try open("brew.search")
        let inventory = try deliver(opened,.object(["operation":.string("installed"),"packages":.array([]),"truncated":.bool(true)]))
        let searching = try field(inventory,"query-search","fire")
        let found = try deliver(searching,data("search",[package("firefox","cask")]))
        let openedPackage = try row(found,named:"firefox")
        XCTAssertNil(openedPackage.operation)
        XCTAssertEqual(try source(openedPackage).input.value(atPointer:"/operation"),.string("info"))
    }
    func testNewCacheGenerationCannotSupplyDifferentRowsToAnOlderView() throws {
        let old = try loaded(packages:[package("old")])
        let staleID = try XCTUnwrap(old.page?.collection?.items.first?.id)
        _ = try loaded(packages:[package("new")])
        let stale = try render(event:.itemAction(page:"homebrew-list",collection:"objects-list",action:"uninstall",item:.init(id:staleID,section:nil,text:"old"),values:.object([:])),state:old.state)
        XCTAssertNil(stale.operation)
        XCTAssertEqual(stale.page?.collection?.total,0)
    }
    func testCurrentReadFlagsReplaceStalePinsAndDetailsReplaceStaleInstallationState() throws {
        let pinned = try loaded(packages:[package("wget","formula",["pinned":.bool(true),"installed_version":.string("1")])])
        let upgrades = try field(pinned,"section","outdated")
        let current = try deliver(upgrades,data("outdated",[package("wget","formula",["installed_version":.string("1"),"version":.string("2")])]))
        XCTAssertTrue(current.page?.collection?.items.first?.marks.contains("included") == true)
        let detail = try row(current,named:"wget",action:"details")
        let removedElsewhere = try deliver(detail,data("info",[package("wget","formula",["version":.string("2")])]))
        let reinstall = try press(removedElsewhere,"install")
        XCTAssertEqual(reinstall.operation?.input.value(atPointer:"/operation"),.string("install"))
    }
    func testExcludedUpgradePrimarySelectsBeforeAnotherGestureCanUpgrade() throws {
        for command in ["brew.outdated"] {
            let listed = try loaded(command, packages: [package("wget"), package("pinned", "formula", ["pinned": .bool(true)])])
            let excluded = try row(listed, named: "wget", action: "include")
            XCTAssertEqual(excluded.page?.collection?.items.first(where: { $0.title == "wget" })?.accessory, "Select")
            let selected = try row(excluded, named: "wget")
            XCTAssertNil(selected.operation)
            XCTAssertEqual(selected.page?.collection?.items.first(where: { $0.title == "wget" })?.marks, ["included"])
            XCTAssertEqual(try row(selected, named: "wget").operation?.input.value(atPointer: "/operation"), .string("upgrade"))
            XCTAssertEqual(listed.page?.collection?.items.first(where: { $0.title == "pinned" })?.accessory, "Unpin")
            XCTAssertEqual(try row(listed, named: "pinned").operation?.input.value(atPointer: "/operation"), .string("unpin"))
        }
    }
    func testReturningToSearchCannotPresentThePreviousQueryUnderAnEmptyField() throws {
        let inventory = try deliver(open("brew.search"), data("installed", []))
        let found = try deliver(field(inventory, "query-search", "fire"), data("search", [package("firefox", "cask")]))
        let installed = try field(found, "section", "list")
        let search = try field(installed, "section", "search")
        XCTAssertEqual(search.state.value(atPointer: "/query"), .string(""))
        XCTAssertEqual(search.page?.collection?.total, 0)
        let refreshed = try deliver(search, data("installed", []))
        XCTAssertTrue(refreshed.page?.sources.isEmpty == true)
        XCTAssertEqual(refreshed.page?.collection?.total, 0)
        XCTAssertNil(refreshed.operation)
    }
    func testReportSwitchCannotRelabelThePreviousOutputWhenTheNewReadFails() throws {
        let doctor = try deliver(open("brew.doctor"), .object(["output": .string("Old doctor output"), "exit_status": .number(0)]))
        let version = try field(doctor, "report", "version")
        XCTAssertNil(version.page?.component("report-output"))
        let pending = try source(version)
        let failed = try render(event: .sourceDelivered(page: "homebrew-doctor", source: pending.id, sequence: 1, result: .null, failure: .init(category: .toolFailed, message: "Version unavailable")), state: version.state)
        XCTAssertNil(failed.page?.component("report-output"))
        XCTAssertNotNil(failed.page?.component("error"))
    }
    func testSystemServiceRowsExplainReadOnlyOwnershipAndOfferNoMutation() throws {
        let listed = try deliver(open("brew.services"), .object(["services": .array([.object(["name": .string("system-redis"), "status": .string("started"), "user_owned": .bool(false)])])]))
        let item = try XCTUnwrap(listed.page?.collection?.items.first)
        XCTAssertEqual(item.accessory, "Read Only")
        XCTAssertTrue(item.subtitle?.contains("Managed outside your user account") == true)
        XCTAssertEqual(item.actions, [])
        XCTAssertNil(try row(listed, named: "system-redis").operation)
    }
    func testCorruptIgnoredAppsStorageShowsARecoverableErrorWithoutDiscardingIt() throws {
        let id = try plugin().manifest.id
        try storage.setValue(.string("corrupt"), forKey: "homebrew.browser.v3.ignored-apps", of: id)
        let listed = try deliver(open("brew.adopt"), .object(["applications": .array([])]))
        XCTAssertNotNil(listed.page?.component("error"))
        XCTAssertNil(listed.operation)
        XCTAssertEqual(try storage.value(forKey: "homebrew.browser.v3.ignored-apps", of: id), .string("corrupt"))
    }
    func testIgnoreWriteFailureKeepsTheApplicationAvailableAndShowsError() throws {
        let application: JSONValue = .object(["identity": .string("copy"), "target": .string("target"), "name": .string("Example"), "candidates": .array([.object(["name": .string("example"), "confidence": .string("likely")])])])
        let listed = try deliver(open("brew.adopt"), .object(["applications": .array([application])]))
        // Existing cache can still be read, but the next key cannot be created.
        storage = PluginStorage(directory: directory, limits: .init(maximumKeyLength: 256, maximumValueBytes: 512 * 1024, maximumPluginBytes: 10 * 1024 * 1024, maximumKeyCount: 1))
        let failed = try row(listed, named: "Example", action: "ignore")
        XCTAssertNotNil(failed.page?.component("error"))
        XCTAssertEqual(failed.page?.collection?.total, 1)
        XCTAssertNil(failed.operation)
    }

    func testLostSelectionGenerationCannotSilentlyUpgradePreviouslyExcludedPackages() throws {
        let listed = try loaded("brew.outdated", packages: [package("one"), package("two")])
        let excluded = try row(listed, named: "two", action: "include")
        try storage.setValue(.object(["generation": .string("another-view"), "data": .object(["excluded": .array([])])]), forKey: "homebrew.browser.v3.selection", of: try plugin().manifest.id)
        let stale = try press(excluded, "upgrade-formula")
        XCTAssertNil(stale.operation)
        XCTAssertNotNil(stale.page?.component("error"))
        let refreshed = try deliver(press(stale, "refresh"), data("outdated", [package("one"), package("two")]))
        XCTAssertNil(refreshed.page?.component("error"))
        XCTAssertEqual(refreshed.page?.collection?.items.filter { $0.marks.contains("included") }.count, 2)
        XCTAssertNil(refreshed.operation)
    }

    func testCatalogAdmissionAndRunningOutputNeverReadBeforeActualCompletion() throws {
        let opened = try render("brew.outdated")
        let admitted = try render(event: .operationFinished(id: "brew-task", perform: "tools.startTask", outcome: .succeeded), state: opened.state)
        XCTAssertFalse(admitted.page?.sources.contains { $0.perform == "tools.read" } == true)
        let task: JSONValue = .object(["id": .string("activity_1123456789abcdef0123456789abcdef"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("running"), "output": .string("Updating…")])
        let running = try render(event: .sourceDelivered(page: "homebrew-task", source: "brew-activities", sequence: 1, result: .array([task]), failure: nil), state: admitted.state)
        XCTAssertEqual(try text(running,"task-output"), "Updating…")
        XCTAssertFalse(running.page?.sources.contains { $0.perform == "tools.read" } == true)
        XCTAssertEqual(try press(running,"stop").operation?.perform,"activities.stop")
        XCTAssertNil(try render("brew.outdated",event: .called,state: running.state).operation)
        let finished = try finishCatalogRefresh(opened)
        XCTAssertEqual(finished.page?.id,"homebrew-outdated")
        XCTAssertEqual(try source(finished).input.value(atPointer:"/operation"),.string("outdated"))
        XCTAssertNil(finished.operation)
    }
    func testCatalogFailureRequiresExplicitRetryOrDisclosedLocalRead() throws {
        for outcome in ["failed","stopped","unknown"] {
            let failed = try completeCatalog(render("brew.outdated"),outcome:outcome)
            XCTAssertEqual(failed.page?.id,"homebrew-task")
            XCTAssertEqual(try text(failed,"task-output"),"Catalog fixture output")
            XCTAssertTrue(failed.page?.sources.isEmpty == true)
            XCTAssertNil(failed.operation)
            let local = try press(failed,"local-catalog")
            XCTAssertNil(local.operation)
            XCTAssertTrue(try text(local,"notice").contains("last locally available"))
            XCTAssertEqual(try source(local).input.value(atPointer:"/operation"),.string("outdated"))
            let retry = try press(failed,"retry-catalog")
            XCTAssertEqual(retry.operation?.input.value(atPointer:"/operation"),.string("refreshCatalog"))
            XCTAssertFalse(retry.page?.sources.contains { $0.perform == "tools.read" } == true)
        }
    }
    func testCatalogRefusalDoesNotReplayFromLateActivityOrAttachToAnOldTask() throws {
        let old: JSONValue = .object(["id": .string("old-catalog"), "kind": .string("task"), "tool": .string("homebrew"), "status": .string("ended"), "result": .object(["outcome": .string("completed")])])
        let opened = try render("brew.outdated",activities:[old])
        let refused = try render(event:.operationFinished(id:"brew-task",perform:"tools.startTask",outcome:.declined),state:opened.state)
        let late = try render(event:.sourceDelivered(page:"homebrew-task",source:"brew-activities",sequence:1,result:.array([old]),failure:nil),state:refused.state)
        XCTAssertNil(late.operation); XCTAssertTrue(late.page?.sources.isEmpty == true)
        let admitted = try render(event:.operationFinished(id:"brew-task",perform:"tools.startTask",outcome:.succeeded),state:opened.state)
        let waiting = try render(event:.sourceDelivered(page:"homebrew-task",source:"brew-activities",sequence:1,result:.array([old]),failure:nil),state:admitted.state)
        XCTAssertFalse(waiting.page?.sources.contains { $0.perform == "tools.read" } == true)
    }
    func testSectionEntryRefreshesButTypingFiltersAndCheckboxesDoNot() throws {
        let listed = try loaded("brew.outdated",packages:[package("wget")])
        XCTAssertNil(try field(listed,"query-outdated","wget").operation)
        XCTAssertNil(try field(listed,"kind","formula").operation)
        XCTAssertNil(try row(listed,named:"wget",action:"include").operation)
        let away = try field(listed,"section","list")
        let entered = try render(event:.pageFieldChanged(page:"homebrew-list",field:"section",values:.object(["section":.string("outdated")])),state:away.state)
        XCTAssertEqual(entered.operation?.input.value(atPointer:"/operation"),.string("refreshCatalog"))
        let reopened = try render("brew.outdated",event:.called,state:listed.state)
        XCTAssertEqual(reopened.operation?.input.value(atPointer:"/operation"),.string("refreshCatalog"))
        let completed = try finishCatalogRefresh(entered)
        XCTAssertNil(completed.state.value(atPointer:"/caches/selection"))
        XCTAssertEqual(completed.page?.reset?.resets("query-outdated"),true)
        XCTAssertEqual(completed.page?.reset?.resets("kind"),true)
        XCTAssertEqual(completed.page?.reset?.resets("section"),true)
        XCTAssertNil(completed.operation)
    }

    func testInstalledAndSearchReadImmediatelyOnEntryNavigationAndRepeatedCalls() throws {
        for command in ["brew.installed","brew.search"] {
            let opened = try render(command)
            XCTAssertNil(opened.operation)
            XCTAssertEqual(try source(opened).input.value(atPointer:"/operation"),.string("installed"))
            let called = try render(command,event:.called,state:opened.state)
            XCTAssertNil(called.operation)
            XCTAssertEqual(try source(called).input.value(atPointer:"/operation"),.string("installed"))
        }
        let listed = try loaded("brew.outdated",packages:[package("wget")])
        for section in ["list","search"] {
            let entered = try render(event:.pageFieldChanged(page:"homebrew-outdated",field:"section",values:.object(["section":.string(section)])),state:listed.state)
            XCTAssertNil(entered.operation)
            XCTAssertEqual(try source(entered).input.value(atPointer:"/operation"),.string("installed"))
        }
    }

}
