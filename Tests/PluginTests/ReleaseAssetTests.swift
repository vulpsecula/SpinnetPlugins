import Foundation
import XCTest
import SpinnetCore

/// Each asset `script/release_plugins.py` builds is offered and applied as a
/// Plugin Update by the Host's own updater, reading the archive with the
/// Host's real reader. GitHub's answers are recorded; nothing reaches the
/// network unless the opt-in live check is enabled.
final class ReleaseAssetTests: XCTestCase {
    private static let repository = "vulpsecula/SpinnetPlugins"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Runs the release tool's offline build into `out`.
    private func buildAssets(into out: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", root.appendingPathComponent("script/release_plugins.py").path,
                             "build", "--out", out.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: message, as: UTF8.self))
    }

    /// The package as an earlier, lower version that declares the same Update Source.
    private func earlierCopy(of package: URL) throws -> URL {
        let copy = directory.appendingPathComponent("Earlier").appendingPathComponent(package.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: copy)
        let manifestURL = copy.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["version"] = "0.0.0-0"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        return copy
    }

    func testEveryBuiltAssetIsOfferedAndAppliedByTheHostUpdater() throws {
        let assets = directory.appendingPathComponent("dist")
        try buildAssets(into: assets)
        let packages = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Plugins"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "spinnetplugin" }.sorted { $0.path < $1.path }
        XCTAssertEqual(packages.count, 22)

        for package in packages {
            let manifest = try PluginManifestLoader.load(packageAt: package).manifest
            let id = manifest.id.rawValue
            let tag = PluginUpdateSource.releaseTag(for: manifest.id, version: manifest.version)
            let name = PluginUpdateSource.assetName(for: manifest.id)
            XCTAssertEqual(tag, "\(id)/v\(manifest.version)")
            XCTAssertEqual(name, "\(id).spinnetplugin.zip")
            let asset = try Data(contentsOf: assets.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(asset.count, PluginUpdateBudgets.maximumPackageBytes, id)

            let sandbox = directory.appendingPathComponent(id)
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry(grantStore: grants)
            let store = PluginInstallationStore(directory: sandbox.appendingPathComponent("Installed"), registry: registry,
                                                grants: grants, persistGrants: {})
            try store.install(from: earlierCopy(of: package))

            let transport = PublishedReleases()
            let api = "https://api.github.com/repos/\(Self.repository)"
            let download = "https://github.com/\(Self.repository)/releases/download/\(tag)/\(name)"
            transport.answers["\(api)/git/matching-refs/tags/\(id)/v"] = try JSONSerialization.data(
                withJSONObject: [["ref": "refs/tags/\(tag)"]])
            transport.answers["\(api)/releases/tags/\(tag)"] = try JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "draft": false, "prerelease": false,
                "assets": [["name": name, "browser_download_url": download]]
            ] as [String: Any])
            transport.answers[download] = asset
            let updater = PluginUpdater(store: store, registry: registry, transport: transport,
                                        downloads: sandbox.appendingPathComponent("Downloads"))

            let check = try updater.check(manifest.id)
            XCTAssertEqual(check.refusals, [], id)
            let offer = try XCTUnwrap(check.update, id)
            XCTAssertEqual(offer.tag, tag)
            XCTAssertEqual(offer.manifest, manifest, id)

            try updater.apply(offer)
            let installed = try XCTUnwrap(registry.package(for: manifest.id), id)
            XCTAssertEqual(installed.manifest.version, manifest.version, id)
            XCTAssertEqual(try files(in: installed.rootURL), try files(in: package), "\(id): the installed package is the source package")
        }
    }

    /// Opt-in: `SPINNET_LIVE_RELEASE=<plugin-id>` checks the published GitHub
    /// Release of that Plugin over the network with the Host's own updater.
    /// The repository's package is installed as version 0.0.0-0, so the
    /// released version must be offered without refusals, and applying it
    /// must install exactly the repository's package.
    func testOptInLiveReleaseIsOfferedAndAppliedFromGitHub() throws {
        guard let id = ProcessInfo.processInfo.environment["SPINNET_LIVE_RELEASE"], !id.isEmpty else {
            throw XCTSkip("Set SPINNET_LIVE_RELEASE=<plugin-id> to check that Plugin's published release on github.com")
        }
        let packages = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Plugins"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "spinnetplugin" }
        let found = try packages.map { ($0, try PluginManifestLoader.load(packageAt: $0).manifest) }
        let (package, manifest) = try XCTUnwrap(found.first { $0.1.id.rawValue == id }, "No package under Plugins/ has the id \(id)")

        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
                                            grants: grants, persistGrants: {})
        try store.install(from: earlierCopy(of: package))
        let updater = PluginUpdater(store: store, registry: registry, transport: LiveHTTPSTransport(),
                                    downloads: directory.appendingPathComponent("Downloads"))

        let check = try updater.check(manifest.id)
        XCTAssertEqual(check.refusals, [])
        let offer = try XCTUnwrap(check.update, "GitHub offers no release of \(id)")
        XCTAssertEqual(offer.tag, PluginUpdateSource.releaseTag(for: manifest.id, version: manifest.version))
        XCTAssertEqual(offer.manifest, manifest)

        try updater.apply(offer)
        let installed = try XCTUnwrap(registry.package(for: manifest.id))
        XCTAssertEqual(installed.manifest.version, manifest.version)
        XCTAssertEqual(try files(in: installed.rootURL), try files(in: package), "the installed package is the repository's package")
    }

    /// Every file's contents by its path inside `package`.
    private func files(in package: URL) throws -> [String: Data] {
        let base = package.resolvingSymlinksInPath().path + "/"
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }
}

/// GitHub's answers for one published release, by exact URL.
private final class PublishedReleases: HTTPSTransport {
    var answers: [String: Data] = [:]

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        guard let body = answers[request.url.absoluteString] else {
            return HTTPSTransportResponse(status: 404, headers: [:], body: Data())
        }
        return HTTPSTransportResponse(status: 200, headers: [:], body: body)
    }
}

/// A minimal real-network transport honouring `HTTPSTransport`: one request
/// per call on an ephemeral session without cookies, cache or stored
/// credentials, returning a redirect to the Host instead of following it.
/// The Host's own URLSession transport is internal to its app target.
private final class LiveHTTPSTransport: NSObject, HTTPSTransport, URLSessionTaskDelegate {
    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Spinnet"]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let done = DispatchSemaphore(value: 0)
        var answer: (Data?, URLResponse?, Error?)
        let task = session.dataTask(with: urlRequest) { data, response, error in
            answer = (data, response, error)
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + request.timeout) == .success else {
            task.cancel()
            throw HTTPSTransportError.timedOut
        }
        if let error = answer.2 as? URLError, error.code == .timedOut { throw HTTPSTransportError.timedOut }
        guard answer.2 == nil, let response = answer.1 as? HTTPURLResponse else { throw HTTPSTransportError.connectionFailed }
        let body = answer.0 ?? Data()
        guard body.count <= request.maximumResponseBytes else { throw HTTPSTransportError.responseTooLarge }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPSTransportResponse(status: response.statusCode, headers: headers, body: body)
    }

    // The Host decides where a redirect may go.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
