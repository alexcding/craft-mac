import AppKit
import Security

/// Craft is now Cascade: the same app under a new name and bundle identifier, which Sparkle cannot
/// update into. This last Craft release installs Cascade itself, quits, and opens it once Craft has
/// exited. Cascade carries Craft's data across on its first launch, so Craft must never open that
/// data again: once Cascade is installed, opening Craft only opens Cascade.
@MainActor
final class CascadeHandoff {
    nonisolated static let bundleIdentifier = "com.alexcding.cascade"
    nonisolated static let feed = URL(string: "https://github.com/alexcding/cascade-mac/releases/latest/download/appcast.xml")!
    nonisolated static let releases = URL(string: "https://github.com/alexcding/cascade-mac/releases/latest")!

    private let team: String
    private var panel: NSPanel?
    private var task: Task<Void, Never>?

    /// Only a packaged, Developer ID–signed Craft hands off: the team it was signed by is the team
    /// Cascade must be signed by. A build from Xcode has neither and runs as it always has.
    static func current(bundle: Bundle = .main) -> CascadeHandoff? {
        guard PackagedBundle.isPackaged(bundle.bundleURL), let team = signingTeam() else { return nil }
        return CascadeHandoff(team: team)
    }

    private init(team: String) { self.team = team }

    /// Opens an installed Cascade, or offers to install it. `continueWithCraft` finishes Craft's own
    /// launch when the user puts the move off or it cannot be done.
    func begin(continueWithCraft: @escaping @MainActor () -> Void) {
        if let installed = installedCascade() { quit(openingAfterwards: installed); return }
        let alert = NSAlert()
        alert.messageText = "Craft is now Cascade"
        alert.informativeText = """
            Cascade is the same app under a new name, and it gets the updates from now on. \
            It installs next to Craft and brings your projects, sessions and settings with it.

            Craft quits, and Cascade opens in its place.
            """
        alert.addButton(withTitle: "Install Cascade")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { continueWithCraft(); return }
        showProgress()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let cascade = try await self.install()
                self.closeProgress()
                self.quit(openingAfterwards: cascade)
            } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.closeProgress()
                continueWithCraft()
            } catch {
                self.closeProgress()
                self.failed(error, continueWithCraft: continueWithCraft)
            }
        }
    }

    // MARK: - Installing

    private func install() async throws -> URL {
        let (feedData, _) = try await URLSession.shared.data(from: Self.feed)
        guard let archive = Self.archiveURL(inAppcast: feedData) else { throw HandoffError.noArchive }
        let (download, _) = try await URLSession.shared.download(from: archive)
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let unpacked = fileManager.temporaryDirectory.appendingPathComponent("cascade-handoff-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: unpacked) }
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", download.path, unpacked.path])
        try? fileManager.removeItem(at: download)
        let app = unpacked.appendingPathComponent("Cascade.app")
        try Self.verify(app, team: team)
        try Task.checkCancellation()

        let destination = try Self.installFolder().appendingPathComponent("Cascade.app")
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: app)
        } else {
            try fileManager.moveItem(at: app, to: destination)
        }
        return destination
    }

    /// Next to Craft when that folder can be written, which is `/Applications` for nearly everyone.
    nonisolated static func installFolder(besides bundle: URL = Bundle.main.bundleURL,
                              fileManager: FileManager = .default) throws -> URL {
        let candidates = [bundle.deletingLastPathComponent(), URL(fileURLWithPath: "/Applications"),
                          fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for folder in candidates where fileManager.isWritableFile(atPath: folder.path) { return folder }
        let personal = candidates[2]
        try fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        return personal
    }

    /// A Cascade already installed and signed by this team, wherever Launch Services found it.
    private func installedCascade() -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return nil }
        return (try? Self.verify(url, team: team)) == nil ? nil : url
    }

    // MARK: - Leaving

    /// Leaves without the quit contract: nothing was started, and that contract stops the terminal
    /// daemon, which Cascade shares with Craft and may be using right now. Cascade opens only once
    /// this process has gone, since it gives way to a Craft that is still running and carries its
    /// data only once Craft has quit.
    private func quit(openingAfterwards cascade: URL) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            running.activate()
            exit(0)
        }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Detached so it outlives Craft, which exits straight after starting it.
        waiter.arguments = ["-c", """
            (while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; /usr/bin/open "$2") >/dev/null 2>&1 &
            """, "sh", String(ProcessInfo.processInfo.processIdentifier), cascade.path]
        do {
            try waiter.run()
            waiter.waitUntilExit()
        } catch {
            // Without the waiter, show Cascade where it was installed and let the user open it.
            NSWorkspace.shared.activateFileViewerSelecting([cascade])
        }
        exit(0)
    }

    private func failed(_ error: Error, continueWithCraft: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Cascade could not be installed"
        alert.informativeText = "\(error.localizedDescription)\n\nYou can download it yourself and open it; it brings your data across on its own."
        alert.addButton(withTitle: "Download Cascade")
        alert.addButton(withTitle: "Continue with Craft")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releases) }
        continueWithCraft()
    }

    // MARK: - Progress

    private func showProgress() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Installing Cascade…")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelInstall))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [spinner, label, cancel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Craft"
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    @objc private func cancelInstall() { task?.cancel() }

    private func closeProgress() {
        panel?.close()
        panel = nil
    }

    // MARK: - Pure parts

    /// The newest update archive a Sparkle appcast names: the first enclosure, as the feed lists newest first.
    nonisolated static func archiveURL(inAppcast data: Data) -> URL? {
        let reader = EnclosureReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// Apple-anchored, Cascade's identifier, and a leaf certificate issued to this app's own team.
    nonisolated static func requirement(team: String) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    nonisolated static func verify(_ app: URL, team: String) throws {
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement(team: team) as CFString, [], &rule) == errSecSuccess,
              let rule else { throw HandoffError.untrusted }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, rule) == errSecSuccess else { throw HandoffError.untrusted }
    }

    /// The team identifier in this running app's signature, or nil for an ad-hoc build.
    nonisolated static func signingTeam() -> String? {
        var own: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw HandoffError.unpack }
        }.value
    }
}

enum HandoffError: LocalizedError {
    case noArchive, unpack, untrusted

    var errorDescription: String? {
        switch self {
        case .noArchive: "Cascade's update feed names no download."
        case .unpack: "The Cascade download could not be unpacked."
        case .untrusted: "The download is not a Cascade signed by the same developer as Craft."
        }
    }
}

private final class EnclosureReader: NSObject, XMLParserDelegate {
    var url: String?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "enclosure", url == nil, let found = attributes["url"] else { return }
        url = found
        parser.abortParsing()
    }
}
