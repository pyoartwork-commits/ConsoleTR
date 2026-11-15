import AppKit

// Gemma 4 through Ollama: error messages, output cleanup, and a real end-to-end run when a
// local Ollama server with the default model is available.
@main struct OllamaTest {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let samples = ["\"Geç kalma, dostum.\"": "Geç kalma, dostum.", "“Ateş et!”": "Ateş et!",
                       "Polislerden kaç.\n(Note: informal)": "Polislerden kaç.", "  Lester'ın evine git.  ": "Lester'ın evine git."]
        for (raw, expected) in samples where OllamaTranslator.clean(raw) != expected {
            throw AppFailure("Model yanıtı temizlenemedi: \(raw)")
        }
        do {
            _ = try ProviderChoice.gemma.make(address: "", names: "", ollamaModel: "  ")
            throw AppFailure("Boş model adı kabul edildi.")
        } catch let failure as AppFailure where failure.message.contains("model adını") {}
        do {
            _ = try await OllamaTranslator(endpoint: URL(string: "http://127.0.0.1:1")!).translate("Follow me.")
            throw AppFailure("Kapalı Ollama hatası oluşmadı.")
        } catch let failure as AppFailure where failure.message.contains("ollama serve") {}

        var tags = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!, timeoutInterval: 3)
        tags.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: tags),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = list["models"] as? [[String: Any]],
              models.contains(where: { ($0["name"] as? String) == OllamaTranslator.defaultModel }) else {
            print("UYARI: Ollama çalışmıyor veya \(OllamaTranslator.defaultModel) yok; gerçek model testleri atlandı.")
            print("Ollama hata mesajları ve yanıt temizleme testleri geçti.")
            return
        }
        do {
            _ = try await OllamaTranslator(model: "consoletr-missing-model").translate("Follow me.")
            throw AppFailure("Eksik model hatası oluşmadı.")
        } catch let failure as AppFailure where failure.message.contains("ollama pull consoletr-missing-model") {}

        let gemma = OllamaTranslator(names: "Atreus")
        let start = ProcessInfo.processInfo.systemUptime
        let named = try await gemma.translate("Kratos: Follow Atreus.")
        print("Gemma:", named, String(format: "(%.0f ms, ilk istek)", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        guard named.hasPrefix("Kratos: "), named.contains("Atreus"), named != "Kratos: Follow Atreus." else {
            throw AppFailure("Konuşmacı etiketi veya karakter adı korunamadı.")
        }

        // End to end: the bundled 6 s video through the controller with the Gemma provider.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard await SubtitleReader.waitForAccurate() else { throw AppFailure("Doğru OCR modeli yüklenemedi.") }
        let model = Controller()
        model.video = URL(fileURLWithPath: CommandLine.arguments[1])
        model.provider = .gemma
        model.start()
        var lines = [String: String](), overlaySeen = false
        while model.running {
            for track in model.tracks { if let value = track.value { lines[track.line.text] = value } }
            overlaySeen = overlaySeen || app.windows.contains { $0 is NSPanel && $0.isVisible && $0.ignoresMouseEvents }
            try await Task.sleep(for: .milliseconds(50))
        }
        print(model.status, lines, "çeviri:", model.translations, "son süre:", Int(model.translationMS), "ms")
        guard model.status == "Video tamamlandı.", Set(lines.keys) == ["Open the door.", "Follow me."], overlaySeen,
              lines.allSatisfy({ !$0.value.isEmpty && $0.value != $0.key }) else { throw AppFailure("Gemma ile video çevirisi tamamlanamadı.") }
        print("Ollama hata mesajları, yanıt temizleme, konuşmacı etiketi ve Gemma ile uçtan uca video testleri geçti.")
    }
}
