import AppKit
import Darwin
import ExplorerAdapterCore
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@main
@MainActor
enum ExplorerAdapterMain {
    // NSApplication does not retain its delegate, so the status controller needs a process-lifetime owner.
    private static var applicationDelegate: ExplorerAdapterApplicationDelegate?

    static func main() {
        do {
            let paths = AdapterRuntimePaths.stable()
            switch try AdapterInstanceLock.acquire(paths: paths) {
            case .secondary:
                let requestIdentifier = try AdapterInstanceLock.requestControls(paths: paths)
                DistributedNotificationCenter.default().post(
                    name: AdapterInstanceLock.showControlsNotification,
                    object: "com.omiyawaki.osrswiki.explorer-adapter",
                    userInfo: nil
                )
                guard AdapterInstanceLock.waitForControlsAcknowledgement(
                    requestIdentifier: requestIdentifier,
                    paths: paths
                ) else {
                    FileHandle.standardError.write(Data(
                        "OSRS Explorer Adapter primary did not acknowledge the second launch\n".utf8
                    ))
                    Foundation.exit(2)
                }
            case let .primary(instanceLock):
                let delegate = ExplorerAdapterApplicationDelegate(
                    runtimePaths: paths,
                    instanceLock: instanceLock
                )
                applicationDelegate = delegate
                let application = NSApplication.shared
                application.delegate = delegate
                application.setActivationPolicy(.accessory)
                application.run()
            }
        } catch {
            FileHandle.standardError.write(Data("OSRS Explorer Adapter startup failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}

@MainActor
final class ExplorerAdapterApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let runtimePaths: AdapterRuntimePaths
    private let instanceLock: AdapterInstanceLock
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let queueMenuItem = NSMenuItem(title: "Queue: none", action: nil, keyEquivalent: "")
    private let itemMenuItem = NSMenuItem(title: "Item: none", action: nil, keyEquivalent: "")
    private let controlStatusLabel = NSTextField(labelWithString: "Status: STARTING")
    private let controlQueueLabel = NSTextField(labelWithString: "Queue: none")
    private let controlItemLabel = NSTextField(labelWithString: "Item: none")
    private let controlIdentityLabel = NSTextField(labelWithString: "Build: unavailable")
    private let controlInstallLabel = NSTextField(labelWithString: "Install: unavailable")
    private let controlPermissionLabel = NSTextField(labelWithString: "Permissions: checking")
    private let controlWorkerLabel = NSTextField(labelWithString: "Worker: stopped")
    private let controlMenuLabel = NSTextField(labelWithString: "Menu: checking")
    private let launchAtLoginMenuItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin(_:)),
        keyEquivalent: ""
    )
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private var controlWindow: NSWindow?
    private var engine: AdapterEngine?
    private var workerServer: UnixSocketServer?
    private var controlServer: UnixSocketServer?
    private var supervisor: NodeWorkerSupervisor?
    private var touchMonitor: TargetTouchMonitor?
    private var refreshTask: Task<Void, Never>?
    private var evidenceRoot: URL?
    private var workerExpectedRunning = false
    private var runtimeExpectedRunning = false
    private var isTerminating = false
    private var runtimeSocket: URL?
    private var workerConfiguration: NodeWorkerConfiguration?
    private var buildIdentity: AdapterBuildIdentity?
    private var installedPath: String?
    private var workerClosureVerified = false
    private var lastQueueManifestName: String?
    private var showControlsObserver: NSObjectProtocol?
    private var secondLaunchObservationTask: Task<Void, Never>?
    private var controlPanelFallbackTracker = ControlPanelFallbackTracker()
    private let controlHandoffMonitor = FocusInvariantMonitor()
    private let launchAtLoginIntentStore = LaunchAtLoginIntentStore()
    private var stableReleaseValidationState: StableReleaseValidationState = .pending

    init(runtimePaths: AdapterRuntimePaths, instanceLock: AdapterInstanceLock) {
        self.runtimePaths = runtimePaths
        self.instanceLock = instanceLock
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        observeSecondLaunches()
        observeSecondLaunchMarker()
        secondLaunchObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.observeSecondLaunchMarker()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        initializeLaunchAtLoginIntent()
        if controlPanelFallbackTracker.shouldPresent(
            isStartup: true,
            statusItemReportedVisible: statusItem.isVisible,
            permissionsGranted: AdapterPermissions.snapshot().allRequiredGranted,
            terminalRuntimeCondition: false
        ) {
            showControlWindow(nil)
        }
        Task { await startRuntime() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        engine?.invalidateActionsSynchronouslyForTermination()
        workerExpectedRunning = false
        runtimeExpectedRunning = false
        refreshTask?.cancel()
        secondLaunchObservationTask?.cancel()
        touchMonitor?.stop()
        workerServer?.stop()
        controlServer?.stop()
        if let showControlsObserver {
            DistributedNotificationCenter.default().removeObserver(showControlsObserver)
        }
        if let supervisor {
            let stopped = DispatchSemaphore(value: 0)
            Task {
                await supervisor.stop()
                stopped.signal()
            }
            _ = stopped.wait(timeout: .now() + 3)
        }
        instanceLock.release()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard filenames.count == 1 else {
            controlStatusLabel.stringValue = "Queue activation failed: exactly one manifest is required"
            showControlWindow(nil)
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        activateQueueManifest(at: URL(fileURLWithPath: filenames[0])) { succeeded in
            sender.reply(toOpenOrPrint: succeeded ? .success : .failure)
        }
    }

    @objc private func enableAdapter(_ sender: Any?) {
        guard let engine else { return }
        controlWindow?.orderOut(nil)
        Task {
            // Let the control click finish activating this app before choosing
            // the external process that input delivery must restore.
            try? await Task.sleep(for: .milliseconds(150))
            let status = await engine.status()
            guard await prepareExternalForegroundAnchor(status: status) else {
                await engine.operatorEnableFailed(reason: "EXTERNAL_FOREGROUND_ANCHOR_REQUIRED")
                controlWindow?.orderFrontRegardless()
                await refreshStatus()
                return
            }
            await engine.enableFromMenu()
            await refreshStatus()
        }
    }

    @objc private func pauseAdapter(_ sender: Any?) {
        guard let engine else { return }
        Task {
            await engine.pauseByUser()
            await refreshStatus()
        }
    }

    @objc private func activateQueue(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Activate Queue"
        panel.prompt = "Activate"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let manifest = panel.url else { return }
        activateQueueManifest(at: manifest)
    }

    private func activateQueueManifest(
        at manifest: URL,
        completion: ((Bool) -> Void)? = nil
    ) {
        lastQueueManifestName = manifest.lastPathComponent
        guard manifest.isFileURL, manifest.pathExtension.lowercased() == "json" else {
            controlStatusLabel.stringValue = "Queue activation failed: expected one JSON manifest"
            showControlWindow(nil)
            completion?(false)
            return
        }
        guard let engine else {
            controlStatusLabel.stringValue = "Queue activation failed: adapter runtime is not ready"
            showControlWindow(nil)
            completion?(false)
            return
        }

        Task {
            do {
                let digest = try AdapterHashing.sha256(fileAt: manifest)
                let response = await engine.handle(
                    AdapterRequest(
                        method: "queue.activate",
                        queueManifestPath: manifest.path,
                        queueManifestSHA256: digest
                    ),
                    role: .hostUI
                )
                if !response.ok {
                    controlStatusLabel.stringValue = "Queue activation failed: \(response.error ?? "unknown")"
                    showControlWindow(nil)
                }
                completion?(response.ok)
            } catch {
                controlStatusLabel.stringValue = "Queue activation failed: \(error)"
                showControlWindow(nil)
                completion?(false)
            }
            await refreshStatus()
        }
    }

    @objc private func cancelQueue(_ sender: Any?) {
        guard let engine else { return }
        Task {
            let status = await engine.status()
            let response = await engine.handle(
                AdapterRequest(
                    method: "queue.cancel",
                    queueGeneration: status.activeQueueGeneration
                ),
                role: .hostUI
            )
            if !response.ok {
                controlStatusLabel.stringValue = "Queue cancellation failed: \(response.error ?? "unknown")"
                showControlWindow(nil)
            }
            await refreshStatus()
        }
    }

    @objc private func cancelJob(_ sender: Any?) {
        guard let engine else { return }
        Task {
            let status = await engine.status()
            let response = await engine.handle(
                AdapterRequest(
                    method: "job.cancel",
                    jobIdentifier: status.activeItemIdentifier
                ),
                role: .hostUI
            )
            if !response.ok {
                controlStatusLabel.stringValue = "Job cancellation failed: \(response.error ?? "unknown")"
                showControlWindow(nil)
            }
            await refreshStatus()
        }
    }

    @objc private func resumeAdapter(_ sender: Any?) {
        guard let engine else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard runtimeExpectedRunning else {
                await engine.runtimeDidFail(reason: "MANUAL_RESUME_RUNTIME_STOPPED")
                await refreshStatus()
                return
            }
            if let supervisor, await !supervisor.isRunning() {
                guard let workerConfiguration else {
                    await engine.runtimeDidFail(reason: "WORKER_RESTART_CONFIGURATION_MISSING")
                    await refreshStatus()
                    return
                }
                do {
                    try await supervisor.start(workerConfiguration)
                    workerExpectedRunning = true
                } catch {
                    await engine.runtimeDidFail(reason: "WORKER_RESTART_FAILED:\(error)")
                    await refreshStatus()
                    return
                }
            }
            await engine.resumeFromMenu()
            await refreshStatus()
        }
    }

    @objc private func emergencyStop(_ sender: Any?) {
        guard let engine else { return }
        Task {
            await engine.emergencyStop()
            workerExpectedRunning = false
            runtimeExpectedRunning = false
            await supervisor?.stop()
            await refreshStatus()
        }
    }

    @objc private func requestPermissions(_ sender: Any? = nil) {
        _ = AdapterPermissions.requestScreenRecording()
        AdapterPermissions.requestAccessibilityPrompt()
        _ = AdapterPermissions.requestInputMonitoring()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        let desired = !launchAtLoginIntentStore.desired
        launchAtLoginIntentStore.setDesired(desired)
        reconcileLaunchAtLoginIntent()
    }

    @objc private func openEvidenceFolder(_ sender: Any?) {
        guard let evidenceRoot else { return }
        NSWorkspace.shared.open(evidenceRoot)
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showControlWindow(_ sender: Any?) {
        if controlWindow == nil {
            controlWindow = makeControlWindow()
        }
        controlWindow?.orderFrontRegardless()
    }

    private func configureMenu() {
        statusItem.autosaveName = "com.omiyawaki.osrswiki.explorer-adapter.status-item"
        statusItem.isVisible = true
        if let image = NSImage(
            systemSymbolName: "map",
            accessibilityDescription: "OSRS Explorer Adapter"
        ) {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "E"
        }
        statusItem.button?.setAccessibilityLabel("Explorer: STARTING")
        statusItem.button?.toolTip = "OSRS Explorer Adapter: STARTING"
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        statusMenu.addItem(statusMenuItem)
        statusMenu.addItem(queueMenuItem)
        statusMenu.addItem(itemMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(item("Enable", action: #selector(enableAdapter(_:))))
        statusMenu.addItem(item("Pause", action: #selector(pauseAdapter(_:))))
        statusMenu.addItem(item("Resume (manual)", action: #selector(resumeAdapter(_:))))
        statusMenu.addItem(item("Emergency Stop", action: #selector(emergencyStop(_:))))
        statusMenu.addItem(.separator())
        statusMenu.addItem(item("Activate Queue...", action: #selector(activateQueue(_:))))
        statusMenu.addItem(item("Cancel Queue", action: #selector(cancelQueue(_:))))
        statusMenu.addItem(item("Cancel Current Job", action: #selector(cancelJob(_:))))
        statusMenu.addItem(.separator())
        statusMenu.addItem(item("Request Permissions", action: #selector(requestPermissions(_:))))
        launchAtLoginMenuItem.target = self
        statusMenu.addItem(launchAtLoginMenuItem)
        statusMenu.addItem(item("Show Controls", action: #selector(showControlWindow(_:))))
        statusMenu.addItem(item("Open Evidence Folder", action: #selector(openEvidenceFolder(_:))))
        statusMenu.addItem(.separator())
        statusMenu.addItem(item("Quit", action: #selector(quit(_:))))
        statusItem.menu = statusMenu
        refreshLaunchAtLoginControls()
    }

    private func observeSecondLaunches() {
        showControlsObserver = DistributedNotificationCenter.default().addObserver(
            forName: AdapterInstanceLock.showControlsNotification,
            object: "com.omiyawaki.osrswiki.explorer-adapter",
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.observeSecondLaunchMarker()
            }
        }
    }

    private func observeSecondLaunchMarker() {
        if let acknowledged = try? instanceLock.acknowledgeControlsRequests(paths: runtimePaths),
           !acknowledged.isEmpty {
            showControlWindow(nil)
        }
    }

    private func initializeLaunchAtLoginIntent() {
        launchAtLoginIntentStore.initialize()
    }

    private func reconcileLaunchAtLoginIntent() {
        guard LaunchAtLoginStartupPolicy.permitsReconciliation(
            validationState: stableReleaseValidationState
        ) else {
            refreshLaunchAtLoginControls()
            return
        }
        let desired = launchAtLoginIntentStore.desired
        let action = LaunchAtLoginPolicy.reconcile(
            desired: desired,
            status: launchAtLoginServiceState()
        )
        do {
            switch action {
            case .none:
                break
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            case .awaitApproval:
                controlWorkerLabel.stringValue = "Login item requires approval in System Settings"
                showControlWindow(nil)
            case .reportUnknown:
                controlWorkerLabel.stringValue = "Login item status is unsupported"
                showControlWindow(nil)
            }
        } catch {
            controlWorkerLabel.stringValue = "Login item reconciliation failed: \(error)"
            showControlWindow(nil)
        }
        refreshLaunchAtLoginControls()
    }

    private func refreshLaunchAtLoginControls() {
        let desired = launchAtLoginIntentStore.desired
        launchAtLoginMenuItem.state = desired ? .on : .off
        launchAtLoginButton.state = desired ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        controlPanelFallbackTracker.confirmStatusItemReachability()
        Task { @MainActor [weak self] in
            await self?.refreshStatus()
            menu.update()
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeControlWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "OSRS Explorer Adapter Controls"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.becomesKeyOnlyIfNeeded = true

        for label in [
            controlStatusLabel,
            controlQueueLabel,
            controlItemLabel,
            controlIdentityLabel,
            controlInstallLabel,
            controlPermissionLabel,
            controlWorkerLabel,
            controlMenuLabel
        ] {
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
        }
        controlStatusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)

        let enable = NSButton(title: "Enable", target: self, action: #selector(enableAdapter(_:)))
        let pause = NSButton(title: "Pause", target: self, action: #selector(pauseAdapter(_:)))
        let resume = NSButton(title: "Resume", target: self, action: #selector(resumeAdapter(_:)))
        let stop = NSButton(title: "Emergency Stop", target: self, action: #selector(emergencyStop(_:)))
        stop.hasDestructiveAction = true
        let activateQueue = NSButton(
            title: "Activate Queue...",
            target: self,
            action: #selector(activateQueue(_:))
        )
        let cancelQueue = NSButton(
            title: "Cancel Queue",
            target: self,
            action: #selector(cancelQueue(_:))
        )
        let cancelJob = NSButton(
            title: "Cancel Job",
            target: self,
            action: #selector(cancelJob(_:))
        )
        let permissions = NSButton(
            title: "Request Permissions",
            target: self,
            action: #selector(requestPermissions(_:))
        )
        let evidence = NSButton(
            title: "Open Evidence Folder",
            target: self,
            action: #selector(openEvidenceFolder(_:))
        )
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin(_:))

        let primaryActions = NSStackView(views: [enable, pause, resume, stop])
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 8
        primaryActions.distribution = .fillEqually
        let queueActions = NSStackView(views: [activateQueue, cancelQueue, cancelJob])
        queueActions.orientation = .horizontal
        queueActions.spacing = 8
        queueActions.distribution = .fillEqually
        let secondaryActions = NSStackView(views: [permissions, evidence])
        secondaryActions.orientation = .horizontal
        secondaryActions.spacing = 8
        secondaryActions.distribution = .fillEqually

        let content = NSStackView(views: [
            controlStatusLabel,
            controlQueueLabel,
            controlItemLabel,
            controlIdentityLabel,
            controlInstallLabel,
            controlPermissionLabel,
            controlWorkerLabel,
            controlMenuLabel,
            launchAtLoginButton,
            primaryActions,
            queueActions,
            secondaryActions
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            primaryActions.widthAnchor.constraint(equalTo: content.widthAnchor),
            queueActions.widthAnchor.constraint(equalTo: content.widthAnchor),
            secondaryActions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.center()
        return window
    }

    private func prepareExternalForegroundAnchor(status: AdapterStatus) async -> Bool {
        let adapterProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let forbiddenBundleIdentifiers = Set([
            Bundle.main.bundleIdentifier,
            "com.jagex.osclient",
            "com.omiyawaki.osrswiki.explorer-adapter-lab-target"
        ].compactMap { $0 })
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != adapterProcessIdentifier,
           frontmost.activationPolicy == .regular,
           !forbiddenBundleIdentifiers.contains(frontmost.bundleIdentifier ?? "") {
            return true
        }

        controlWindow?.orderOut(nil)
        let snapshot = controlHandoffMonitor.snapshot(
            targetWindowIdentifier: status.target?.windowIdentifier ?? 0
        )
        let candidates = ControlEnableHandoffPolicy.candidateProcessIdentifiers(
            snapshot: snapshot,
            excluding: [adapterProcessIdentifier]
        )
        guard let application = candidates.lazy.compactMap({ processIdentifier in
            NSRunningApplication(processIdentifier: processIdentifier)
        }).first(where: { application in
            !application.isTerminated
                && application.activationPolicy == .regular
                && !forbiddenBundleIdentifiers.contains(application.bundleIdentifier ?? "")
        }), application.activate(options: [.activateAllWindows]) else {
            return false
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func startRuntime() async {
        do {
            let configuration = try ApplicationConfiguration.load()
            stableReleaseValidationState = .validated
            reconcileLaunchAtLoginIntent()
            evidenceRoot = configuration.evidenceRoot
            buildIdentity = configuration.buildIdentity
            installedPath = configuration.installPath
            workerClosureVerified = true
            runtimeSocket = runtimePaths.socket
            let capabilities = try CapabilityStore.createFresh(
                at: runtimePaths,
                ownedBy: instanceLock
            )
            let engine = AdapterEngine(
                capabilities: capabilities,
                evidenceRoot: configuration.evidenceRoot
            )
            await engine.prepare()
            self.engine = engine
            guard !isTerminating else {
                engine.invalidateActionsSynchronouslyForTermination()
                return
            }
            let workerServer = UnixSocketServer(path: runtimePaths.socket.path)
            try workerServer.start { request in
                await engine.handle(request, role: .worker)
            }
            self.workerServer = workerServer
            let peerValidator = DesignatedCLIPeerValidator(
                expectedExecutablePath: configuration.controlExecutable,
                expectedCertificateSHA256: configuration.buildIdentity.signingCertificateSHA256
            )
            let controlServer = UnixSocketServer(
                path: runtimePaths.controlSocket.path,
                peerValidator: { peerValidator.accepts($0) }
            )
            try controlServer.start { request in
                await engine.handle(request, role: .control)
            }
            self.controlServer = controlServer
            let supervisor = NodeWorkerSupervisor()
            self.supervisor = supervisor
            let workerConfiguration = NodeWorkerConfiguration(
                nodeExecutable: configuration.nodeExecutable,
                workerEntryPoint: configuration.workerEntryPoint,
                socketPath: runtimePaths.socket.path,
                workerCapability: capabilities.worker,
                logDirectory: configuration.evidenceRoot.appendingPathComponent("worker-logs"),
                expectedRuntimeIdentity: configuration.runtimeIdentity
            )
            self.workerConfiguration = workerConfiguration
            _ = try EvidenceStore(root: configuration.evidenceRoot).writeImmutable(
                configuration.runtimeIdentity,
                relativePath: "runtime-identity/\(UUID().uuidString.lowercased()).json"
            )
            try await supervisor.start(workerConfiguration)
            guard !isTerminating else {
                await supervisor.stop()
                return
            }
            workerExpectedRunning = true
            runtimeExpectedRunning = true
            let monitor = TargetTouchMonitor(engine: engine)
            monitor.start()
            touchMonitor = monitor
            refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.refreshStatus()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            await refreshStatus()
        } catch {
            if case .pending = stableReleaseValidationState {
                stableReleaseValidationState = .rejected
            }
            engine?.invalidateActionsSynchronouslyForTermination()
            workerServer?.stop()
            controlServer?.stop()
            await supervisor?.stop()
            guard !isTerminating else { return }
            statusItem.button?.setAccessibilityLabel("Explorer: FAULTED")
            statusItem.button?.toolTip = "OSRS Explorer Adapter: FAULTED"
            statusMenuItem.title = "Startup failed: \(error)"
            controlStatusLabel.stringValue = "Startup failed: \(error)"
            showControlWindow(nil)
        }
    }

    private func refreshStatus() async {
        guard let engine else { return }
        observeSecondLaunchMarker()
        await engine.refreshPermissionState()
        if runtimeExpectedRunning,
           let runtimeSocket,
           (!FileManager.default.fileExists(atPath: runtimeSocket.path)
            || !FileManager.default.fileExists(atPath: runtimePaths.controlSocket.path)) {
            runtimeExpectedRunning = false
            workerExpectedRunning = false
            await engine.runtimeDidFail(reason: "CONTROL_SOCKET_MISSING")
            await supervisor?.stop()
        }
        if workerExpectedRunning,
           let supervisor,
           await !supervisor.isRunning() {
            workerExpectedRunning = false
            await engine.workerDidTerminate(status: await supervisor.lastTerminationStatus)
        }
        let initialStatus = await engine.status()
        let workerHealthy = if let supervisor { await supervisor.isRunning() } else { false }
        let workerProcessIdentifier: Int32? = if let supervisor {
            await supervisor.processIdentifier()
        } else {
            nil
        }
        let menuVisible = statusItem.isVisible
        let loginRegistered = SMAppService.mainApp.status == .enabled
        let hostStatus = AdapterHostStatus(
            instanceIdentifier: instanceLock.instanceIdentifier,
            buildIdentity: buildIdentity,
            installPath: installedPath,
            menuVisible: menuVisible,
            loginItemRegistered: loginRegistered,
            loginItemState: loginItemState(),
            workerProcessIdentifier: workerProcessIdentifier,
            workerHealthy: workerHealthy,
            inFlightPhase: initialStatus.activeItemIdentifier == nil
                ? nil
                : (await engine.isForegroundLeaseActive() ? "input" : "claimed")
        )
        let diagnostics = AdapterDiagnostics(
            runtimeRoot: runtimePaths.root.path,
            socketPath: runtimePaths.socket.path,
            lockPath: runtimePaths.lock.path,
            socketPresent: FileManager.default.fileExists(atPath: runtimePaths.socket.path),
            lockHeld: instanceLock.owns(paths: runtimePaths),
            targetWindowBound: initialStatus.target != nil,
            workerClosureVerified: workerClosureVerified
        )
        await engine.updateHostStatus(hostStatus, diagnostics: diagnostics)
        let status = await engine.status()
        statusItem.button?.setAccessibilityLabel("Explorer: \(status.state.rawValue)")
        statusItem.button?.toolTip = "OSRS Explorer Adapter: \(status.state.rawValue)"
        statusMenuItem.title = "Status: \(status.state.rawValue)"
        queueMenuItem.title = "Queue: \(status.activeQueueGeneration ?? "none")"
        itemMenuItem.title = "Item: \(status.activeItemIdentifier ?? "none")"
        let queueAttempt = lastQueueManifestName.map { " Queue file: \($0)" } ?? ""
        let queueError = status.lastError.map { " Error: \($0)" } ?? ""
        controlStatusLabel.stringValue = statusMenuItem.title + queueAttempt + queueError
        controlQueueLabel.stringValue = queueMenuItem.title
        controlItemLabel.stringValue = itemMenuItem.title
        if let build = status.host.buildIdentity {
            controlIdentityLabel.stringValue = "Build: \(build.version) (\(build.buildNumber)) \(build.cdHash)"
        } else {
            controlIdentityLabel.stringValue = "Build: unavailable"
        }
        controlInstallLabel.stringValue = "Install: \(status.host.installPath ?? "unavailable")"
        controlPermissionLabel.stringValue = "Permissions: screen=\(status.permissions.screenRecording) accessibility=\(status.permissions.accessibility) input=\(status.permissions.inputMonitoring)"
        controlWorkerLabel.stringValue = "Worker: \(status.host.workerHealthy ? "healthy" : "stopped") pid=\(status.host.workerProcessIdentifier.map(String.init) ?? "none") phase=\(status.host.inFlightPhase ?? "idle")"
        controlMenuLabel.stringValue = "Menu: \(status.host.menuVisible ? "visible" : "hidden") | Login: \(status.host.loginItemState)"
        refreshLaunchAtLoginControls()
        if controlPanelFallbackTracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: status.host.menuVisible,
            permissionsGranted: status.permissions.allRequiredGranted,
            terminalRuntimeCondition: ControlPanelFallbackPolicy.isTerminalRuntimeCondition(
                status.state
            )
        ), controlWindow?.isVisible != true {
            showControlWindow(nil)
        }
    }

    private func loginItemState() -> String {
        launchAtLoginServiceState().rawValue
    }

    private func launchAtLoginServiceState() -> LaunchAtLoginServiceState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        case .requiresApproval: .requiresApproval
        @unknown default: .unknown
        }
    }
}

private struct ApplicationConfiguration {
    let evidenceRoot: URL
    let nodeExecutable: URL
    let workerEntryPoint: URL
    let controlExecutable: URL
    let runtimeIdentity: WorkerRuntimeIdentity
    let buildIdentity: AdapterBuildIdentity
    let installPath: String

    static func load() throws -> ApplicationConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let forbiddenOverrides = [
            "OSRS_ADAPTER_RUNTIME_ROOT",
            "OSRS_ADAPTER_ARTIFACT_ROOT",
            "OSRS_ADAPTER_NODE",
            "OSRS_ADAPTER_WORKER",
            "OSRS_ADAPTER_BUNDLE_ID"
        ]
        guard forbiddenOverrides.allSatisfy({ environment[$0] == nil }) else {
            throw AdapterError.backgroundUnsupported("RUNTIME_OVERRIDE_FORBIDDEN")
        }
        let expectedInstall = home.appendingPathComponent(
            "Applications/OSRS Explorer Adapter.app",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let actualInstall = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard actualInstall == expectedInstall else {
            throw AdapterError.backgroundUnsupported("STABLE_INSTALL_PATH_REQUIRED:\(actualInstall.path)")
        }
        guard let resources = Bundle.main.resourceURL else {
            throw AdapterError.backgroundUnsupported("NODE_WORKER_PATH_REQUIRED")
        }
        let nodeExecutable = resources.appendingPathComponent("node/bin/node")
        let workerRoot = resources.appendingPathComponent("node-worker", isDirectory: true)
        let workerEntryPoint = workerRoot.appendingPathComponent("src/worker.mjs")
        let controlExecutable = actualInstall
            .appendingPathComponent("Contents/MacOS/osrs-explorerctl")
        guard FileManager.default.isExecutableFile(atPath: controlExecutable.path) else {
            throw AdapterError.backgroundUnsupported("BUNDLED_CONTROL_UTILITY_REQUIRED")
        }
        let closureManifest = resources.appendingPathComponent("WORKER_RUNTIME_CLOSURE.json")
        try verifyBundleSignature()
        let buildIdentity = try AdapterReleaseIdentityReader.read(bundle: .main)
        let runtimeIdentity = try WorkerRuntimeIdentityVerifier.verify(
            nodeExecutable: nodeExecutable,
            workerRoot: workerRoot,
            workerEntryPoint: workerEntryPoint,
            closureManifest: closureManifest
        )
        return ApplicationConfiguration(
            evidenceRoot: home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("OSRS Explorer Adapter", isDirectory: true)
                .appendingPathComponent("evidence", isDirectory: true),
            nodeExecutable: nodeExecutable,
            workerEntryPoint: workerEntryPoint,
            controlExecutable: controlExecutable,
            runtimeIdentity: runtimeIdentity,
            buildIdentity: buildIdentity,
            installPath: actualInstall.path
        )
    }

    private static func verifyBundleSignature() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "--deep", Bundle.main.bundleURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AdapterError.backgroundUnsupported("BUNDLE_SIGNATURE_INVALID:\(detail)")
        }
    }
}

@MainActor
private final class TargetTouchMonitor {
    private let engine: AdapterEngine
    private let foregroundInterferenceRegistry: ForegroundInterferenceRegistry
    private var activationObserver: NSObjectProtocol?
    private var mouseMonitor: Any?

    init(engine: AdapterEngine) {
        self.engine = engine
        foregroundInterferenceRegistry = engine.foregroundInterferenceRegistry
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let adapterLeaseWasActive = self?.foregroundInterferenceRegistry.hasActiveLease() == true
            Task { @MainActor in
                await self?.applicationActivated(
                    application,
                    adapterLeaseWasActive: adapterLeaseWasActive
                )
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .mouseMoved,
                .scrollWheel,
                .keyDown
            ]
        ) { [weak self] event in
            if let cgEvent = event.cgEvent {
                let sourceProcessIdentifier = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
                guard cgEvent.getIntegerValueField(.eventSourceUserData) != osrsAdapterEventTag,
                      sourceProcessIdentifier != Int64(getpid()) else { return }
            }
            let type = event.type.rawValue
            let point = event.cgEvent?.location
            let reason = "USER_INPUT_DURING_FOREGROUND_LEASE:\(type)"
            if self?.foregroundInterferenceRegistry.invalidateActive(reason: reason) == true {
                Task { await self?.engine.pauseForUserInterference(reason: reason) }
                return
            }
            Task { @MainActor in await self?.externalInput(type: type, point: point) }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        activationObserver = nil
        mouseMonitor = nil
    }

    private func applicationActivated(
        _ application: NSRunningApplication,
        adapterLeaseWasActive: Bool
    ) async {
        let status = await engine.status()
        if adapterLeaseWasActive {
            guard foregroundInterferenceRegistry.hasActiveInputEmission(),
                  status.target?.processIdentifier != application.processIdentifier else { return }
            let reason = "NON_TARGET_ACTIVATED_DURING_FOREGROUND_INPUT:\(application.processIdentifier)"
            if foregroundInterferenceRegistry.invalidateActive(reason: reason) {
                await engine.pauseForUserInterference(reason: reason)
            }
            return
        }
        guard status.target?.processIdentifier == application.processIdentifier else { return }
        await engine.pauseForTargetTouch(reason: "TARGET_ACTIVATED_BY_USER")
    }

    private func externalInput(type: UInt, point: CGPoint?) async {
        let mouseDownTypes = [
            NSEvent.EventType.leftMouseDown.rawValue,
            NSEvent.EventType.rightMouseDown.rawValue,
            NSEvent.EventType.otherMouseDown.rawValue
        ]
        guard mouseDownTypes.contains(type), let point else { return }
        let status = await engine.status()
        guard let target = status.target,
              target.frame.cgRect.contains(point),
              WindowHitTester.topmostProcessIdentifier(at: point) == target.processIdentifier else {
            return
        }
        await engine.pauseForTargetTouch(reason: "TARGET_TOUCHED_BY_USER")
    }
}
