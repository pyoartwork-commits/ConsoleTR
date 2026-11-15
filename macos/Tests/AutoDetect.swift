import AppKit
import ScreenCaptureKit

// Automatic full-window detection on a moving scene. Frames live only in memory.

struct SceneText { var text: String; var center: CGPoint; var size: CGFloat; var bold = false }

enum Scene {
    static func frame(_ t: Int, texts: [SceneText]) -> CGImage {
        let size = CGSize(width: 1600, height: 900)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.78, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.22, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.10, alpha: 1).cgColor] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        // Foliage and bright patches pan behind fixed HUD text, like a moving camera.
        var seed: UInt64 = 7
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        let span = size.width * 1.4
        for _ in 0..<140 {
            var x = (next() * span - CGFloat(t) * 14).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            let y = next() * size.height, w = 30 + next() * 180, h = 20 + next() * 120, b = next()
            ctx.setFillColor(NSColor(calibratedRed: 0.2 + b * 0.7, green: 0.25 + b * 0.65, blue: 0.15 + b * 0.5, alpha: 0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for item in texts {
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = CGSize(width: 1, height: -1)
            let string = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.systemFont(ofSize: item.size, weight: item.bold ? .bold : .medium),
                .foregroundColor: NSColor.white, .shadow: shadow])
            let s = string.size()
            string.draw(at: CGPoint(x: item.center.x * size.width - s.width / 2, y: size.height - item.center.y * size.height - s.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    // Squeeze a frame through a 1280x720 stream, as Remote Play does.
    static func stream(_ image: CGImage) -> CGImage {
        func scaled(_ source: CGImage, _ width: Int, _ height: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .low
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()!
        }
        return scaled(scaled(image, 1280, 720), image.width, image.height)
    }
}

// Offline provider with Apple-like latency, so lost requests show up as cancellations.
@MainActor final class SlowDemo: TranslationProvider {
    var calls = 0, cancels = 0
    func translate(_ text: String) async throws -> String {
        calls += 1
        do { try await Task.sleep(for: .milliseconds(300)) } catch { cancels += 1; throw error }
        return "TR: " + text
    }
}

@main struct AutoDetect {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Acceptance rules for the exact sample, without manual regions.
        let bottom = CGRect(x: 0.46, y: 0.845, width: 0.08, height: 0.03)
        let rules: [(String, TextRole?)] = [("Oh, Geralt", .subtitle), ("Oh, Geralt.", .subtitle),
                                            ("come back to Kaer Morhen", .subtitle), ("The Witcher Wild Hunt", nil),
                                            ("itcher Wild Hunt", nil), ("e Witcher Wild Hunt", nil), ("The Witche,Wild", nil)]
        for (text, expected) in rules where GameTextClassifier.role(for: text, box: bottom) != expected {
            throw AppFailure("Sınıflandırma hatalı: \(text)")
        }
        // The accurate OCR model loads once per executable path (about 30 s when new).
        // Until then the reader uses fast recognition; this suite measures the steady state.
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let game = NSWindow(contentRect: CGRect(x: 60, y: 120, width: 1000, height: 562), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSImageView(frame: CGRect(x: 0, y: 0, width: 1000, height: 562))
        view.imageScaling = .scaleAxesIndependently
        game.contentView = view
        game.orderFrontRegardless()
        defer { game.orderOut(nil) }

        let quest = [SceneText(text: "Wandering in the Dark", center: CGPoint(x: 0.86, y: 0.22), size: 22, bold: true),
                     SceneText(text: "Follow Ciri's trail.", center: CGPoint(x: 0.86, y: 0.255), size: 20)]
        let cases: [(name: String, texts: [SceneText], expected: [String])] = [
            ("Kısa diyalog ve görev", [SceneText(text: "Oh, Geralt", center: CGPoint(x: 0.5, y: 0.86), size: 30)] + quest,
             ["oh, geralt", "follow ciri"]),
            ("İki satırlı diyalog", [SceneText(text: "Oh, Geralt. I didn't expect", center: CGPoint(x: 0.5, y: 0.83), size: 30),
                                     SceneText(text: "to see you here", center: CGPoint(x: 0.5, y: 0.875), size: 30)],
             ["geralt"]),
            ("Duraklatma başlığı", [SceneText(text: "The Witcher Wild Hunt", center: CGPoint(x: 0.5, y: 0.78), size: 40, bold: true),
                                    SceneText(text: "Resume", center: CGPoint(x: 0.5, y: 0.86), size: 28)], []),
        ]
        for item in cases {
            let frames = (0..<24).map { Scene.frame($0, texts: item.texts) }
            view.image = NSImage(cgImage: frames[0], size: .zero)
            let animation = Task { @MainActor in
                var tick = 0
                while !Task.isCancelled {
                    tick += 1
                    view.image = NSImage(cgImage: frames[tick % frames.count], size: .zero)
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
            defer { animation.cancel() }
            try await Task.sleep(for: .milliseconds(300))
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { Int($0.windowID) == game.windowNumber }) else { throw AppFailure("Deneme penceresi bulunamadı.") }
            let model = Controller(), provider = SlowDemo()
            model.live = true
            model.manualRegions = false
            let target = CaptureTarget(id: "game", title: "Oyun testi", filter: SCContentFilter(desktopIndependentWindow: window), displayID: nil, windowID: window.windowID)
            model.targets = [target]
            model.selection = target.id
            model.start(using: provider)
            // Sample once per 100 ms after a 1.2 s warm-up for the first OCR pass and translation.
            try await Task.sleep(for: .milliseconds(1200))
            var visible = Array(repeating: 0, count: item.expected.count), stray = 0, samples = 0
            var ids = Set<UUID>()
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                samples += 1
                ids.formUnion(model.tracks.map(\.id))
                let shown = app.windows.filter { $0 is NSPanel && $0.isVisible }
                    .flatMap { $0.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue.lowercased() } ?? [] }
                for (index, expected) in item.expected.enumerated() where shown.contains(where: { $0.contains(expected) }) { visible[index] += 1 }
                stray += shown.filter { text in !item.expected.contains { text.contains($0) } }.count
            }
            model.stop()
            print(item.name, "— görünür:", zip(item.expected, visible).map { "\($0)=\($1)/\(samples)" }, "yabancı katman:", stray,
                  "track:", ids.count, "istek:", provider.calls, "iptal:", provider.cancels)
            guard visible.allSatisfy({ $0 >= samples * 9 / 10 }), stray == 0,
                  ids.count <= item.expected.count + 1, provider.cancels <= 1 else { throw AppFailure("\(item.name) kararlı izlenmedi.") }
        }
        try await flowingCaptions(app: app, game: game, view: view, quest: quest)
        print("Otomatik algılama: kısa diyalog, iki satır, eşzamanlı görev, menü başlığı ve akan altyazı testleri geçti.")
    }

    // Captions replace each other every 2.5 s over a 720p stream while a quest tracker stays
    // on screen. Every caption must get its translation drawn while it is still shown.
    @MainActor static func flowingCaptions(app: NSApplication, game: NSWindow, view: NSImageView, quest: [SceneText]) async throws {
        let script: [[String]] = [["Oh, Geralt"], ["The Baron's men passed through the village yesterday."],
                                  ["Hm. Wolves, maybe. Or something worse"], ["I've heard rumors of a griffin", "near White Orchard."],
                                  ["You better not be late."], ["Man, what you doin' here, dog?", "Get in the car."]]
        let tracker = quest + [SceneText(text: "Speak with the Baron.", center: CGPoint(x: 0.86, y: 0.29), size: 20)]
        let fps = 10, perLine = 25
        let frames = (0..<(script.count * perLine)).map { index in
            let parts = script[index / perLine]
            let captions = parts.enumerated().map { i, part in
                SceneText(text: part, center: CGPoint(x: 0.5, y: 0.86 - 0.04 * Double(parts.count - 1 - i)), size: 26)
            }
            return Scene.stream(Scene.frame(index, texts: tracker + captions))
        }
        view.image = NSImage(cgImage: frames[0], size: .zero)
        try await Task.sleep(for: .milliseconds(300))
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { Int($0.windowID) == game.windowNumber }) else { throw AppFailure("Deneme penceresi bulunamadı.") }
        let model = Controller(), provider = SerialDemo()
        model.live = true
        model.manualRegions = false
        let target = CaptureTarget(id: "game", title: "Oyun testi", filter: SCContentFilter(desktopIndependentWindow: window), displayID: nil, windowID: window.windowID)
        model.targets = [target]
        model.selection = target.id
        model.start(using: provider)
        defer { model.stop() }
        try await Task.sleep(for: .milliseconds(500))
        let clock = ContinuousClock(), start = clock.now
        var first = [Double?](repeating: nil, count: script.count)
        var shown = [Int](repeating: 0, count: script.count), samples = [Int](repeating: 0, count: script.count)
        while true {
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let index = Int(seconds * Double(fps))
            guard index < frames.count else { break }
            view.image = NSImage(cgImage: frames[index], size: .zero)
            let line = index / perLine
            let expected = "tr: " + Track.key(for: script[line].joined(separator: " "))
            let texts = app.windows.filter { $0 is NSPanel && $0.isVisible }
                .flatMap { $0.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? [] }
            samples[line] += 1
            if texts.contains(where: { Track.similarity(Track.key(for: $0), expected) >= 0.8 }) {
                shown[line] += 1
                if first[line] == nil { first[line] = (seconds - Double(line * perLine) / Double(fps)) * 1000 }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        for (index, line) in script.enumerated() {
            print("Akan altyazı \(index + 1): ilk çeviri", first[index].map { String(format: "%.0f ms", $0) } ?? "YOK",
                  "görünür %\(shown[index] * 100 / max(1, samples[index]))", line.joined(separator: " / "))
        }
        print("Akan altyazı — istek:", provider.calls, "iptal:", provider.cancels)
        // A line counts as served when its translation appears within 1.5 s of the
        // 2.5 s it is on screen and then stays for at least 40% of that time.
        guard first.allSatisfy({ ($0 ?? .infinity) <= 1500 }),
              zip(shown, samples).allSatisfy({ $0 * 10 >= $1 * 4 }) else { throw AppFailure("Akan altyazıların çevirisi yetişmedi.") }
    }
}

// Offline provider that serves one request at a time in arrival order, like Apple
// Translation. Cancelled requests leave the queue.
@MainActor final class SerialDemo: TranslationProvider {
    private var queue: [UUID] = []
    var calls = 0, cancels = 0
    func translate(_ text: String) async throws -> String {
        let id = UUID()
        queue.append(id)
        calls += 1
        defer { queue.removeAll { $0 == id } }
        do {
            while queue.first != id { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(350))
        } catch { cancels += 1; throw error }
        return "TR: " + text
    }
}
