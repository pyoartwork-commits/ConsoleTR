import AppKit
@main struct Integration {
    @MainActor static func main() async throws {
        // Measure the steady state: accurate OCR loads once per executable path.
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let model = Controller()
        model.video = URL(fileURLWithPath: CommandLine.arguments[1])
        let preview = try await model.previewImage()
        guard preview.width > 0, preview.height > 0 else { throw AppFailure("Video önizlemesi alınamadı.") }
        model.start()
        var measured = Set<String>()
        var overlaySeen = false
        var lines = [String: String]()
        while model.running {
            if !model.translated.isEmpty {
                if measured.insert(model.original).inserted {
                    print("OCR ve çeviri süreleri (ms):", model.ocrMS, model.translationMS)
                }
                lines[model.original] = model.translated
                overlaySeen = overlaySeen || app.windows.contains { $0 is NSPanel && $0.isVisible && $0.ignoresMouseEvents && $0.level == .floating }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        print(model.status, lines, model.translations, model.hits, overlaySeen)
        guard model.status == "Video tamamlandı.", lines == ["Open the door.": "Kapıyı aç.", "Follow me.": "Beni takip et."], model.translations == 2, model.hits == 1, overlaySeen else { exit(1) }
        let named = try await Translator(endpoint: nil, names: "Atreus").translate("Kratos: Follow Atreus.")
        guard named.hasPrefix("Kratos: "), named.contains("Atreus") else { throw AppFailure("Karakter adı korunamadı.") }
        model.provider = .libre
        model.address = "http://127.0.0.1:1/translate"
        model.start()
        while model.running { try await Task.sleep(for: .milliseconds(50)) }
        guard model.status.contains("sunucu"), !app.windows.contains(where: { $0 is NSPanel && $0.isVisible }) else { throw AppFailure("Ağ hatası yönetilemedi.") }
        print("Yerel video, karakter adı ve ağ hatası testleri geçti.")
    }
}
