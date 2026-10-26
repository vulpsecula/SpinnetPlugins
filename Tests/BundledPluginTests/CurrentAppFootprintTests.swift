import XCTest
import Darwin
import SpinnetCore
import SpinnetPluginTestKit

final class CurrentAppFootprintTests: XCTestCase {
    func footprint() throws -> UInt64 {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-x", "SpinnetPluginHelper"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let pids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 1, "Only this test's current helper may be sampled")
        return try XCTUnwrap(pids.first.flatMap { PluginHelperResourceSampler.physFootprint(processID: $0) })
    }

    func testIncrementalActiveHelperFootprintAgainstEmptyPlugin() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CURRENT_APP_MEASURE"] == "1",
                          "Set CURRENT_APP_MEASURE=1 for the local resource measurement")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("current-app-empty-\(UUID().uuidString).spinnetplugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        {"protocol_version":"1.0","engines":{"spinnet":"^1.0.0"},"id":"com.spinnet.probe.empty","name":"Empty",
         "version":"1.0.0","capabilities":[],"preset":{"readiness":"ready_to_use","is_configurable":false,
         "default_primary_command_id":"empty","default_alternate_command_ids":[]},"commands":[{"id":"empty",
         "title":"Empty","description":"Empty helper baseline","execution":"javascript","is_configurable":false,"script":"empty.js"}]}
        """.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("null;".utf8).write(to: directory.appendingPathComponent("empty.js"))
        let empty = try PluginUnderTest(packageAt: directory)
        let baselineHelper = try PluginTestHelper()
        _ = try baselineHelper.run(PluginTestInvocation("empty"), of: empty, answering: RecordedHostServices()).answer()
        let baseline = try footprint()
        baselineHelper.shutdown()

        let plugin = try PluginUnderTest(named: "CurrentApp.spinnetplugin", origin: .bundled)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let apps = RecordedApps()
        let services = RecordedHostServices(apps: apps)
        _ = try helper.run(PluginTestInvocation("current.inspect"), of: plugin, answering: services).answer()
        let active = try footprint()
        for _ in 0..<100 {
            _ = try helper.run(PluginTestInvocation("current.inspect"), of: plugin, answering: services).answer()
        }
        let warm = try footprint()
        let incremental = max(active, warm) > baseline ? max(active, warm) - baseline : 0
        print("CURRENT_APP_FOOTPRINT version=\(plugin.manifest.version) empty_bytes=\(baseline) active_bytes=\(active) after_100_bytes=\(warm) incremental_bytes=\(incremental) helper_launches=\(helper.launchCount)")
        XCTAssertLessThanOrEqual(incremental, 6 * 1_024 * 1_024)
        XCTAssertEqual(helper.launchCount, 1)
    }
}
