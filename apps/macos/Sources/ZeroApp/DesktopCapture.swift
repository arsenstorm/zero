import AppKit
import CoreMedia
import ScreenCaptureKit
import ZeroCore

/// The desktop tools' eyes and the drag: a window's picture or film, through ScreenCaptureKit (the Screen Recording
/// permission, which only Settings › Desktop asks for), Zero's own windows drawn by Zero itself (no permission).
extension DesktopHands {
    // MARK: Screenshot

    static func screenshot(_ target: Target?, _ args: [String: Any]) throws -> [String: Any] {
        let save = args["save"] as? Bool == true
        // Zero's own window, drawn as it is, off-screen or not. ponytail: Zero Browser's page (another process's layer)
        // may come out blank here; ScreenCaptureKit when granted, if that's ever needed.
        if let target, target.pid == getpid() {
            guard let window = MainActor.assumeIsolated({ ownWindow(args) }) else { throw DesktopError("Zero has no window open") }
            let view = window.contentView?.superview ?? window.contentView!
            let size = view.bounds.size
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw DesktopError("Couldn't draw Zero's window") }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            return try picture(
                rep,
                "\(target.name), window \(window.windowNumber) \(Int(size.width))x\(Int(size.height)): its x and y are the other tools'",
                save: save, name: target.name)
        }
        let (filter, size, said, source) = try content(target, args)
        let config = SCStreamConfiguration()
        if let source { config.sourceRect = source }
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        // The window's own pixels, no shadow around them: one pixel a point from its top-left, as desktop_read's x and y.
        config.ignoreShadowsSingleWindow = true
        let image = try waited { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        return try picture(NSBitmapImageRep(cgImage: image), said, save: save, name: target?.name ?? "screen")
    }

    /// Zero's own window an agent means: the one named, else the frontmost of its windows (never a panel: a card, the bar).
    @MainActor static func ownWindow(_ args: [String: Any]) -> NSWindow? {
        if let id = args["window"] as? Int { return NSApp.window(withWindowNumber: id).flatMap { $0 is NSPanel ? nil : $0 } }
        return NSApp.orderedWindows.first { !($0 is NSPanel) && $0.isVisible }
    }

    /// What ScreenCaptureKit films: the app's window (by its window server id, as desktop_read gives it), or the main
    /// display. Never asked of it without the permission: that would be the system's prompt.
    /// With its sheets and child windows (another window of the app's, on screen, inside its frame), the window's part of
    /// the display, those windows alone: `source`.
    static func content(_ target: Target?, _ args: [String: Any]) throws -> (SCContentFilter, CGSize, String, source: CGRect?) {
        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopError("Zero hasn't got the Screen Recording permission: ask the user to grant it in Zero's Settings › Desktop.")
        }
        let id: CGWindowID?
        if let target {
            id =
                target.pid == getpid()
                ? onMain { ownWindow(args).map { CGWindowID($0.windowNumber) } } : windowID(try window(target, args))
            guard id != nil else { throw DesktopError("\(target.name) has no window open") }
        } else {
            id = nil
        }
        let shareable = try waited { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        if let target, let id {
            guard let window = shareable.windows.first(where: { $0.windowID == id }) else {
                throw DesktopError("\(target.name)'s window \(id) can't be captured (closed, or not on any display)")
            }
            let size = window.frame.size
            let said = "\(target.name), window \(id) \(Int(size.width))x\(Int(size.height))"
            let children = shareable.windows.filter {
                $0.windowID != id && $0.isOnScreen && $0.owningApplication?.processID == target.pid
                    && window.frame.insetBy(dx: -2, dy: -2).contains($0.frame)
            }
            let middle = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if !children.isEmpty, let display = shareable.displays.first(where: { $0.frame.contains(middle) }) {
                return (
                    SCContentFilter(display: display, including: [window] + children), size,
                    "\(said) with \(children.count) sheet or child window\(children.count == 1 ? "" : "s"): its x and y are the other tools'",
                    window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                )
            }
            return (SCContentFilter(desktopIndependentWindow: window), size, "\(said): its x and y are the other tools'", nil)
        }
        // ponytail: the main display alone; a display argument when someone works across several.
        guard let display = shareable.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? shareable.displays.first else {
            throw DesktopError("No display to capture")
        }
        return (
            SCContentFilter(display: display, excludingWindows: []), CGSize(width: display.width, height: display.height),
            "The screen, \(display.width)x\(display.height)", nil
        )
    }

    /// The picture as the agent sees it (a JPEG, small enough for its context), and as a PNG file when asked.
    static func picture(_ rep: NSBitmapImageRep, _ said: String, save: Bool, name: String) throws -> [String: Any] {
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw DesktopError("Couldn't encode the picture")
        }
        var said = said + " (one pixel per point)"
        if save, let png = rep.representation(using: .png, properties: [:]) {
            let url = try file(name, "png")
            try png.write(to: url)
            said += "; saved at \(url.path)"
        }
        return [
            "content": [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"], ["type": "text", "text": said]]
        ]
    }

    /// A new file in Zero's desktop folder (~/.zero/desktop; Zero Dev's in ~/.zero-dev).
    static func file(_ name: String, _ ext: String) throws -> URL {
        let folder = Paths.dir.appendingPathComponent("desktop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return folder.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
    }

    /// An async call waited for, off the main thread (the desktop's queue).
    static func waited<T>(_ seconds: Double = 20, _ work: @escaping () async throws -> T) throws -> T {
        let box = WaitedBox<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            throw DesktopError("Screen capture didn't answer within \(Int(seconds)) seconds")
        }
        return try box.result!.get()
    }

    // MARK: Record

    /// A task's recording under way: one a task.
    final class Recording: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
        let stream: SCStream
        let url: URL
        let started = Date()
        let finished = DispatchSemaphore(value: 0)
        var failed: Error?
        init(stream: SCStream, url: URL) { self.stream = stream; self.url = url }
        func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) { finished.signal() }
        func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
            failed = error
            finished.signal()
        }
    }
    nonisolated(unsafe) static var recordings: [String: Recording] = [:]
    /// What a recording that stopped by itself (its max, the user's Stop) said, for the task's stop.
    nonisolated(unsafe) static var ended: [String: String] = [:]
    static let recordingsLock = NSLock()

    static func record(_ target: Target?, _ args: [String: Any]) throws -> String {
        let session = args["session"] as? String ?? ""
        if args["action"] as? String == "stop" { return try stopRecording(session) }
        guard args["action"] as? String == "start" else { throw DesktopError("action: start or stop") }
        if recordingsLock.withLock({ recordings[session] != nil }) { throw DesktopError("This task is recording already: stop it first") }
        let (filter, size, said, source) = try content(target, args)
        let fps = min(60, max(1, args["fps"] as? Int ?? 60)), seconds = min(600, max(1, args["max"] as? Double ?? 60))
        let config = SCStreamConfiguration()
        if let source { config.sourceRect = source }
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        let url = try file(target?.name ?? "screen", "mp4")
        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mp4
        output.videoCodecType = .h264
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recording = Recording(stream: stream, url: url)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: recording))
        try waited { try await stream.startCapture() }
        recordingsLock.withLock {
            recordings[session] = recording
            ended[session] = nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if recordingsLock.withLock({ recordings[session] === recording }) { _ = try? stopRecording(session, keep: true) }
        }
        return
            "Recording \(said) at \(fps) fps into \(url.path). Act, then desktop_record stop; it stops by itself after \(Int(seconds)) s."
    }

    /// The task's recording ended and its file finished: where it is and how long. Also the user's Stop, and its max.
    /// `keep`: a stop the task didn't make (its max, the user's Stop), its answer kept for the task's own stop.
    @discardableResult static func stopRecording(_ session: String, keep: Bool = false) throws -> String {
        guard let recording = recordingsLock.withLock({ recordings.removeValue(forKey: session) }) else {
            if let said = recordingsLock.withLock({ ended.removeValue(forKey: session) }) { return said }
            throw DesktopError("This task isn't recording")
        }
        defer { Task { @MainActor in Desktop.shared.settled() } }
        let seconds = Date().timeIntervalSince(recording.started)
        try? waited { try await recording.stream.stopCapture() }
        _ = recording.finished.wait(timeout: .now() + 10)
        if let failed = recording.failed { throw DesktopError("The recording failed: \(failed.localizedDescription)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw DesktopError("The recording stopped, but its file is empty: no frames reached it") }
        let said =
            "Saved \(recording.url.path), \(String(format: "%.1f", seconds)) s. See its frames with zero video \(recording.url.path) (--every, --from, --to)."
        if keep { recordingsLock.withLock { ended[session] = said } }
        return said
    }

    // MARK: Drag

    static func drag(_ target: Target, _ args: [String: Any]) throws -> String {
        // Both ends checked before anything moves: in Zero, neither may be the user's.
        let from = try place(target, args["from"], args), to = try place(target, args["to"], args)
        try trusted()
        let real = args["pointer"] as? Bool == true && !target.background
        let source = CGEventSource(stateID: real ? .hidSystemState : .privateState)
        let window = windowNumber(at: from, pid: target.pid)
        var back: CGPoint?
        if real {
            try waitForIdle()
            back = CGEvent(source: nil)?.location
            target.app.activate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let before = state(target, at: from)
        let steps = 12
        for step in 0...steps + 1 {
            let along = Double(min(step, steps)) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along)
            let type: CGEventType = step == 0 ? .leftMouseDown : step > steps ? .leftMouseUp : .leftMouseDragged
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            if let window {
                event?.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(window))
                event?.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(window))
            }
            if real { event?.post(tap: .cghidEventTap) } else { event?.postToPid(target.pid) }
            // A moment after the press, for the app's tracking loop to start.
            Thread.sleep(forTimeInterval: step == 0 ? 0.05 : 0.01)
        }
        if let back { CGWarpMouseCursorPosition(back) }
        Thread.sleep(forTimeInterval: 0.15)
        let at = { (p: CGPoint) in "\(Int(p.x)),\(Int(p.y))" }
        let did =
            "Dragged from \(at(from)) to \(at(to))" + (real ? " with the real pointer (\(target.name) came forward)" : " in the background")
        if let changed = DesktopChange.said(before, state(target, at: from)) { return "\(did): \(changed)" }
        // Text selected by a drag, in an app that ignores drags sent to it in the background: the same selection, set
        // through accessibility.
        if !real, let selected = selectText(target, from: from, to: to) {
            return "Selected text from \(at(from)) to \(at(to)) through accessibility: \(selected)"
        }
        return
            "\(did), but nothing changed that accessibility shows (selection, value, scroll, window position)\(real ? "" : ": if it should have, try pointer: true")"
    }

    /// What a drag or a scroll can change at a point, as accessibility shows it, from the element there up: the text
    /// selection, a slider's value, the scroll position, the window's place.
    static func state(_ target: Target, at point: CGPoint) -> [String: String] {
        var found: [String: String] = [:]
        var current = elementAt(target, point)
        var steps = 0
        while let element = current, steps < 15 {
            let role = string(element, kAXRoleAttribute) ?? ""
            if found["selection"] == nil, let range = attribute(element, kAXSelectedTextRangeAttribute).flatMap(cfRange) {
                found["selection"] = "\(range.location)+\(range.length)"
            }
            if found["scroll"] == nil, role == kAXScrollAreaRole {
                let bar = { (name: String) -> String in
                    attribute(element, name).flatMap { (attribute($0 as! AXUIElement, kAXValueAttribute) as? NSNumber)?.doubleValue }
                        .map { String(format: "%.2f", $0) } ?? "-"
                }
                found["scroll"] = "\(bar(kAXVerticalScrollBarAttribute)) down, \(bar(kAXHorizontalScrollBarAttribute)) across"
            }
            if found["value"] == nil, [kAXSliderRole, kAXIncrementorRole].contains(role),
                let value = attribute(element, kAXValueAttribute) as? NSNumber
            {
                found["value"] = "\(value)"
            }
            if found["window"] == nil, role == kAXWindowRole {
                let frame = frameOf(element)
                found["window"] = "at \(Int(frame.minX)),\(Int(frame.minY))"
            }
            current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
            steps += 1
        }
        return found
    }

    static func cfRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Both ends in one text element: its characters between them selected, by their positions.
    static func selectText(_ target: Target, from: CGPoint, to: CGPoint) -> String? {
        guard let text = elementAt(target, from), let end = elementAt(target, to), CFEqual(text, end),
            settable(text, kAXSelectedTextRangeAttribute)
        else { return nil }
        func index(_ point: CGPoint) -> Int? {
            var point = point
            var found: CFTypeRef?
            guard let at = AXValueCreate(.cgPoint, &point),
                AXUIElementCopyParameterizedAttributeValue(text, kAXRangeForPositionParameterizedAttribute as CFString, at, &found)
                    == .success
            else { return nil }
            return found.flatMap(cfRange)?.location
        }
        guard let start = index(from), let stop = index(to) else { return nil }
        var range = CFRange(location: min(start, stop), length: abs(stop - start))
        guard let value = AXValueCreate(.cfRange, &range), (try? set(text, kAXSelectedTextRangeAttribute, value)) != nil else { return nil }
        return "selection \(range.location)+\(range.length)"
    }

    /// One end of a drag on the screen: a ref's middle, or x and y in the window; in Zero, never on what's the user's.
    static func place(_ target: Target, _ spot: Any?, _ args: [String: Any]) throws -> CGPoint {
        guard let spot = spot as? [String: Any] else { throw DesktopError("from and to: each a ref, or x and y") }
        if let ref = spot["ref"] as? String {
            let element = try element(target, ref)
            try guardZero(target, element)
            let frame = frameOf(element)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        var at = spot
        at["window"] = args["window"]
        let point = try screenPoint(target, at)
        if target.pid == getpid() {
            guard let element = elementAt(target, point) else { throw refusedInZero }
            try guardZero(target, element)
        }
        return point
    }
}

/// What a waited call gave, handed from its task to the thread waiting on it.
final class WaitedBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
