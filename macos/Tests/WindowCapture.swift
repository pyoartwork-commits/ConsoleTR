import AppKit
import Carbon
import ScreenCaptureKit

@main struct WindowCaptureTest {
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(60)
        while !condition() {
            if ContinuousClock.now >= end { throw AppFailure(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor static func main() async throws {
        // Measure the steady state: accurate OCR loads once per executable path.
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 160, width: 800, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "ConsoleTR pencere testi"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        let heading = NSTextField(labelWithString: "Find the key")
        heading.frame = CGRect(x: 495, y: 325, width: 290, height: 45)
        heading.autoresizingMask = [.minYMargin, .minXMargin]
        let label = NSTextField(labelWithString: "Kratos: Open the door.")
        label.frame = CGRect(x: 30, y: 40, width: 740, height: 50)
        for field in [heading, label] {
            field.font = .systemFont(ofSize: 29)
            field.textColor = .white
            window.contentView?.addSubview(field)
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        try await Task.sleep(for: .milliseconds(500))
        let content = try await SCShareableContent.currentProcess
        guard let source = content.windows.first(where: { Int($0.windowID) == window.windowNumber }) else {
            throw AppFailure("Test penceresi bulunamadı.")
        }
        let target = CaptureTarget(id: "test", title: window.title,
                                   filter: SCContentFilter(desktopIndependentWindow: source), displayID: nil, windowID: source.windowID)
        let model = Controller()
        model.provider = .demo
        model.live = true
        model.targets = [target]
        model.selection = target.id
        model.start()
        defer { model.stop(); window.orderOut(nil) }
        func value(_ role: TextRole) -> String? { model.tracks.first { $0.line.role == role }?.value }
        func visiblePanels() -> [NSWindow] { app.windows.filter { $0 is NSPanel && $0.isVisible && $0.ignoresMouseEvents } }
        try await wait("Görev ve altyazı ayrı tanınamadı.") {
            value(.subtitle) == "TR: Kratos: Open the door." && value(.objective) == "TR: Find the key" && visiblePanels().count == 2
        }
        guard let subtitlePanel = visiblePanels().min(by: { $0.frame.midY < $1.frame.midY }),
              let taskPanel = visiblePanels().max(by: { $0.frame.midY < $1.frame.midY }),
              taskPanel.frame.midX > window.frame.midX, subtitlePanel.frame.midX < window.frame.midX else {
            throw AppFailure("Katmanlar kaynak metinlerin yanında değil.")
        }
        let initial = subtitlePanel.frame
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 40, y: window.frame.minY + 30))
        try await wait("Altyazı taşınan pencereyi izlemedi.") {
            abs(subtitlePanel.frame.midX - initial.midX - 40) < 2 && abs(subtitlePanel.frame.minY - initial.minY - 30) < 2
        }
        let taskX = taskPanel.frame.midX
        heading.frame.origin.x += 48
        try await wait("Görev metninin hareketi izlenemedi.") { taskPanel.frame.midX > taskX + 35 && model.translations == 2 }
        heading.stringValue = ""
        try await wait("Kaybolan görev katmanı kaldırılmadı.") { visiblePanels().count == 1 && value(.objective) == nil && value(.subtitle) != nil }
        model.configureShortcut()
        defer { model.shortcut.remove() }
        func sendShortcut() throws {
            var event: EventRef?
            var id = EventHotKeyID(signature: 0x4354524B, id: 1)
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                              EventAttributes(kEventAttributeNone), &event) == noErr, let event else { throw AppFailure("Kısayol olayı oluşturulamadı.") }
            defer { ReleaseEvent(event) }
            guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &id) == noErr,
                  SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr else { throw AppFailure("Kısayol işlenemedi.") }
        }
        try sendShortcut()
        guard !model.enabled, visiblePanels().isEmpty else { throw AppFailure("Çeviri kapanmadı.") }
        try sendShortcut()
        try await wait("Sabit karede çeviri yeniden açılmadı.") { visiblePanels().count == 1 && model.translations == 2 }
        window.toggleFullScreen(nil)
        try await wait("Tam ekran geçişi doğrulanamadı.") { window.styleMask.contains(.fullScreen) && visiblePanels().count == 1 }
        label.stringValue = "Follow me."
        try await wait("Tam ekranda yeni altyazı okunamadı.") { value(.subtitle) == "TR: Follow me." }
        try await Task.sleep(for: .seconds(1))
        window.toggleFullScreen(nil)
        try await wait("Pencere moduna dönülemedi.") { !window.styleMask.contains(.fullScreen) }
        label.stringValue = ""
        try await wait("Kaybolan altyazı gizlenmedi.") { model.translated.isEmpty && visiblePanels().isEmpty }
        model.stop()
        heading.frame.origin = CGPoint(x: 45, y: 325)
        heading.stringValue = "Reach the garage"
        label.stringValue = "Wait for me."
        // The second layout uses the same automatic scan configuration.
        model.start()
        try await wait("Sol üst görev ve alt altyazı ayrı izlenemedi.") {
            value(.objective) == "TR: Reach the garage" && value(.subtitle) == "TR: Wait for me." && visiblePanels().count == 2
        }
        heading.frame.origin = CGPoint(x: 250, y: 210)
        heading.stringValue = "Retrieve the package"
        try await wait("Merkezdeki görev otomatik algılanamadı.") {
            value(.objective) == "TR: Retrieve the package" && value(.subtitle) == "TR: Wait for me."
        }
        model.stop()
        model.manualRegions = true
        model.objectiveRegion = CGRect(x: 0, y: 0.04, width: 0.50, height: 0.42)
        heading.frame.origin = CGPoint(x: 45, y: 325)
        heading.stringValue = "The White Orchard"
        model.start()
        try await wait("Manuel yedek alandaki görev okunamadı.") {
            value(.objective) == "TR: The White Orchard" && value(.subtitle) == "TR: Wait for me."
        }
        print("Merkezde otomatik tarama ve manuel yedek alan doğrulandı.")
        print("Sağ ve sol üst görev alanları, altyazı ayrımı, taşıma, bağımsız gizleme, aç/kapat ve tam ekran testleri geçti.")
    }
}
