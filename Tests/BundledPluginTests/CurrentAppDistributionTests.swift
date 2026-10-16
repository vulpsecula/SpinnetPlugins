import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class CurrentAppDistributionTests: XCTestCase {
    func testBundledAndUserInstalledCopiesRequireTheSameTwoGrants() throws {
        for origin: PluginOrigin in [.bundled, .installed] {
            let plugin = try PluginUnderTest(named: "CurrentApp.spinnetplugin", origin: origin)
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

    func testBundledCurrentAppKeepsAcceptedIdentityAndReviewsBeforeAnyExit() throws {
        let plugin = try PluginUnderTest(named: "CurrentApp.spinnetplugin", origin: .bundled)
        XCTAssertEqual(plugin.manifest.id.rawValue, "com.spinnet.probe.current-app")
        XCTAssertEqual(plugin.manifest.apiLevel, 2)
        XCTAssertTrue(plugin.manifest.candidateContracts.isEmpty)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let apps = RecordedApps()
        let answer = try helper.run(PluginTestInvocation("current.close"), of: plugin,
                                    answering: RecordedHostServices(apps: apps)).answer()
        XCTAssertEqual(answer.page?.id, "current")
        XCTAssertNil(answer.operation)
        XCTAssertEqual(apps.exits, [])
    }
}
