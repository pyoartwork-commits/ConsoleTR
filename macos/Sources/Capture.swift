@preconcurrency import ScreenCaptureKit
import CoreImage

// Game sources are what ConsoleTR should read: a Remote Play window or an OBS projector. OBS's
// main window shows the game only as a small preview next to OBS's own text ("CPU: 5.0%").
enum SourceKind: Sendable { case game, obsMain, other }

struct CaptureTarget: Identifiable {
    let id: String
    let title: String
    let filter: SCContentFilter
    let displayID: CGDirectDisplayID?

    var windowID: CGWindowID? = nil
    var kind = SourceKind.other
    // Window area in points; Remote Play's video window is its largest one.
    var area: CGFloat = 0

    @MainActor func placement(lastFrame: CGRect?, captureRect: CGRect?) -> (frame: CGRect?, level: NSWindow.Level) {
        guard let windowID else {
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
            return (screen?.frame, .floating)
        }
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        let item = info?.first
        let layer = item?[kCGWindowLayer as String] as? Int ?? 0
        let level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, layer + 1))
        if item?[kCGWindowIsOnscreen as String] as? Bool == false { return (nil, level) }
        let bounds = (item?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let selected = filter.includedWindows.first { $0.windowID == windowID }?.frame
        if let rect = bounds ?? captureRect, !rect.isEmpty, let primary = NSScreen.screens.first {
            return (CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height), level)
        }
        if let lastFrame { return (lastFrame, level) }
        if let selected, let primary = NSScreen.screens.first {
            return (CGRect(x: selected.minX, y: primary.frame.maxY - selected.maxY, width: selected.width, height: selected.height), level)
        }
        return (nil, level)
    }

    static func list() async throws -> [CaptureTarget] {
        // Off-screen windows are needed too: a full-screen Remote Play window lives in its own
        // Space, so it is off screen while ConsoleTR is set up on the desktop and was missing
        // from this list. ConsoleTR then picked another window and never saw the game.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let windows = content.windows.compactMap { (window: SCWindow) -> CaptureTarget? in
            guard window.windowLayer == 0, window.frame.width > 100, window.frame.height > 100,
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else { return nil }
            let app = window.owningApplication?.applicationName ?? "Uygulama"
            let bundle = window.owningApplication?.bundleIdentifier.lowercased() ?? ""
            let remotePlay = app.localizedCaseInsensitiveContains("Remote Play") || bundle.contains("remoteplay")
            let obs = bundle.contains("obsproject") || app.hasPrefix("OBS")
            let projector = obs && ["projektör", "projector"].contains { (window.title ?? "").localizedCaseInsensitiveContains($0) }
            let kind: SourceKind = remotePlay || projector ? .game : obs ? .obsMain : .other
            // Other apps keep many hidden windows; of those only Remote Play's are listed.
            guard window.isOnScreen || remotePlay else { return nil }
            let display = content.displays.max {
                func area(_ d: SCDisplay) -> CGFloat {
                    let r = d.frame.intersection(window.frame)
                    return r.isNull ? 0 : r.width * r.height
                }
                return area($0) < area($1)
            }
            let title = app + (window.title.flatMap { $0.isEmpty ? nil : " — " + $0 } ?? "") +
                (kind == .game ? " (oyun görüntüsü)" : "") + (window.isOnScreen ? "" : " (başka masaüstünde)")
            return Self(id: "w-\(window.windowID)", title: title,
                        filter: SCContentFilter(desktopIndependentWindow: window), displayID: display?.displayID,
                        windowID: window.windowID, kind: kind, area: window.frame.width * window.frame.height)
        }.sorted { (a: CaptureTarget, b: CaptureTarget) in a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        return windows + content.displays.enumerated().map { index, display in
            Self(id: "d-\(display.displayID)", title: "Ekran \(index + 1)",
                 filter: SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: []), displayID: display.displayID)
        }
    }
}

enum CapturedFrame: Sendable {
    case image(CGImage, screenRect: CGRect?)
    case empty
}

final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let context = CIContext(options: [.cacheIntermediates: false])
    @MainActor private var stream: SCStream?
    let frames: AsyncThrowingStream<CapturedFrame, Error>
    private let sink: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    override init() {
        (frames, sink) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }
    @MainActor func start(_ target: CaptureTarget, region: CGRect) async throws {
        let config = configuration(target, size: target.filter.contentRect.size, region: region)
        let stream = SCStream(filter: target.filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ConsoleTR.frames"))
        try await stream.startCapture()
    }
    @MainActor func resize(_ target: CaptureTarget, size: CGSize, region: CGRect) async throws {
        try await stream?.updateConfiguration(configuration(target, size: size, region: region))
    }
    private func configuration(_ target: CaptureTarget, size: CGSize, region: CGRect) -> SCStreamConfiguration {
        let crop = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                          width: region.width * size.width, height: region.height * size.height)
        let scale = min(CGFloat(target.filter.pointPixelScale), 1600 / max(1, crop.width))
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        config.sourceRect = crop
        config.width = max(2, Int(crop.width * scale))
        config.height = max(2, Int(crop.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }
    @MainActor func stop() async {
        sink.finish()
        try? await stream?.stopCapture()
        stream = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sink.finish(throwing: AppFailure("Yakalama kesildi. Pencerenin açık ve erişilebilir olduğunu kontrol edin."))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        if raw == SCFrameStatus.blank.rawValue || raw == SCFrameStatus.suspended.rawValue {
            sink.yield(.empty)
            return
        }
        guard raw == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        if let frame = context.createCGImage(image, from: image.extent) {
            let rect = (attachments.first?[.screenRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            sink.yield(.image(frame, screenRect: rect))
        }
    }
}

@MainActor final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    enum Outcome {
        case selected(CaptureTarget)
        case cancelled
        case failed(Error)
    }
    private var completion: ((Outcome) -> Void)?
    private var observing = false

    func present(_ completion: @escaping (Outcome) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        if !observing {
            picker.add(self)
            observing = true
        }
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.consoletr.desktop"]
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config
        picker.isActive = true
        picker.present(using: .window)
    }

    func close() {
        completion = nil
        if observing {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
            observing = false
        }
    }

    private func finish(_ outcome: Outcome) {
        let callback = completion
        completion = nil
        callback?(outcome)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in
            guard let window = filter.includedWindows.first else {
                finish(.failed(AppFailure("Seçilen pencereye erişilemedi. Pencereyi yeniden seçin.")))
                return
            }
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.owningApplication?.applicationName ?? "Seçilen pencere"
            finish(.selected(CaptureTarget(id: "w-\(window.windowID)", title: title, filter: filter,
                                           displayID: filter.includedDisplays.first?.displayID, windowID: window.windowID,
                                           area: window.frame.width * window.frame.height)))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in finish(.cancelled) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in finish(.failed(error)) }
    }
}
