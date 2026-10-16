import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class OfficialPackagesTests: XCTestCase {
    func testEveryShippedPackageLoadsWithItsExistingIdentityAndStableContract() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Plugins")
        let packages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "spinnetplugin" }
            .map { try PluginUnderTest(packageAt: $0, origin: .bundled) }
        XCTAssertEqual(Set(packages.map { $0.manifest.id.rawValue }), [
            "com.spinnet.bob", "com.spinnet.clipboard-history", "com.spinnet.builtin.copy-selected-text",
            "com.spinnet.builtin.cut", "com.spinnet.builtin.open-application", "com.spinnet.builtin.open-file",
            "com.spinnet.builtin.open-folder", "com.spinnet.builtin.open-url", "com.spinnet.builtin.paste",
            "com.spinnet.builtin.keyboard-shortcut", "com.spinnet.builtin.service", "com.spinnet.builtin.run-shortcut",
            "com.spinnet.builtin.screenshot", "com.spinnet.shottr", "com.spinnet.smart-jump",
            "com.spinnet.translator", "com.spinnet.window-position", "com.spinnet.coffee",
            "com.spinnet.probe.current-app", "com.spinnet.external.spotify", "com.spinnet.system-monitor",
            "com.spinnet.homebrew"
        ])
        XCTAssertEqual(packages.count, 22)
        for plugin in packages {
            XCTAssertTrue(plugin.manifest.candidateContracts.isEmpty, plugin.manifest.id.rawValue)
            XCTAssertLessThanOrEqual(plugin.manifest.apiLevel, PluginAPILevel.highestSupported)
        }
    }
}
