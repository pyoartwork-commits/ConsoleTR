import AppKit
import ScreenCaptureKit

@MainActor final class DelayedAppleProvider: TranslationProvider {
    let apple = Translator(endpoint: nil, names: "Geralt")
    var calls = [String]()
    var released = false
    var cancelled = false
    func translate(_ text: String) async throws -> String {
        calls.append(text)
        while !released {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { cancelled = true; throw error }
        }
        return try await apple.translate(text)
    }
}

@main struct MovingOverlay {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            if ContinuousClock.now > deadline { throw AppFailure("Beklenen katman durumu oluşmadı.") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor static func main() async throws {
        // Measure the steady state: accurate OCR loads once per executable path.
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let game = NSWindow(contentRect: CGRect(x: 100, y: 150, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        game.level = .statusBar
        let dialogue = NSTextField(labelWithString: "Oh, Geralt")
        let objective = NSTextField(labelWithString: "Find the key")
        for (field, origin) in [(dialogue, CGPoint(x: 80, y: 60)), (objective, CGPoint(x: 490, y: 345))] {
            field.font = .systemFont(ofSize: 32)
            field.textColor = .white
            field.frame = CGRect(origin: origin, size: CGSize(width: 300, height: 48))
            game.contentView?.addSubview(field)
        }
        game.backgroundColor = .black
        game.orderFrontRegardless()
        let animation = Task {
            var tick = 0
            while !Task.isCancelled {
                game.backgroundColor = NSColor(white: CGFloat(tick % 8) / 40, alpha: 1)
                tick += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        defer { animation.cancel(); game.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { Int($0.windowID) == game.windowNumber }) else { throw AppFailure("Deneme penceresi bulunamadı.") }
        let model = Controller(), provider = DelayedAppleProvider()
        model.live = true
        model.manualRegions = true
        let target = CaptureTarget(id: "game", title: "Oyun testi", filter: SCContentFilter(desktopIndependentWindow: window), displayID: nil, windowID: window.windowID)
        model.targets = [target]
        model.selection = target.id
        model.start(using: provider)
        defer { model.stop() }
        try await wait { provider.calls.count >= 2 }
        print("Algılama ve çeviri isteği:", provider.calls)
        dialogue.stringValue = ""
        try await Task.sleep(for: .milliseconds(370))
        dialogue.stringValue = "Oh Geralt."
        try await Task.sleep(for: .milliseconds(350))
        provider.released = true
        try await wait { model.tracks.count == 2 && model.tracks.allSatisfy { $0.value != nil } }
        let panels = app.windows.filter { $0 is NSPanel && $0.isVisible && $0.isOnActiveSpace }
        let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String:Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        let above = panels.filter { panel in
            guard let p = order.firstIndex(of: panel.windowNumber), let g = order.firstIndex(of: game.windowNumber) else { return false }
            return p < g && game.frame.contains(panel.frame)
        }
        print("Üretilen çeviriler:", model.translated, "Görünür katman:", panels.count, "Oyunun üzerinde:", above.count, "İptal:", provider.cancelled)
        let displayed = above.flatMap { panel in
            panel.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        }
        guard !provider.cancelled, provider.calls.count == 2, above.count == 2,
              Set(displayed) == Set(model.tracks.compactMap(\.value)) else { exit(1) }
        dialogue.stringValue = ""
        try await wait { model.tracks.count == 1 && model.tracks[0].line.role == .objective }
        print("Diyalog kaybolduğunda görev katmanı korundu.")
    }
}
