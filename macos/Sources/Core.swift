import Foundation
import AVFoundation
import Vision
import CoreText
import Synchronization
import NaturalLanguage
@preconcurrency import Translation

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum TextRole: String, CaseIterable, Identifiable, Sendable {
    case subtitle = "Altyazı"
    case objective = "Görev"
    var id: Self { self }
}

// Normalized source coordinates, measured from the top left.
struct Detection: Equatable, Sendable {
    var role: TextRole
    var text: String
    var box: CGRect
}

struct ScanZone: Sendable {
    let role: TextRole?
    let rect: CGRect
}

enum GameTextClassifier {
    private static let actions: Set<String> = ["find", "reach", "meet", "locate", "collect", "return", "deliver", "retrieve", "defeat", "kill", "escort", "protect", "escape", "investigate", "search", "enter", "leave", "drive", "steal", "take", "use", "get", "follow", "talk", "go", "destroy", "rescue", "complete", "visit", "travel", "recover", "eliminate", "look", "wait"]
    private static let headings = ["objective", "quest", "mission", "new objective", "new quest", "quest updated", "mission passed", "mission failed", "optional objective"]
    private static let controls = ["press ", "hold ", "click ", "fps ", "consoletr", "tr:"]

    static func role(for text: String, box: CGRect) -> TextRole? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split { !$0.isLetter }
        guard let first = words.first,
              !controls.contains(where: lower.hasPrefix) else { return nil }
        if words.count >= 5, let language = NLLanguageRecognizer.dominantLanguage(for: text),
           language != .english { return nil }
        if headings.contains(where: { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + " ") }) { return .objective }
        if text.range(of: #"^[A-Z][A-Za-z '’-]{0,28}:\s*\S"#, options: .regularExpression) != nil { return .subtitle }
        let punctuated = lower.last.map { ".!?…".contains($0) } ?? false
        let conversational = words.contains { ["i", "we", "you", "me", "our", "my", "your", "they"].contains($0) }
        if conversational && (punctuated || words.count >= 3) { return .subtitle }
        if words.count >= 2 && actions.contains(String(first)) {
            if box.midY >= 0.65 && punctuated && abs(box.midX - 0.5) < 0.30 { return .subtitle }
            return .objective
        }
        if punctuated && (box.midY >= 0.40 || words.count >= 3) { return .subtitle }
        // Unpunctuated captions in the bottom centre. Runs where every word is capitalised
        // ("The Witcher Wild Hunt") are menu titles, not speech; the first word is skipped
        // because OCR often clips it ("itcher Wild Hunt"). A comma followed by a space marks
        // short vocative lines such as "Oh, Geralt".
        if box.midY >= 0.63 && abs(box.midX - 0.5) < 0.28 && text != text.uppercased() {
            let titleCased = !text.split(separator: " ").dropFirst().contains { $0.first?.isLowercase == true }
            if words.count >= 3 && !titleCased { return .subtitle }
            if words.count >= 2 && text.contains(", ") { return .subtitle }
        }
        return nil
    }
}

actor SubtitleReader {
    // Accurate recognition loads its model on first use. For an executable at a new path
    // this took 26 s on M4 before the system cached it, so fast recognition covers the gap.
    static let accurateReady = Atomic<Bool>(false)
    private static let warmUp = Task.detached(priority: .utility) {
        let width = 480, height = 80
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Text has to be present, or recognition may never load its model.
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Follow the trail.", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 16, y: 26)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        accurateReady.store(true, ordering: .releasing)
    }
    static func prewarm() { _ = warmUp }
    // Switching from fast to accurate mid-session moves boxes by a few pixels once.
    // Tests that measure positions wait for the steady state; false on timeout.
    static func waitForAccurate(timeout: Duration = .seconds(120)) async -> Bool {
        prewarm()
        let end = ContinuousClock.now + timeout
        while !accurateReady.load(ordering: .acquiring) {
            if ContinuousClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private struct Snapshot {
        let pixels: CFData
        let rect: CGRect
        let stride: Int
        let lines: [Detection]
    }
    private var snapshots: [TextRole?: Snapshot] = [:]

    func read(_ frame: CGImage, zones: [ScanZone]) throws -> (lines: [Detection], milliseconds: Double?) {
        let start = ProcessInfo.processInfo.systemUptime
        var scanned = false
        var lines: [Detection] = []
        let width = CGFloat(frame.width), height = CGFloat(frame.height)
        for zone in zones {
            try Task.checkCancellation()
            let crop = CGRect(x: zone.rect.minX * width, y: zone.rect.minY * height,
                              width: zone.rect.width * width, height: zone.rect.height * height)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = frame.cropping(to: crop) else { continue }
            let pixels = image.dataProvider?.data
            if let last = snapshots[zone.role], last.rect == crop, last.stride == image.bytesPerRow,
               let pixels, CFEqual(pixels, last.pixels) {
                lines += last.lines
                continue
            }
            scanned = true
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            // Fast recognition clipped or split most captions over moving, stream-compressed
            // scenes (12% exact on a 720p Remote Play-like test). Accurate read 95% exact in
            // about 70 ms per full frame on M4, inside the 250 ms capture interval.
            Self.prewarm()
            request.recognitionLevel = Self.accurateReady.load(ordering: .acquiring) ? .accurate : .fast
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { throw AppFailure("Vision metni okuyamadı. Yakalama kaynağını yeniden seçin.") }
            let observations = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                      candidate.string.rangeOfCharacter(from: .letters) != nil else { return nil }
                let box = observation.boundingBox
                let rect = CGRect(x: (crop.minX + box.minX * crop.width) / width,
                                  y: (crop.minY + (1 - box.maxY) * crop.height) / height,
                                  width: box.width * crop.width / width, height: box.height * crop.height / height)
                return (candidate.string, rect)
            }
            var found: [Detection] = []
            for observation in observations.sorted(by: { $0.box.minY < $1.box.minY }) {
                var role = zone.role ?? GameTextClassifier.role(for: observation.text, box: observation.box)
                // Wrapped lines often lack a speaker name, action verb or punctuation.
                if role == nil, observation.text.split(separator: " ").count >= 2 {
                    let box = observation.box
                    role = found.last(where: {
                        let gap = box.minY - $0.box.maxY
                        let aligned = abs(box.minX - $0.box.minX) < box.height || abs(box.midX - $0.box.midX) < box.height
                        return aligned && gap >= 0 && gap < box.height * 0.65 && abs(box.height - $0.box.height) < box.height * 0.25
                    })?.role
                }
                if let role { found.append(Detection(role: role, text: observation.text, box: observation.box)) }
            }
            if let pixels { snapshots[zone.role] = Snapshot(pixels: pixels, rect: crop, stride: image.bytesPerRow, lines: found) }
            lines += found
        }
        // An overlapping zone must not draw the same source line twice.
        var unique: [Detection] = []
        for line in lines {
            let duplicate = unique.contains {
                let overlap = $0.box.intersection(line.box)
                return !overlap.isNull && overlap.width * overlap.height > 0.65 * min($0.box.width * $0.box.height, line.box.width * line.box.height)
            }
            if !duplicate { unique.append(line) }
        }
        // Join adjacent lines of a caption so their overlays cannot cover each other.
        var blocks: [Detection] = []
        for line in unique.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let index = blocks.lastIndex(where: {
                let gap = line.box.minY - $0.box.maxY
                return $0.role == line.role && gap >= -line.box.height * 0.25 && gap <= line.box.height * 0.75 &&
                    min($0.box.maxX, line.box.maxX) > max($0.box.minX, line.box.minX)
            }) {
                blocks[index].text += " " + line.text
                blocks[index].box = blocks[index].box.union(line.box)
            } else { blocks.append(line) }
        }
        return (blocks, scanned ? (ProcessInfo.processInfo.systemUptime - start) * 1000 : nil)
    }
}

@MainActor protocol TranslationProvider {
    func translate(_ text: String) async throws -> String
    // How many requests the engine can usefully work on at once. Requests beyond this
    // only queue inside the engine, where the newest caption would wait behind stale ones.
    var maxConcurrentRequests: Int { get }
}

extension TranslationProvider {
    var maxConcurrentRequests: Int { .max }
}

struct DemoProvider: TranslationProvider {
    func translate(_ text: String) async throws -> String { "TR: " + text }
}

enum ProviderChoice: String, CaseIterable, Identifiable {
    case demo = "Çevrimdışı demo"
    case apple = "Apple Çeviri"
    case libre = "LibreTranslate"
    case gemma = "Gemma 4 · Ollama (yerel)"
    var id: Self { self }
    @MainActor func make(address: String, names: String, ollamaModel: String = OllamaTranslator.defaultModel) throws -> any TranslationProvider {
        switch self {
        case .demo: return DemoProvider()
        case .apple: return Translator(endpoint: nil, names: names)
        case .gemma:
            let model = ollamaModel.trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { throw AppFailure("Ollama model adını girin.") }
            return OllamaTranslator(model: model, names: names)
        case .libre:
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil else {
                throw AppFailure("Geçerli bir HTTP veya HTTPS hizmet adresi girin.")
            }
            return Translator(endpoint: url, names: names)
        }
    }
}

struct SubtitleHistory {
    private var cache: [String: String] = [:]
    private var order: [String] = []
    func cached(_ text: String) -> String? { cache[text] }
    mutating func save(_ value: String, for text: String) {
        if cache[text] == nil {
            if order.count >= 256 { cache.removeValue(forKey: order.removeFirst()) }
            order.append(text)
        }
        cache[text] = value
    }
}

@MainActor func movieFrames(_ url: URL, region: CGRect = CGRect(x: 0, y: 0.5, width: 1, height: 0.5), consume: (CGImage) async throws -> Void) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else { throw AppFailure("Video süresi okunamadı.") }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1600, height: 1000)
    generator.requestedTimeToleranceAfter = .zero
    generator.requestedTimeToleranceBefore = .zero
    let clock = ContinuousClock()
    var start = clock.now
    var tick = 0
    while Double(tick) / 4 < duration {
        try Task.checkCancellation()
        let (image, _) = try await generator.image(at: CMTime(value: Int64(tick), timescale: 4))
        if let crop = image.cropping(to: CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height), width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral) {
            try await consume(crop)
        }
        if tick == 0 { start = clock.now }
        let elapsed = start.duration(to: clock.now).components
        tick = max(tick + 1, Int((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 4))
        try await clock.sleep(until: start.advanced(by: .milliseconds(tick * 250)))
    }
}

@MainActor final class Translator: TranslationProvider {
    let endpoint: URL?
    private var session: TranslationSession?
    private lazy var network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    private var names: Set<String>
    init(endpoint: URL?, names: String = "") {
        self.endpoint = endpoint
        self.names = Set(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    func translate(_ text: String) async throws -> String {
        // Keep speaker labels out of both translation engines.
        if let range = text.range(of: #"^(?:\[[^\]]{1,48}\]\s*|[\p{L}][\p{L} .’'-]{0,38}:\s*)"#, options: .regularExpression) {
            let dialogue = String(text[range.upperBound...])
            let name = text[range].trimmingCharacters(in: CharacterSet(charactersIn: "[]: ").union(.whitespaces))
            if !name.isEmpty { names.insert(name) }
            return String(text[range]) + (dialogue.isEmpty ? "" : try await translateDialogue(dialogue))
        }
        return try await translateDialogue(text)
    }
    private func translateDialogue(_ text: String) async throws -> String {
        let candidates = names.filter { text.localizedCaseInsensitiveContains($0) }.sorted { $0.count > $1.count }
        guard !candidates.isEmpty else { return try await translateBody(text) }
        let alternatives = candidates.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let regex = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#, options: .caseInsensitive)
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return try await translateBody(text) }
        // Preserve sentence context first. Retry in fragments if an engine changes a placeholder.
        let masked = source.mutableCopy() as! NSMutableString
        for (index, match) in matches.enumerated().reversed() {
            masked.replaceCharacters(in: match.range, with: "ZXNAME\(index)XZ")
        }
        var result = try await translateBody(masked as String)
        if matches.indices.allSatisfy({ result.contains("ZXNAME\($0)XZ") }) {
            for (index, match) in matches.enumerated() {
                result = result.replacingOccurrences(of: "ZXNAME\(index)XZ", with: source.substring(with: match.range))
            }
            return result
        }
        var pieces = [String]()
        var end = 0
        for match in matches {
            let prefix = source.substring(with: NSRange(location: end, length: match.range.location - end))
            pieces.append(try await translateFragment(prefix))
            pieces.append(source.substring(with: match.range))
            end = NSMaxRange(match.range)
        }
        pieces.append(try await translateFragment(source.substring(from: end)))
        return pieces.joined()
    }
    private func translateFragment(_ fragment: String) async throws -> String {
        guard fragment.rangeOfCharacter(from: .letters) != nil else { return fragment }
        let core = fragment.trimmingCharacters(in: .whitespaces)
        return (fragment.first?.isWhitespace == true ? " " : "") + (try await translateBody(core)) + (fragment.last?.isWhitespace == true ? " " : "")
    }
    private func translateBody(_ text: String) async throws -> String {
        if let endpoint {
            var request = URLRequest(url: endpoint, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["q": text, "source": "en", "target": "tr", "format": "text"])
            let (data, response) = try await network.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = result["translatedText"] as? String, !value.isEmpty else {
                throw AppFailure("Çeviri sunucusu geçerli bir yanıt vermedi. Hizmet adresini kontrol edin.")
            }
            return value
        }
        if session == nil {
            let en = Locale.Language(identifier: "en"), tr = Locale.Language(identifier: "tr")
            switch await LanguageAvailability().status(from: en, to: tr) {
            case .installed: session = TranslationSession(installedSource: en, target: tr)
            case .supported: throw AppFailure("Apple çevirisi için Sistem Ayarları’nda İngilizce ve Türkçe çeviri dillerini indirin.")
            default: throw AppFailure("Apple bu dil çiftini desteklemiyor. LibreTranslate seçebilirsiniz.")
            }
        }
        return try await session!.translate(text).targetText
    }
}

// Local LLM translation through Ollama on this Mac. In a 14-line Witcher/GTA sample,
// Gemma 4 E4B kept names, slang and Turkish suffixes right where Apple Translation did
// not, at about 0.4–1.0 s per line on M4 versus 0.2–0.6 s.
@MainActor final class OllamaTranslator: TranslationProvider {
    static let defaultModel = "gemma4:e4b-it-qat"
    // Ollama serves one request at a time on this machine (n_slots = 1), and Gemma 4's
    // sliding-window attention rules out prompt caching, so every request costs 0.4–0.9 s.
    var maxConcurrentRequests: Int { 1 }
    private static let speakerLabel = #"^(?:\[[^\]]{1,48}\]\s*|[\p{L}][\p{L} .’'-]{0,38}:\s*)"#
    let model: String
    private let endpoint: URL
    private let names: [String]
    private lazy var network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(model: String = defaultModel, names: String = "", endpoint: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.endpoint = endpoint
        self.names = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Loads the model into memory so the first caption does not wait for it.
    func prewarm() {
        let body: [String: Any] = ["model": model, "keep_alive": "30m"]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: endpoint.appending(path: "api/generate"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let network = network
        Task.detached { _ = try? await network.data(for: request) }
    }

    func translate(_ text: String) async throws -> String {
        // Speaker labels stay verbatim, as with the other providers.
        if let range = text.range(of: Self.speakerLabel, options: .regularExpression) {
            let dialogue = String(text[range.upperBound...])
            let label = text[range].trimmingCharacters(in: CharacterSet(charactersIn: "[]: ").union(.whitespaces))
            return String(text[range]) + (dialogue.isEmpty ? "" : try await translateBody(dialogue, speaker: label))
        }
        return try await translateBody(text, speaker: nil)
    }

    private func translateBody(_ text: String, speaker: String?) async throws -> String {
        var kept = ["Geralt", "Ciri", "Roach"] + names
        if let speaker, !speaker.isEmpty { kept.append(speaker) }
        let instructions = """
        You translate English video game subtitles and quest objectives into natural, idiomatic Turkish (Türkiye). \
        Keep character and place names unchanged (\(kept.joined(separator: ", "))). Keep "witcher" as "Witcher". \
        Match the speaker's tone, including slang and swearing. Use the imperative for objectives. \
        Reply with the Turkish translation only, no quotes, no notes.
        """
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "30m",
            "options": ["temperature": 0, "num_predict": 256],
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
        ]
        var request = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            throw AppFailure("Ollama’ya ulaşılamadı. Ollama uygulamasını açın veya Terminal’de “ollama serve” komutunu çalıştırın.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status == 404 {
            throw AppFailure("“\(model)” modeli Ollama’da yok. Terminal’de “ollama pull \(model)” komutuyla indirin.")
        }
        guard (200..<300).contains(status), let message = json?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AppFailure("Ollama geçerli bir çeviri döndürmedi (HTTP \(status)). Model adını kontrol edin.")
        }
        let value = Self.clean(content)
        guard !value.isEmpty else { throw AppFailure("Ollama boş bir çeviri döndürdü. Başka bir model deneyin.") }
        return value
    }

    // Models sometimes wrap the answer in quotes or add a trailing note on a new line.
    static func clean(_ output: String) -> String {
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var value = first.trimmingCharacters(in: .whitespaces)
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")]
        if value.count >= 2, quotes.contains(where: { value.first == $0.0 && value.last == $0.1 }) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
