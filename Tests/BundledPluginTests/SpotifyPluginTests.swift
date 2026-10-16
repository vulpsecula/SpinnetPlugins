import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SpotifyPluginTests: XCTestCase {
    private var directory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Plugins/Spotify.spinnetplugin") }

    private func connectedRegistry() throws -> PluginRegistry {
        let manifest = try PluginUnderTest(packageAt: directory).manifest
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        return PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { _ in .ready })
    }
}

extension SpotifyPluginTests {
    func testConnectionIsDeclaredForEveryDailyActionInsteadOfOfferingAConnectAction() throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(manifest.value(atPointer: "/external_app_connections"), .array([.object([
            "bundle_id": .string("com.spotify.client"),
            "command_ids": .array(["spotify.toggle", "spotify.play", "spotify.pause", "spotify.previous", "spotify.next",
                                  "spotify.volume-up", "spotify.volume-down", "spotify.volume", "spotify.mute"].map(JSONValue.string))
        ])]))
        let plugin = try PluginUnderTest(packageAt: directory)
        XCTAssertFalse(plugin.manifest.commands.contains { $0.id.rawValue == "spotify.connect" })
        XCTAssertFalse(plugin.manifest.preset.defaultAlternateCommandIDs.contains(CommandID("spotify.connect")))
    }

    func testHostEntryWaitsForConnectionWithoutReplayingPlaybackAndPreservesConfiguredActions() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
        var status = ExternalAppConnectionStatus.permissionNeeded
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { _ in status })
        try registry.register(plugin.package)
        let action = try plugin.action(for: PluginTestInvocation("spotify.toggle"))
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        var playbackRequests: [JSONValue] = []
        let services = RecordedHostServices(operations: ["apps.perform": .answer {
            playbackRequests.append($0)
            return .null
        }])
        let runner = HostActionRunner(executor: services, scriptedExecutor: helper, hostServiceBroker: services)
        let empty = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let editor = HostConfigurationEditor(registry: registry, configuration: empty)
        XCTAssertThrowsError(try editor.placePreset(pluginID: plugin.manifest.id, inSlotAt: 0))
        guard case .failed(let blocked) = runner.invoke(action, using: registry).terminal else {
            return XCTFail("An unconnected Spotify Action must wait for Host setup")
        }
        XCTAssertEqual(blocked.category, .commandUnavailable)
        XCTAssertEqual(helper.launchCount, 0)
        XCTAssertTrue(playbackRequests.isEmpty)

        status = .ready
        _ = try editor.placePreset(pluginID: plugin.manifest.id, inSlotAt: 0)
        let configured = editor.configuration
        XCTAssertTrue(playbackRequests.isEmpty, "Completing configuration never replays playback")
        guard case .succeeded(let answer) = runner.invoke(action, using: registry).terminal else {
            return XCTFail("The user's next explicit Action should run after connection")
        }
        XCTAssertEqual(answer.value(atPointer: "/toast"), .string("Play/Pause sent to Spotify."))
        XCTAssertEqual(playbackRequests, [.object(["bundle_id": .string("com.spotify.client"), "operation": .string("play_pause")])])

        for unavailable in [ExternalAppConnectionStatus.notRunning, .permissionDenied] {
            status = unavailable
            guard case .failed(let failure) = runner.invoke(action, using: registry).terminal else {
                return XCTFail("Stopped or unauthorized Spotify must not run playback")
            }
            XCTAssertEqual(failure.category, .commandUnavailable)
            XCTAssertEqual(editor.configuration, configured)
            XCTAssertEqual(playbackRequests.count, 1)
        }
    }

    func testNormalInstallationKeepsOriginInstalledAndLeavesEveryGrantUndetermined() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let store = PluginInstallationStore(directory: sandbox, registry: registry, grants: grants, persistGrants: {})
        let manifest = try store.install(from: directory)
        let installed = try XCTUnwrap(registry.package(for: manifest.id))
        XCTAssertEqual(installed.origin, .installed)
        for capability in manifest.capabilities {
            XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: capability,
                scope: manifest.scope(for: capability)), .notDetermined)
        }
        XCTAssertTrue(manifest.candidateContracts.isEmpty)
        XCTAssertEqual(manifest.apiLevel, 3)
        for filename in ["manifest.json", "actions.js"] {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(filename)),
                try Data(contentsOf: installed.rootURL.appendingPathComponent(filename)))
        }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt: installed.rootURL)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: installed.rootURL.path)), Set(["manifest.json", "actions.js", "LICENSE", "NOTICE"]))
        let answer = try helper.run(PluginTestInvocation("spotify.toggle"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": .value(.null)])).answer()
        XCTAssertNil(answer.description)
        XCTAssertEqual(answer.toast, "Play/Pause sent to Spotify.")
        XCTAssertNil(answer.operation)
    }
}

extension SpotifyPluginTests {
    func testStandaloneTransportActionsPerformOnceWithoutOpeningAView() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (command, operation, feedback) in [
            ("spotify.play", "play", "Play sent to Spotify."),
            ("spotify.pause", "pause", "Pause sent to Spotify."),
            ("spotify.previous", "previous", "Previous sent to Spotify.")
        ] {
            let services = RecordedHostServices(operations: ["apps.perform": .value(.null)])
            let run = helper.run(PluginTestInvocation(command), of: plugin, answering: services)
            let answer = try run.answer()
            XCTAssertNil(answer.description)
            XCTAssertEqual(answer.toast, feedback)
            XCTAssertEqual(run.requests.count, 1)
            XCTAssertEqual(run.requests.first?.input.value(atPointer: "/operation"), .string(operation))
        }
    }
}

extension SpotifyPluginTests {
    func testVolumeActionsUseNumericArgumentsAndReportObservedClampedVolume() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (command, input, operation, arguments, observed, feedback) in [
            ("spotify.volume-up", JSONValue.null, "adjust_volume", JSONValue.object(["delta": .number(5)]), 100, "Spotify volume: 100%."),
            ("spotify.volume-down", .null, "adjust_volume", .object(["delta": .number(-5)]), 0, "Spotify volume: 0%."),
            ("spotify.volume", .string("37"), "set_volume", .object(["volume": .number(37)]), 37, "Spotify volume: 37%.")
        ] {
            let services = RecordedHostServices(operations: ["apps.perform": .value(.object(["volume": .number(Double(observed))]))])
            let run = helper.run(PluginTestInvocation(command, input: input), of: plugin, answering: services)
            let answer = try run.answer()
            XCTAssertNil(answer.description)
            XCTAssertEqual(answer.toast, feedback)
            XCTAssertEqual(run.requests.count, 1)
            XCTAssertEqual(run.requests.first?.input.value(atPointer: "/operation"), .string(operation))
            XCTAssertEqual(run.requests.first?.input.value(atPointer: "/arguments"), arguments)
        }
    }
}

extension SpotifyPluginTests {
    func testNextActionReportsObservedBoundaryWithoutClaimingAnEmptyQueueOrRetrying() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (outcome, feedback) in [
            ("changed", "Spotify track changed."),
            ("unconfirmed", "No track change confirmed. Check Spotify's queue."),
            ("no_current_track", "No current track. Choose a song in Spotify."),
            ("stopped", "Spotify playback is stopped. Choose a song or resume playback.")
        ] {
            let services = RecordedHostServices(operations: ["apps.perform": .value(.object(["outcome": .string(outcome)]))])
            let run = helper.run(PluginTestInvocation("spotify.next"), of: plugin, answering: services)
            let answer = try run.answer()
            XCTAssertNil(answer.description)
            XCTAssertNil(answer.operation)
            XCTAssertEqual(answer.toast, feedback)
            XCTAssertEqual(run.requests.count, 1, "A boundary outcome never causes automatic transport retries")
            XCTAssertEqual(run.requests.first?.input, .object(["bundle_id": .string("com.spotify.client"), "operation": .string("next_checked")]))
        }
    }
}

extension SpotifyPluginTests {
    func testReadyConfigurablePresetDefaultsToStandalonePlayPauseAndOffersAllActions() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let registry = try connectedRegistry()
        try registry.register(plugin.package)
        let preset = try XCTUnwrap(registry.menuItemPreset(for: plugin.manifest.id))
        XCTAssertEqual(preset.readiness, .readyToUse)
        XCTAssertTrue(preset.isConfigurable)
        XCTAssertEqual(preset.declaration.defaultPrimaryCommandID?.rawValue, "spotify.toggle")
        XCTAssertEqual(Set(preset.commands.map(\.id.rawValue)), Set(["spotify.toggle", "spotify.play", "spotify.pause", "spotify.previous", "spotify.next", "spotify.volume-up", "spotify.volume-down", "spotify.volume", "spotify.mute"]))
        XCTAssertEqual(preset.declaration.defaultInputs[CommandID("spotify.volume")], .string("50"))
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)
        let placed = try editor.placePreset(pluginID: plugin.manifest.id, inSlotAt: 0)
        XCTAssertEqual(editor.configuration.actions.first(where: { $0.id == placed.primaryActionID })?.commandID.rawValue, "spotify.toggle")
        let alternates = preset.commands.map(\.id).filter { $0 != CommandID("spotify.volume") }
        let edited = try editor.configuredMenuItem(at: 0, pluginID: plugin.manifest.id,
            primaryCommandID: CommandID("spotify.volume"), alternateCommandIDs: alternates,
            inputs: [CommandID("spotify.volume"): .string("37")])
        XCTAssertEqual(edited.actions.count, 9)
        let configuredPrimary = try XCTUnwrap(edited.actions.first { $0.id == edited.menu.items.first?.primaryActionID })
        XCTAssertEqual(configuredPrimary.commandID.rawValue, "spotify.volume")
        XCTAssertEqual(configuredPrimary.input, .string("37"))
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let run = helper.run(PluginTestInvocation("spotify.toggle"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": .value(.null)]))
        let answer = try run.answer()
        XCTAssertNil(answer.description)
        XCTAssertEqual(answer.toast, "Play/Pause sent to Spotify.")
        XCTAssertEqual(run.requests.count, 1)
        XCTAssertEqual(run.requests.first?.input.value(atPointer: "/operation"), .string("play_pause"))
    }
}

extension SpotifyPluginTests {
    func testAbsoluteVolumeRejectsInvalidPercentagesWithoutRequestingAnyHostMutation() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for value in ["-1", "101", "2.5", "5x", "Infinity", "1e2", "+5", "NaN", "000"] {
            let run = helper.run(PluginTestInvocation("spotify.volume", input: .string(value)), of: plugin, answering: RecordedHostServices())
            let answer = try run.answer()
            XCTAssertEqual(answer.toast, "Set Volume needs a whole number from 0 to 100.")
            XCTAssertNil(answer.description)
            XCTAssertTrue(run.requests.isEmpty)
        }
        for (text, number) in [("0", 0), ("100", 100), (" 37 ", 37)] {
            let services = RecordedHostServices(operations: ["apps.perform": .value(.object(["volume": .number(Double(number))]))])
            let run = helper.run(PluginTestInvocation("spotify.volume", input: .string(text)), of: plugin, answering: services)
            _ = try run.answer()
            XCTAssertEqual(run.requests.first?.input.value(atPointer: "/arguments/volume"), .number(Double(number)))
            XCTAssertEqual(run.requests.count, 1)
        }
    }


    func testControlFailuresKeepHostRepairGuidanceAndNeverRetryOrReportSuccess() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for failure in [PluginHostServiceError.capabilityDenied(.controlExternalApp),
                        .appRead(.permissionNeeded), .automationPermissionDenied("Spotify"),
                        .appRead(.notRunning), .externalAppMissing("Install Spotify"),
                        .failed("Spotify request timed out; its effect is unknown")] {
            for command in ["spotify.toggle", "spotify.next", "spotify.volume-up"] {
                let services = RecordedHostServices(operations: ["apps.perform": .failure(failure)])
                let run = helper.run(PluginTestInvocation(command), of: plugin, answering: services)
                XCTAssertThrowsError(try run.answer()) { error in
                    XCTAssertEqual((error as? PluginRuntimeError)?.failureCategory, failure.actionFailureCategory)
                    XCTAssertTrue(String(describing: error).contains(failure.description))
                }
                XCTAssertEqual(run.requests.count, 1)
            }
        }
        let event = PluginViewEvent.operationFinished(id: "ignored", perform: "apps.perform", outcome: .succeeded)
        let run = helper.run(PluginTestInvocation("spotify.next", event: event), of: plugin, answering: RecordedHostServices())
        let answer = try run.answer()
        XCTAssertNil(answer.toast)
        XCTAssertNil(answer.operation)
        XCTAssertTrue(run.requests.isEmpty)
    }
}

extension SpotifyPluginTests {
    private func legacyPackage() throws -> PluginPackage {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Spotify/spotify-1.0-manifest.json")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: fixture))
        return PluginPackage(rootURL: directory, manifest: manifest, origin: .installed)
    }


    func testOlderHostRefusesStableLevelThreeUpdateWithoutReplacingTheExistingPlugin() throws {
        let legacy = try legacyPackage()
        let current = try PluginUnderTest(packageAt: directory)
        let oldContracts = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels.filter { $0.key <= 2 },
            candidates: [])
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(contracts: oldContracts, grantStore: grants)
        try registry.register(legacy)
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = PluginInstallationStore(directory: sandbox, registry: registry, grants: grants, persistGrants: {})
        XCTAssertThrowsError(try store.install(from: directory)) { error in
            XCTAssertTrue(String(describing: error).contains("3"))
        }
        XCTAssertEqual(registry.package(for: legacy.manifest.id)?.manifest.version, "1.0.0")
        XCTAssertEqual(grants.decision(for: current.manifest.id, pluginVersion: current.manifest.version,
            capability: .controlExternalApp, scope: current.manifest.scope(for: .controlExternalApp)), .notDetermined)
        let helper = try PluginTestHelper(contracts: oldContracts); defer { helper.shutdown() }
        let run = helper.run(PluginTestInvocation("spotify.toggle"), of: current, answering: RecordedHostServices())
        XCTAssertThrowsError(try run.answer())
        XCTAssertTrue(run.requests.isEmpty)
        XCTAssertEqual(helper.launchCount, 0)
    }
}

extension SpotifyPluginTests {
    func testMuteToggleRestoresActualPriorVolumeAcrossHelperAndStorageRestart() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var actual = 40.0
        var writes: [JSONValue] = []
        let volumeService = RecordedHostServices.Answer.answer { input in
            if input.value(atPointer: "/operation") == .string("set_volume") {
                writes.append(input)
                guard case .number(let target)? = input.value(atPointer: "/arguments/volume") else {
                    throw PluginHostServiceError.invalidInput("Expected numeric volume")
                }
                actual = target
            }
            return .object(["volume": .number(actual)])
        }
        let first = helper.run(PluginTestInvocation("spotify.mute"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": volumeService], storage: PluginStorage(directory: sandbox)))
        XCTAssertEqual(try first.answer().toast, "Spotify muted.")
        XCTAssertEqual(actual, 0)
        XCTAssertEqual(writes.count, 1)
        helper.retireHelper(of: plugin)
        let second = helper.run(PluginTestInvocation("spotify.mute"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": volumeService], storage: PluginStorage(directory: sandbox)))
        let restored = try second.answer()
        XCTAssertEqual(restored.toast, "Spotify unmuted: 40%.")
        XCTAssertNil(restored.description)
        XCTAssertEqual(actual, 40)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(helper.launchCount, 2)
    }
}

extension SpotifyPluginTests {
    func testMuteUsesDefaultForMissingOrInvalidRememberedVolumeAndTrustsExternalVolumeChanges() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let storage = PluginStorage(directory: sandbox)
        var actual = 0.0
        let services = RecordedHostServices(operations: ["apps.perform": .answer { input in
            if case .number(let target)? = input.value(atPointer: "/arguments/volume") { actual = target }
            return .object(["volume": .number(actual)])
        }], storage: storage)
        let fallback = try helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services).answer()
        XCTAssertEqual(fallback.toast, "Spotify unmuted: 50%.")
        XCTAssertEqual(actual, 50)
        // An external change must replace the remembered level on the next mute.
        actual = 73
        _ = try helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services).answer()
        let restored = try helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services).answer()
        XCTAssertEqual(restored.toast, "Spotify unmuted: 73%.")
        let key = try XCTUnwrap(storage.keys(of: plugin.manifest.id).first)
        for invalid in [JSONValue.number(0), .number(-1), .number(101), .number(12.5), .string("40"), .object([:]), .null] {
            try storage.setValue(invalid, forKey: key, of: plugin.manifest.id)
            actual = 0
            let run = helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services)
            XCTAssertEqual(try run.answer().toast, "Spotify unmuted: 50%.")
            XCTAssertEqual(actual, 50)
            XCTAssertEqual(run.requests.filter { $0.input.value(atPointer: "/operation") == .string("set_volume") }.count, 1)
        }
    }

    func testMuteRefusesMalformedInitialVolumeWithoutAnyStorageOrMutation() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for malformed in [JSONValue.null, .object([:]), .object(["volume": .number(-1)]), .object(["volume": .number(101)]),
                          .object(["volume": .number(0.5)]), .object(["volume": .string("40")])] {
            let run = helper.run(PluginTestInvocation("spotify.mute"), of: plugin,
                answering: RecordedHostServices(operations: ["apps.perform": .value(malformed)]))
            XCTAssertEqual(try run.answer().toast, "Spotify volume could not be read. Mute was not changed.")
            XCTAssertEqual(run.requests.count, 1)
            XCTAssertEqual(run.requests.first?.input.value(atPointer: "/operation"), .string("volume"))
        }
    }

    func testMuteReportsOnlyObservedReadbackAndNeverRetriesAnUnconfirmedEffect() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        for (initial, observed, feedback) in [
            (40, JSONValue.object(["volume": .number(17)]), "Spotify mute change was not confirmed. Current volume: 17%."),
            (0, .object(["volume": .number(0)]), "Spotify mute change was not confirmed. Current volume: 0%."),
            (0, .object(["volume": .number(31)]), "Spotify unmuted: 31%."),
            (40, .null, "Spotify mute request was sent; the current volume could not be confirmed.")
        ] {
            let services = RecordedHostServices(operations: [
                "apps.perform": .answer { input in input.value(atPointer: "/operation") == .string("volume") ? .object(["volume": .number(Double(initial))]) : observed },
                "storage.get": .value(.null), "storage.set": .value(.null)
            ])
            let run = helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services)
            let answer = try run.answer()
            XCTAssertEqual(answer.toast, feedback)
            XCTAssertNil(answer.description)
            XCTAssertEqual(run.requests.filter { $0.input.value(atPointer: "/operation") == .string("set_volume") }.count, 1)
        }
    }

    func testMuteStorageFailureAndNativeFailureAbortWithoutRetryOrSuccess() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let storageFailed = helper.run(PluginTestInvocation("spotify.mute"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": .value(.object(["volume": .number(40)])),
                "storage.set": .failure(.storageLimitExceeded("Storage is full"))]))
        XCTAssertThrowsError(try storageFailed.answer())
        XCTAssertFalse(storageFailed.requests.contains { $0.input.value(atPointer: "/operation") == .string("set_volume") })
        let readFailed = helper.run(PluginTestInvocation("spotify.mute"), of: plugin,
            answering: RecordedHostServices(operations: ["apps.perform": .value(.object(["volume": .number(0)])),
                "storage.get": .failure(.failed("Storage could not be read"))]))
        XCTAssertThrowsError(try readFailed.answer())
        XCTAssertFalse(readFailed.requests.contains { $0.input.value(atPointer: "/operation") == .string("set_volume") })
        for failure in [PluginHostServiceError.appRead(.permissionNeeded), .automationPermissionDenied("Spotify"),
                        .capabilityDenied(.controlExternalApp), .failed("Spotify result unknown")] {
            for failureOnWrite in [false, true] {
                let services = RecordedHostServices(operations: ["apps.perform": .answer { input in
                    if !failureOnWrite || input.value(atPointer: "/operation") == .string("set_volume") { throw failure }
                    return .object(["volume": .number(40)])
                }, "storage.set": .value(.null)])
                let run = helper.run(PluginTestInvocation("spotify.mute"), of: plugin, answering: services)
                XCTAssertThrowsError(try run.answer()) { error in
                    XCTAssertEqual((error as? PluginRuntimeError)?.failureCategory, failure.actionFailureCategory)
                    XCTAssertTrue(String(describing: error).contains(failure.description))
                }
                XCTAssertEqual(run.requests.filter { $0.input.value(atPointer: "/operation") == .string("set_volume") }.count, failureOnWrite ? 1 : 0)
            }
        }
    }

}

extension SpotifyPluginTests {
    func testActionOnlyPackageKeepsSetupOutOfPluginExecution() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        XCTAssertFalse(plugin.manifest.commands.contains { $0.id.rawValue == "spotify.show" })
        XCTAssertEqual(plugin.manifest.capabilities, [.controlExternalApp])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("show.js").path))
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let run = helper.run(PluginTestInvocation("spotify.connect"), of: plugin, answering: RecordedHostServices())
        XCTAssertThrowsError(try run.answer())
        XCTAssertTrue(run.requests.isEmpty, "Connection setup belongs to the Host; no Plugin Command runs")
    }

}

extension SpotifyPluginTests {
    func testRemovedGUIActionRemainsUnavailableAndUserConfigurationIsNotRemapped() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Spotify/spotify-1.1.1-manifest.json")
        let previous = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: fixture))
        let registry = try connectedRegistry()
        let oldGUI = try ActionConfiguration(id: ActionID("existing-gui-action"), pluginID: previous.id,
            command: XCTUnwrap(previous.commands.first { $0.id.rawValue == "spotify.show" }), input: .null)
        let oldControls = try previous.commands.filter { $0.id.rawValue != "spotify.show" }.map {
            try ActionConfiguration(id: ActionID($0.id.rawValue), pluginID: previous.id, command: $0,
                input: $0.id.rawValue == "spotify.volume" ? .string("37") : .null)
        }
        let item = try MenuItemConfiguration(primaryActionID: oldGUI.id, alternateActionIDs: oldControls.map(\.id), alias: "My Spotify")
        let configuration = try HostConfiguration(actions: [oldGUI] + oldControls, menu: MenuConfiguration(items: [item]))
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)
        let current = try PluginUnderTest(packageAt: directory)
        // Historical candidate manifests are retired. Saved Action records still
        // restore against the stable package without rewriting user configuration.
        try registry.register(current.package)
        XCTAssertEqual(editor.configuration, configuration)
        XCTAssertEqual(registry.availability(for: oldGUI), .unavailable(.commandMissing))
        for action in oldControls {
            XCTAssertEqual(registry.availability(for: action),
                action.commandID.rawValue == "spotify.connect" ? .unavailable(.commandMissing) : .available)
        }
        XCTAssertFalse(current.manifest.migrations.renamedCommands.keys.contains(oldGUI.commandID))
    }

    func testEveryActionStaysViewlessAndPassiveEventsNeverConnectOrMutate() throws {
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let services = RecordedHostServices(operations: ["apps.perform": .answer { input in
            switch input.value(atPointer: "/operation") {
            case .string("next_checked"): return .object(["outcome": .string("unconfirmed")])
            case .string("volume"): return .object(["volume": .number(40)])
            case .string("set_volume"), .string("adjust_volume"): return .object(["volume": .number(0)])
            default: return .null
            }
        }], storage: PluginStorage(directory: storageDirectory))
        for command in plugin.manifest.commands {
            let input: JSONValue = command.id.rawValue == "spotify.volume" ? .string("37") : .null
            let called = helper.run(PluginTestInvocation(command.id.rawValue, input: input, event: .called,
                state: .object(["previous": .string("state")])), of: plugin, answering: services)
            let answer = try called.answer()
            XCTAssertNil(answer.description)
            XCTAssertNil(answer.operation)
            XCTAssertNotNil(answer.toast)
            for passiveEvent in [PluginViewEvent.operationFinished(id: "ignored", perform: "apps.perform", outcome: .succeeded),
                                 .sourceDelivered(page: "old-page", source: "playback", sequence: 1, result: .null, failure: nil)] {
                let passive = helper.run(PluginTestInvocation(command.id.rawValue, input: input, event: passiveEvent), of: plugin, answering: services)
                let ignored = try passive.answer()
                XCTAssertNil(ignored.toast)
                XCTAssertNil(ignored.description)
                XCTAssertNil(ignored.operation)
                XCTAssertTrue(passive.requests.isEmpty)
            }
        }
    }
}
