import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class CurrentAppConfigurationTests: XCTestCase {
    func plugin() throws -> PluginUnderTest {
        try PluginUnderTest(named: "CurrentApp.spinnetplugin", origin: .bundled)
    }

    func testCloseIsTheConfiguredPrimaryAndQuitAnAlternateButCallingEitherOnlyReviews() throws {
        let plugin = try plugin()
        XCTAssertEqual(plugin.manifest.preset.defaultPrimaryCommandID?.rawValue, "current.close")
        XCTAssertEqual(plugin.manifest.preset.defaultAlternateCommandIDs.map(\.rawValue), ["current.quit", "current.inspect"])
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let apps = RecordedApps()
        for command in ["current.close", "current.quit"] {
            let opened = try helper.run(PluginTestInvocation(command), of: plugin,
                                        answering: RecordedHostServices(apps: apps)).answer()
            XCTAssertEqual(opened.page?.id, "current")
            XCTAssertNil(opened.operation)
        }
        XCTAssertEqual(apps.exits, [])
    }

    func testTheConfiguredCommandNamesItsTargetAndOrdersItsPreferredExitFirst() throws {
        let plugin = try plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        for (command, expected) in [("current.close", ["Close TextEdit's Window", "Quit TextEdit"]),
                                    ("current.quit", ["Quit TextEdit", "Close TextEdit's Window"])] {
            let answer = try helper.run(PluginTestInvocation(command), of: plugin,
                answering: RecordedHostServices(apps: RecordedApps())).answer()
            let page = try XCTUnwrap(answer.page)
            guard case .actions(_, let ordinary)? = page.component("exits") else { return XCTFail("No ordinary exits") }
            XCTAssertEqual(ordinary.map(\.title), expected)
            guard case .text(let identity)? = page.component("bundle") else { return XCTFail("No App identity") }
            XCTAssertEqual(identity.text, "com.apple.TextEdit")
            guard case .text(let warning)? = page.component("force-warning") else { return XCTFail("No Force Quit warning") }
            XCTAssertTrue(warning.text.contains("unsaved changes"))
        }
    }

    func testRefreshAndCallingAnotherConfiguredCommandAreTheOnlyWaysToChangeTheTarget() throws {
        let plugin = try plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let page = PluginTestPage("current.close", of: plugin, helper: helper, answering: RecordedHostServices(apps: apps))
        try page.open()
        apps.bringToFront(.safari)
        guard case .text(let held)? = page.page?.component("target") else { return XCTFail("No target") }
        XCTAssertEqual(held.text, "TextEdit")
        try page.click("refresh")
        guard case .text(let refreshed)? = page.page?.component("target") else { return XCTFail("No refreshed target") }
        XCTAssertEqual(refreshed.text, "Safari")
        try page.call("current.quit")
        guard case .actions(_, let exits)? = page.page?.component("exits") else { return XCTFail("No exits") }
        XCTAssertEqual(exits.first?.title, "Quit Safari")
        XCTAssertEqual(apps.exits, [])
    }

    func testAnUnsupportedConfiguredDefaultIsExplainedWithoutSubstitutingForceQuit() throws {
        let plugin = try plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let apps = RecordedApps(front: RecordedApps.App("No Windows", bundleID: "com.example.empty", menu: [.quit]))
        let answer = try helper.run(PluginTestInvocation("current.close"), of: plugin, answering: RecordedHostServices(apps: apps)).answer()
        guard case .text(let policy)? = answer.page?.component("preferred-status") else { return XCTFail("No default explanation") }
        XCTAssertTrue(policy.text.contains("Close Window is unavailable"))
        guard case .actions(_, let exits)? = answer.page?.component("exits") else { return XCTFail("No supported exit") }
        XCTAssertEqual(exits.map(\.title), ["Quit No Windows"])
        XCTAssertNil(answer.operation)
        XCTAssertEqual(apps.exits, [])
    }
}
