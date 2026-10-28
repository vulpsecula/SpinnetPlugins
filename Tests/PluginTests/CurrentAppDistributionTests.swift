import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class CurrentAppDistributionTests: XCTestCase {
    func testCloseRequiresBothGrants() throws {
        let plugin = try PluginUnderTest(named: "CurrentApp.spinnetplugin")
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(plugin.package)
        let action = try plugin.action(for: PluginTestInvocation("current.close"))
        XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        for capability in plugin.manifest.capabilities {
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                               capability: capability, scope: plugin.manifest.scope(for: capability))
        }
        XCTAssertEqual(registry.availability(for: action), .available)
        grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                           capability: .quitFrontmostApp)
        XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
    }
}
