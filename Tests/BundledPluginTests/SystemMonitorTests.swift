import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SystemMonitorTests: XCTestCase {
    func testCompletePageUsesVisibleBindingsAndSurvivesHelperRetirement() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("monitor.show", of: plugin, helper: helper)
        try page.open()
        XCTAssertEqual(page.page?.id, "monitor")
        XCTAssertNotNil(page.pageJSON?.value(atPointer: "/resizable"))
        XCTAssertEqual(page.page?.sources.map(\.perform), ["system.metrics"])
        XCTAssertFalse(try XCTUnwrap(page.page?.sources.first).delivers)
        XCTAssertNotNil(page.page?.component("cpu-value"))
        helper.retireHelper(of: plugin)
        _ = try page.call()
        XCTAssertEqual(helper.launchCount, 2)
        XCTAssertEqual(page.page?.id, "monitor")
    }
}

extension SystemMonitorTests {
    func testRecordedMetricsStopWhileHiddenAndNeverRunAHelper() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let answer = try helper.run(PluginTestInvocation("monitor.show"), of: plugin, answering: RecordedHostServices()).result.get()
        let snapshot: JSONValue = .object(["cpu": .object(["busy": .number(0.37)]), "memory": .object(["used_bytes": .number(8_589_934_592), "total_bytes": .number(17_179_869_184)]), "disk": .null,
            "battery": .object(["present": .bool(false), "charge": .null, "charging": .null, "power_source": .null])])
        let sources = try RecordedHostSources(of: plugin, for: PluginTestInvocation("monitor.show"), operations: ["system.metrics": .value(snapshot)])
        try sources.present(try XCTUnwrap(answer.value(atPointer: "/page")))
        sources.setVisible(true)
        XCTAssertEqual(sources.shown("cpu-value", locale: Locale(identifier: "en_US"))?.text, "37%")
        XCTAssertEqual(sources.shown("battery-detail")?.text, "No battery or unavailable")
        XCTAssertEqual(sources.shown("disk-value")?.text, "Unavailable")
        let visibleCount = sources.samples.count
        sources.setVisible(false); sources.advance(by: 60)
        XCTAssertEqual(sources.samples.count, visibleCount)
        XCTAssertTrue(try XCTUnwrap(sources.shown("cpu-value")).isStale)
        XCTAssertTrue(sources.deliveries.isEmpty)
        XCTAssertEqual(helper.launchCount, 1)
        sources.setVisible(true); sources.advance(by: 3)
        XCTAssertEqual(sources.samples.count, visibleCount + 4, "One immediate sample, then one per second; no hidden backlog")
        sources.close(); let closedCount = sources.samples.count; sources.advance(by: 60)
        XCTAssertEqual(sources.samples.count, closedCount)
        XCTAssertNil(sources.shown("cpu-value"))
    }
}

extension SystemMonitorTests {
    private func loadedPage(_ plugin: PluginUnderTest, _ helper: PluginTestHelper) throws -> JSONValue {
        let answer = try helper.run(PluginTestInvocation("monitor.show"), of: plugin, answering: RecordedHostServices()).result.get()
        return try XCTUnwrap(answer.value(atPointer: "/page"))
    }
    func testDeniedAndRevokedAuthorityNeverContinuesRefreshing() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = try loadedPage(plugin, helper)
        let sources = try RecordedHostSources(of: plugin, for: PluginTestInvocation("monitor.show"), deniedCapabilities: [.readSystemStatus], operations: ["system.metrics": .value(.object(["cpu": .object(["busy": .number(0.5)])]))])
        try sources.present(page); sources.setVisible(true)
        XCTAssertTrue(try XCTUnwrap(sources.shown("cpu-value")).text.contains("read_system_status"))
        sources.grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readSystemStatus, scope: plugin.manifest.scope(for: .readSystemStatus))
        sources.authorityChanged(); sources.advance(by: 1)
        XCTAssertEqual(sources.shown("cpu-value", locale: Locale(identifier:"en_US"))?.text, "50%")
        sources.grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readSystemStatus, scope: plugin.manifest.scope(for: .readSystemStatus))
        // The native Host ends the View Session synchronously on revocation;
        // this test also checks that the adapter re-authorizes before any read.
        sources.advance(by: 1)
        XCTAssertTrue(try XCTUnwrap(sources.shown("cpu-value")).isStale)
        sources.close(); let count = sources.samples.count; sources.advance(by: 30)
        XCTAssertEqual(sources.samples.count, count)
        XCTAssertEqual(helper.launchCount, 1)
    }

    func testActualNativeAdapterDropsLateAnswersWhenHiddenOrUnregistered() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = try PluginPage(parsing: loadedPage(plugin, helper), permits: helper.contracts.permitting(plugin.manifest))
        let action = try plugin.action(for: PluginTestInvocation("monitor.show"))
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readSystemStatus, scope: plugin.manifest.scope(for: .readSystemStatus))
        let registry = PluginRegistry(grantStore: grants); try registry.register(plugin.package)
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in XCTFail("No System Permission applies"); return false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in })
        let adapter = broker.systemMetricsSourceAdapter(using: registry)
        var background: [() -> Void] = [], finishes: [() -> Void] = [], timers: [() -> Void] = []
        let engine = HostRunSources(adapters: ["system.metrics": adapter], schedule: { _, task in timers.append(task) }, background: { background.append($0) }, executor: { finishes.append($0) })
        try engine.present(page, for: action); engine.setVisible(true, pluginID: plugin.manifest.id)
        background.removeFirst()()
        engine.setVisible(false, pluginID: plugin.manifest.id)
        finishes.removeFirst()()
        XCTAssertEqual(engine.shown(component: "cpu-value", pluginID: plugin.manifest.id)?.text, "—")
        for timer in timers { timer() }
        XCTAssertTrue(background.isEmpty, "Hidden snapshots must not be queued")
        engine.end(pluginID: plugin.manifest.id)
        XCTAssertNil(engine.shown(component: "cpu-value", pluginID: plugin.manifest.id))
        XCTAssertEqual(helper.launchCount, 1)
        try engine.present(page, for: action); engine.setVisible(true, pluginID: plugin.manifest.id)
        background.removeFirst()()
        registry.unregister(plugin.manifest.id)
        finishes.removeFirst()()
        XCTAssertEqual(engine.shown(component: "cpu-value", pluginID: plugin.manifest.id)?.text, "—", "An invalid owner's late result must not appear")
        engine.end(pluginID: plugin.manifest.id)
        let input: JSONValue = .object(["metrics": .array(["cpu","memory","disk","battery"].map(JSONValue.string))])
        let snapshot = try SystemMetricsSampler().read(input, owner: plugin.manifest.id)
        XCTAssertEqual(snapshot.value(atPointer: "/memory/total_bytes"), .number(Double(ProcessInfo.processInfo.physicalMemory)))
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 1024)
    }

    func testOptInNativeMetricsReadCost() throws {
        guard ProcessInfo.processInfo.environment["SYSTEM_MONITOR_MEASURE"] == "1" else {
            throw XCTSkip("Set SYSTEM_MONITOR_MEASURE=1 for the 1000-sample native metrics measurement")
        }
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let input: JSONValue = .object(["metrics": .array(["cpu","memory","disk","battery"].map(JSONValue.string))])
        let snapshot = try SystemMetricsSampler().read(input, owner: plugin.manifest.id)
        print("METRIC_SNAPSHOT \(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))")
        var times: [Double] = [], resultBytes = 0
        for _ in 0..<1000 {
            let start = DispatchTime.now().uptimeNanoseconds
            // Each sample measures a fresh native sampler, as in the original proof.
            let result = try SystemMetricsSampler().read(input, owner: plugin.manifest.id)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
            resultBytes = max(resultBytes, try JSONEncoder().encode(result).count)
            XCTAssertEqual(result.value(atPointer: "/memory/total_bytes"), .number(Double(ProcessInfo.processInfo.physicalMemory)))
            XCTAssertLessThan(resultBytes, 1024)
        }
        times.sort()
        print("METRIC_NATIVE_COST n=\(times.count) p50_us=\(times[times.count / 2]) p95_us=\(times[times.count * 95 / 100]) max_us=\(times.last!) max_result_bytes=\(resultBytes) source_every_seconds=1")
        print("METRIC_MACHINE \(ProcessInfo.processInfo.operatingSystemVersionString) cores=\(ProcessInfo.processInfo.processorCount) memory=\(ProcessInfo.processInfo.physicalMemory)")
    }
}

extension SystemMonitorTests {
    func testNormalInstallationRequestsTheSameGrantAsAnyExternalPlugin() throws {
        let source = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = PluginCapabilityGrantStore(), registry = PluginRegistry()
        let installer = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: {})
        let review = try installer.review(source.package.rootURL)
        XCTAssertEqual(review.requestedAccess, [.readSystemStatus])
        try installer.install(from: source.package.rootURL)
        let package = try XCTUnwrap(registry.package(for: source.manifest.id))
        XCTAssertEqual(package.origin, .installed)
        for filename in ["manifest.json", "monitor.js"] {
            XCTAssertEqual(try Data(contentsOf: source.package.rootURL.appendingPathComponent(filename)),
                try Data(contentsOf: package.rootURL.appendingPathComponent(filename)))
        }
        XCTAssertEqual(grants.decision(for: source.manifest.id, pluginVersion: source.manifest.version,
            capability: .readSystemStatus, scope: source.manifest.scope(for: .readSystemStatus)), .notDetermined)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt: package.rootURL)
        let page = PluginTestPage("monitor.show", of: plugin, helper: helper)
        try page.open()
        XCTAssertEqual(page.page?.id, "monitor")
    }
}


extension SystemMonitorTests {
    func testStableAdaptiveCardsPreserveTheVisibleSourceAndBindings() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        XCTAssertEqual(plugin.manifest.apiLevel, 3)
        XCTAssertTrue(plugin.manifest.candidateContracts.isEmpty)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("monitor.show", of: plugin, helper: helper)
        try page.open()
        let json = try XCTUnwrap(page.pageJSON)
        XCTAssertEqual(json.value(atPointer: "/content/0/kind"), .string("adaptive"))
        XCTAssertEqual(json.value(atPointer: "/content/0/id"), .string("metric-cards"))
        XCTAssertEqual(json.value(atPointer: "/content/0/min_card_width"), .number(320))
        XCTAssertEqual(json.value(atPointer: "/content/0/spacing"), .number(12))
        XCTAssertEqual(json.value(atPointer: "/content/0/max_columns"), .number(2))
        let ids = ["cpu", "memory", "disk", "battery"]
        XCTAssertEqual(page.page?.component("metric-cards")?.children.map(\.id),
            ["cpu-card", "memory-card", "disk-card", "battery-card"])
        let pointers = ["/cpu/busy", "/memory/used_bytes", "/disk/available_bytes", "/battery/charge"]
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(json.value(atPointer: "/content/0/content/\(index)/id"), .string(id + "-card"))
            XCTAssertEqual(json.value(atPointer: "/content/0/content/\(index)/content/1/bind/source"), .string("metrics"))
            XCTAssertEqual(json.value(atPointer: "/content/0/content/\(index)/content/1/bind/pointer"), .string(pointers[index]))
            XCTAssertNotNil(page.page?.component(id + "-value"), "Bindings remain discoverable inside the adaptive subtree")
        }
        for (index, pointer) in [(1, "/memory/total_bytes"), (2, "/disk/total_bytes"), (3, "/battery/power_source")] {
            XCTAssertEqual(json.value(atPointer: "/content/0/content/\(index)/content/2/bind/source"), .string("metrics"))
            XCTAssertEqual(json.value(atPointer: "/content/0/content/\(index)/content/2/bind/pointer"), .string(pointer))
        }
        XCTAssertEqual(page.page?.sources.map(\.perform), ["system.metrics"])
        XCTAssertFalse(try XCTUnwrap(page.page?.sources.first).delivers)
        XCTAssertEqual(json.value(atPointer: "/sources/0/input/metrics"), .array(["cpu", "memory", "disk", "battery"].map(JSONValue.string)))
        XCTAssertEqual(json.value(atPointer: "/sources/0/every"), .number(1))
    }
}


extension SystemMonitorTests {
    func testLevelTwoHostRefusesTheStableLevelThreePackageBeforeInstallation() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldHost = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels.filter { $0.key <= 2 })
        let registry = PluginRegistry(contracts: oldHost)
        let installer = PluginInstallationStore(directory: directory, registry: registry,
            grants: PluginCapabilityGrantStore(), persistGrants: {})
        XCTAssertThrowsError(try installer.review(plugin.package.rootURL)) { error in
            XCTAssertEqual(error as? UnsupportedPluginAPILevel, UnsupportedPluginAPILevel(requiredBy: plugin.manifest, supportedLevel: 2))
        }
        XCTAssertNil(registry.package(for: plugin.manifest.id))
    }

    func testAdaptiveBuilderRemainsUnavailableToAnOtherwiseIdenticalLevelTwoPlugin() throws {
        let source = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: source.package.rootURL, to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["api_level"] = 2
        manifest.removeValue(forKey: "candidate_contracts")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let undeclared = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        XCTAssertThrowsError(try helper.run(PluginTestInvocation("monitor.show"), of: undeclared, answering: RecordedHostServices()).answer()) { error in
            XCTAssertTrue(String(describing: error).contains("adaptive"), "The absent candidate member must explain the refusal: \(error)")
        }
    }
}

extension SystemMonitorTests {
    func testViewportFitDeclaresDensityWithoutDroppingPrimaryMetrics() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let page = PluginTestPage("monitor.show", of: plugin, helper: helper)
        try page.open()
        let json = try XCTUnwrap(page.pageJSON)
        XCTAssertEqual(json.value(atPointer: "/content/0/fit/profiles/0/id"), .string("compact"))
        XCTAssertEqual(json.value(atPointer: "/content/0/fit/profiles/1/id"), .string("standard"))
        XCTAssertEqual(json.value(atPointer: "/content/0/fit/profiles/2/id"), .string("spacious"))
        guard case .array(let profiles)? = json.value(atPointer: "/content/0/fit/profiles") else {
            return XCTFail("The complete page must declare its density profiles")
        }
        XCTAssertEqual(profiles.count, 3)
        for (index, profile) in profiles.enumerated() {
            guard case .array(let overrides)? = profile.value(atPointer: "/overrides") else {
                return XCTFail("Every declared density must retain its primary metric overrides")
            }
            XCTAssertEqual(overrides.count, 12)
            for metric in ["cpu", "memory", "disk", "battery"] {
                let title = try XCTUnwrap(overrides.first { $0.value(atPointer: "/id") == .string(metric + "-title") })
                let value = try XCTUnwrap(overrides.first { $0.value(atPointer: "/id") == .string(metric + "-value") })
                XCTAssertNotEqual(title.value(atPointer: "/hidden"), .bool(true))
                XCTAssertNotEqual(value.value(atPointer: "/hidden"), .bool(true))
                XCTAssertEqual(title.value(atPointer: "/style/font_weight"), .string("semibold"))
                XCTAssertEqual(value.value(atPointer: "/style/font_weight"), .string("bold"))
                XCTAssertEqual(value.value(atPointer: "/style/monospaced_digits"), .bool(true))
                XCTAssertEqual(value.value(atPointer: "/style/font_size"), .number([20.0, 26.0, 32.0][index]))
                let detail = try XCTUnwrap(overrides.first { $0.value(atPointer: "/id") == .string(metric + "-detail") })
                XCTAssertEqual(detail.value(atPointer: "/hidden") == .bool(true), index == 0)
            }
        }
        for metric in ["cpu", "memory", "disk", "battery"] {
            XCTAssertNotNil(page.page?.component(metric + "-title"))
            XCTAssertNotNil(page.page?.component(metric + "-value"))
        }
    }
}

extension SystemMonitorTests {
    func testHistoricalCandidatePackageIsRefusedAfterStablePromotion() throws {
        let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: plugin.package.rootURL, to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["api_level"] = 2
        manifest["candidate_contracts"] = [["name": "adaptive_layout", "revision": 2]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let registry = PluginRegistry()
        let installer = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
            grants: PluginCapabilityGrantStore(), persistGrants: {})
        XCTAssertThrowsError(try installer.review(directory)) { error in
            XCTAssertEqual(error as? CandidateContractRefusal, .retired(plugin: "System Monitor",
                declared: CandidateContractRevision(name: "adaptive_layout", revision: 2), promotedToLevel: 3))
        }
        XCTAssertNil(registry.package(for: plugin.manifest.id))
    }
}
