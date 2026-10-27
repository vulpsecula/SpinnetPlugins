import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SpotifyDistributionTests: XCTestCase {
    func testBundledSpotifyKeepsAcceptedIdentityOnStableContract() throws {
        let plugin = try PluginUnderTest(named: "Spotify.spinnetplugin", origin: .bundled)
        XCTAssertEqual(plugin.manifest.id.rawValue, "com.spinnet.external.spotify")
        XCTAssertEqual(plugin.manifest.version, "1.2.0")
        XCTAssertEqual(plugin.manifest.hostCompatibility.rawValue, "^1.0.0")

        XCTAssertEqual(plugin.manifest.commands.count, 9)
    }

    func testBundledAndInstalledCopiesNeedTheSameScopedPlaybackGrant() throws {
        for origin: PluginOrigin in [.bundled, .installed] {
            let plugin = try PluginUnderTest(named: "Spotify.spinnetplugin", origin: origin)
            let action = try plugin.action(for: PluginTestInvocation("spotify.toggle"))
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
                externalAppConnectionStatus: { _ in .ready })
            try registry.register(plugin.package)
            var dispatches = 0
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants,
                systemPermissionCheck: { _ in true },
                clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
                externalApps: .init(reviewedAppPerformer: { _, _ in dispatches += 1; return .null }),
                pluginRegistry: registry
            )
            let request = PluginRuntimeHostServiceRequest(invocationID: "toggle", actionID: action.id,
                service: .performAppOperation, input: .object(["bundle_id": .string("com.spotify.client"),
                    "operation": .string("play_pause")]), operation: "apps.perform")
            for decision in [PluginCapabilityGrantDecision.notDetermined, .denied] {
                grants.setDecision(decision, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                    capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
                XCTAssertThrowsError(try broker.execute(request: request, for: plugin.package, action: action))
                XCTAssertEqual(dispatches, 0)
            }
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
            XCTAssertEqual(try broker.execute(request: request, for: plugin.package, action: action), .null)
            XCTAssertEqual(dispatches, 1)
            grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
            XCTAssertThrowsError(try broker.execute(request: request, for: plugin.package, action: action))
            XCTAssertEqual(dispatches, 1)
        }
    }
}
