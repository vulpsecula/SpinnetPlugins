import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SystemMonitorDistributionTests: XCTestCase {
    func testStableBundledAndInstalledCopiesRequireTheSameMetricGrant() throws {
        for origin: PluginOrigin in [.bundled, .installed] {
            let plugin = try PluginUnderTest(named: "SystemMonitor.spinnetplugin", origin: origin)
            XCTAssertEqual(plugin.manifest.id.rawValue, "com.spinnet.system-monitor")
            XCTAssertEqual(plugin.manifest.hostCompatibility.rawValue, "^1.0.0")

            XCTAssertEqual(plugin.manifest.capabilities, [.readSystemStatus])
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry(grantStore: grants)
            try registry.register(plugin.package)
            let action = try plugin.action(for: PluginTestInvocation("monitor.show"))
            XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .readSystemStatus, scope: plugin.manifest.scope(for: .readSystemStatus))
            XCTAssertEqual(registry.availability(for: action), .available)
            grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .readSystemStatus, scope: plugin.manifest.scope(for: .readSystemStatus))
            XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        }
    }
}
