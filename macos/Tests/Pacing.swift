import AppKit
import ScreenCaptureKit

// Offline engine that, like Ollama here, works on one request at a time in arrival order.
@MainActor final class SingleSlot: TranslationProvider {
    var maxConcurrentRequests: Int { 1 }
    private var queue: [UUID] = []
    var calls: [String] = [], cancels = 0, mostQueued = 0
    func translate(_ text: String) async throws -> String {
        let id = UUID()
        queue.append(id)
        calls.append(text)
        mostQueued = max(mostQueued, queue.count)
        defer { queue.removeAll { $0 == id } }
        do {
            while queue.first != id { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(500))
        } catch { cancels += 1; throw error }
        return "TR: " + text
    }
}

@main struct Pacing {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let game = NSWindow(contentRect: CGRect(x: 100, y: 150, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        game.backgroundColor = .black
        func label(_ text: String, _ origin: CGPoint, width: CGFloat = 300) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 26)
            field.textColor = .white
            field.frame = CGRect(origin: origin, size: CGSize(width: width, height: 40))
            game.contentView?.addSubview(field)
            return field
        }
        _ = label("Find the key", CGPoint(x: 500, y: 430))
        _ = label("Reach the garage", CGPoint(x: 500, y: 390))
        _ = label("Retrieve the package", CGPoint(x: 500, y: 350))
        let caption = label("", CGPoint(x: 120, y: 50), width: 560)
        caption.alignment = .center
        game.orderFrontRegardless()
        defer { game.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { Int($0.windowID) == game.windowNumber }) else { throw AppFailure("Deneme penceresi bulunamadı.") }
        let model = Controller(), provider = SingleSlot()
        model.live = true
        let target = CaptureTarget(id: "game", title: "Oyun testi", filter: SCContentFilter(desktopIndependentWindow: window), displayID: nil, windowID: window.windowID)
        model.targets = [target]
        model.selection = target.id
        model.start(using: provider)
        defer { model.stop() }
        func shown() -> [String] {
            app.windows.filter { $0 is NSPanel && $0.isVisible }
                .flatMap { $0.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? [] }
        }
        func wait(_ message: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
            let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while !condition() {
                if ContinuousClock.now > end { throw AppFailure(message) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let clock = ContinuousClock()
        func elapsed(since start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: clock.now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        // 1. Three objectives are waiting for the only slot when a caption appears.
        try await wait("Görev metinleri çeviriye gönderilmedi.") { !provider.calls.isEmpty }
        caption.stringValue = "Kratos: Open the door."
        let appeared = clock.now
        try await wait("Altyazı çevirisi gelmedi.") { shown().contains("TR: Kratos: Open the door.") }
        let captionDelay = elapsed(since: appeared)
        print(String(format: "Bekleyen görevlere rağmen altyazı çevirisi: %.0f ms", captionDelay * 1000),
              "istekler:", provider.calls, "en fazla sıra:", provider.mostQueued, "iptal:", provider.cancels)
        guard captionDelay < 1.3, provider.mostQueued == 1 else { throw AppFailure("Altyazı görevlerin arkasında bekledi.") }

        // 2. The line leaves the screen; its translation must stay readable.
        try await Task.sleep(for: .milliseconds(400))
        caption.stringValue = ""
        let gone = clock.now
        try await Task.sleep(for: .milliseconds(1200))
        guard shown().contains("TR: Kratos: Open the door.") else { throw AppFailure("Çeviri satır kaybolunca hemen silindi.") }
        try await wait("Çeviri okuma süresinden sonra kaldırılmadı.", seconds: 8) { !shown().contains("TR: Kratos: Open the door.") }
        print(String(format: "Kaybolan satırın çevirisi %.1f s ekranda kaldı.", elapsed(since: gone)))

        // 3. A new caption replaces the previous one without an empty gap.
        try await wait("Görev çevirileri tamamlanmadı.") { !model.tracks.isEmpty && model.tracks.allSatisfy { $0.value != nil } }
        caption.stringValue = "Wait for me."
        try await wait("İlk altyazı çevrilmedi.") { shown().contains("TR: Wait for me.") }
        try await Task.sleep(for: .milliseconds(300))
        caption.stringValue = "Follow me."
        var gaps = 0, samples = 0
        while !shown().contains("TR: Follow me.") {
            samples += 1
            if !shown().contains(where: { $0 == "TR: Wait for me." }) { gaps += 1 }
            if samples > 400 { throw AppFailure("Yeni altyazı çevrilmedi.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        let captions = shown().filter { $0 == "TR: Wait for me." || $0 == "TR: Follow me." }
        print("Geçişte boş örnek:", gaps, "/", samples, "geçişten sonra altyazı katmanları:", captions)
        guard gaps == 0, captions == ["TR: Follow me."] else { throw AppFailure("Altyazı geçişinde boşluk veya çift katman oluştu.") }

        // 4. Translations remain listed in memory after they leave the screen.
        let pairs = model.recent.map { "\($0.original) → \($0.translation)" }
        print("Son çeviriler:", pairs)
        guard pairs.contains("Kratos: Open the door. → TR: Kratos: Open the door."), pairs.first == "Follow me. → TR: Follow me." else {
            throw AppFailure("Son çeviriler listesi eksik.")
        }
        print("Tek sıralı çeviri önceliği, okuma süresi, kesintisiz geçiş ve son çeviriler testleri geçti.")
    }
}
