import AppKit
import CoreGraphics
import Darwin
import ExplorerAdapterCore
import Foundation

@main
enum ExplorerAdapterLabMain {
    static func main() {
        let application = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())
        let delegate: NSApplicationDelegate
        if arguments.contains("--cover") || Bundle.main.bundleIdentifier?.hasSuffix(".cover") == true {
            delegate = LabCoverDelegate(
                eventLogURL: option("--activate-after-event-log", in: arguments).map {
                    URL(fileURLWithPath: $0)
                },
                eventKind: option("--activate-after-kind", in: arguments)
            )
        } else {
            let logPath = option("--log", in: arguments)
                ?? "/tmp/osrs-explorer-adapter-lab-events.jsonl"
            delegate = LabTargetDelegate(logURL: URL(fileURLWithPath: logPath))
        }
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

@MainActor
private final class LabTargetDelegate: NSObject, NSApplicationDelegate {
    private let recorder: LabEventRecorder
    private var window: NSWindow?
    private var canvas: LabCanvasView?

    init(logURL: URL) {
        recorder = LabEventRecorder(url: logURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 240, y: 180, width: 640, height: 480)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Explorer Adapter Lab Target"
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        let button = NSButton(title: "Foreground Click Target", target: self, action: #selector(buttonPressed))
        button.identifier = NSUserInterfaceItemIdentifier("foreground-click-target")
        button.frame = NSRect(x: 28, y: 408, width: 220, height: 36)
        root.addSubview(button)

        let label = NSTextField(labelWithString: "Bounded focus-lease click and drag laboratory")
        label.textColor = .white
        label.frame = NSRect(x: 278, y: 415, width: 330, height: 24)
        root.addSubview(label)

        let canvas = LabCanvasView(
            frame: NSRect(x: 28, y: 28, width: 584, height: 350),
            recorder: recorder
        )
        root.addSubview(canvas)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.canvas = canvas
        recorder.record(kind: "target_started", event: nil, visualState: canvas.visualState)
    }

    @objc private func buttonPressed() {
        canvas?.visualState += 1
        canvas?.needsDisplay = true
        recorder.record(kind: "ax_button_press", event: NSApp.currentEvent, visualState: canvas?.visualState ?? 0)
    }
}

@MainActor
private final class LabCoverDelegate: NSObject, NSApplicationDelegate {
    private let eventLogURL: URL?
    private let eventKind: String?
    private var window: NSWindow?
    private var activationTask: Task<Void, Never>?

    init(eventLogURL: URL?, eventKind: String?) {
        self.eventLogURL = eventLogURL
        self.eventKind = eventKind
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 220, y: 160, width: 680, height: 520)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Explorer Adapter Opaque Cover and Typing Surface"
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.17, blue: 0.23, alpha: 1)
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let label = NSTextField(labelWithString: "Foreground typing surface")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 30, y: 450, width: 400, height: 30)
        root.addSubview(label)
        let scroll = NSScrollView(frame: NSRect(x: 30, y: 35, width: 620, height: 390))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = "Prior foreground surface restored after each bounded target action.\n"
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        scroll.documentView = textView
        root.addSubview(scroll)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
        startActivationWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        activationTask?.cancel()
    }

    private func startActivationWatcher() {
        guard let eventLogURL, let eventKind else { return }
        let armedAt = AdapterClock.now()
        activationTask = Task { @MainActor [weak self] in
            let decoder = JSONDecoder()
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: eventLogURL) {
                    for line in data.split(separator: 0x0A) {
                        guard let record = try? decoder.decode(LabEventRecord.self, from: Data(line)),
                              record.kind == eventKind,
                              record.recordedAt >= armedAt else { continue }
                        self?.window?.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

@MainActor
private final class LabCanvasView: NSView {
    private let recorder: LabEventRecorder
    var visualState = 0
    private var lastPoint: NSPoint?
    private var dragActive = false

    init(frame: NSRect, recorder: LabEventRecorder) {
        self.recorder = recorder
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragActive = true
        visualState += 1
        lastPoint = convert(event.locationInWindow, from: nil)
        recorder.record(
            kind: "left_mouse_down",
            event: event,
            visualState: visualState,
            dragActive: dragActive
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        visualState += 1
        lastPoint = convert(event.locationInWindow, from: nil)
        recorder.record(
            kind: "left_mouse_dragged",
            event: event,
            visualState: visualState,
            dragActive: dragActive
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragActive = false
        visualState += 1
        lastPoint = convert(event.locationInWindow, from: nil)
        recorder.record(
            kind: "left_mouse_up",
            event: event,
            visualState: visualState,
            dragActive: dragActive
        )
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        visualState += 1
        lastPoint = convert(event.locationInWindow, from: nil)
        recorder.record(kind: "right_mouse_down", event: event, visualState: visualState)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        visualState += 1
        lastPoint = convert(event.locationInWindow, from: nil)
        recorder.record(kind: "right_mouse_up", event: event, visualState: visualState)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hue = CGFloat(visualState % 12) / 12
        NSColor(calibratedHue: hue, saturation: 0.48, brightness: 0.62, alpha: 1).setFill()
        dirtyRect.fill()
        let text = "Visual state \(visualState)"
        text.draw(
            at: NSPoint(x: 18, y: bounds.height - 38),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.white
            ]
        )
        if let lastPoint {
            NSColor.white.setStroke()
            let horizontal = NSBezierPath()
            horizontal.move(to: NSPoint(x: lastPoint.x - 12, y: lastPoint.y))
            horizontal.line(to: NSPoint(x: lastPoint.x + 12, y: lastPoint.y))
            horizontal.stroke()
            let vertical = NSBezierPath()
            vertical.move(to: NSPoint(x: lastPoint.x, y: lastPoint.y - 12))
            vertical.line(to: NSPoint(x: lastPoint.x, y: lastPoint.y + 12))
            vertical.stroke()
        }
    }
}

private struct LabEventRecord: Codable {
    let schemaVersion: Int
    let recordedAt: String
    let kind: String
    let processIdentifier: Int32
    let appIsActive: Bool
    let windowNumber: Int?
    let eventLocation: AdapterPoint?
    let screenCursor: AdapterPoint
    let eventType: UInt?
    let eventTag: Int64?
    let visualState: Int
    let dragActive: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordedAt = "recorded_at"
        case kind
        case processIdentifier = "process_id"
        case appIsActive = "app_is_active"
        case windowNumber = "window_number"
        case eventLocation = "event_location"
        case screenCursor = "screen_cursor"
        case eventType = "event_type"
        case eventTag = "event_tag"
        case visualState = "visual_state"
        case dragActive = "drag_active"
    }
}

@MainActor
private final class LabEventRecorder {
    private let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    func record(kind: String, event: NSEvent?, visualState: Int, dragActive: Bool = false) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let location = event.map { AdapterPoint(x: $0.locationInWindow.x, y: $0.locationInWindow.y) }
        let record = LabEventRecord(
            schemaVersion: 1,
            recordedAt: AdapterClock.now(),
            kind: kind,
            processIdentifier: getpid(),
            appIsActive: NSApp.isActive,
            windowNumber: event?.windowNumber,
            eventLocation: location,
            screenCursor: AdapterPoint(x: cursor.x, y: cursor.y),
            eventType: event.map { UInt($0.type.rawValue) },
            eventTag: event?.cgEvent?.getIntegerValueField(.eventSourceUserData),
            visualState: visualState,
            dragActive: dragActive
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        data.append(0x0A)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
