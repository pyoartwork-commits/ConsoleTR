import AppKit
import AVFoundation
import ScreenCaptureKit
import Combine
import UniformTypeIdentifiers

struct Track: Identifiable, Equatable {
    let id = UUID()
    var line: Detection
    var value: String? {
        didSet { if value != nil, shownAt == nil { shownAt = ProcessInfo.processInfo.systemUptime } }
    }
    // When the translation first appeared on screen.
    private(set) var shownAt: Double?
    // The key of the latest translation request made for this track.
    var requestedKey: String?
    // Newer lines are translated first when the engine has a single slot.
    let since = ProcessInfo.processInfo.systemUptime
    // The key `value` was translated from. It can lag behind `translationKey` while a
    // better OCR reading is being translated; the old value stays visible meanwhile.
    var valueKey: String?
    private struct Reading: Equatable {
        let text: String
        let box: CGRect
    }
    // Recent raw OCR readings. OCR on a moving scene misreads or clips parts of a line on
    // some frames, so the displayed text is the majority of the last readings.
    private var reads: [Reading]
    var translationKey: String { Self.key(for: line.text) }
    var needsTranslation: Bool { valueKey != translationKey }

    init(line: Detection, value: String? = nil) {
        self.line = line
        self.value = value
        valueKey = value == nil ? nil : Self.key(for: line.text)
        shownAt = value == nil ? nil : ProcessInfo.processInfo.systemUptime
        reads = [Reading(text: line.text, box: line.box)]
    }

    // A translation that arrives late must stay long enough to be read once its line is gone.
    static func readingTime(_ text: String) -> Double { min(6, 1.5 + 0.06 * Double(text.count)) }

    // `tolerance` is the box jitter, in normalized units, that must not move the overlay.
    mutating func observe(_ text: String, box: CGRect, tolerance: CGSize) {
        reads.append(Reading(text: text, box: box))
        if reads.count > 5 { reads.removeFirst() }
        // A clipped reading ("Man, what…" for "Lamar: Man, what…") counts for the current text.
        let current = translationKey
        let counts = Dictionary(grouping: reads) { read -> String in
            let key = Self.key(for: read.text)
            return current.contains(key) ? current : key
        }.mapValues(\.count)
        // Ties keep the current text so a single misread cannot restart translation.
        let winner = counts.max { $0.value < $1.value }.flatMap { $0.value > counts[current, default: 0] ? $0.key : nil } ?? current
        func loose(_ rect: CGRect) -> CGRect { rect.insetBy(dx: -tolerance.width, dy: -tolerance.height) }
        if winner != current, let latest = reads.last(where: { Self.key(for: $0.text) == winner }) {
            line.text = latest.text
            line.box = latest.box
        } else if Self.key(for: text) == current {
            // A reading of the shown text places the overlay unless it only jitters.
            line.text = text
            if !loose(line.box).contains(box) || !loose(box).contains(line.box) { line.box = box }
        } else if !loose(line.box).contains(box) {
            // Another reading inside the box is clipped (a colored speaker name or a word lost
            // on a bright patch) and used to shift the overlay sideways, so it changes nothing.
            // One reaching outside the box means the line moved or was read more fully.
            line.box = box
        }
    }

    static func key(for text: String) -> String {
        text.lowercased().split { $0.isWhitespace || $0 == "," || $0 == "." }.joined(separator: " ")
    }

    // Edit-distance similarity of two keys, or 1 when one contains the other.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if min(a.count, b.count) >= 4, String(a).contains(String(b)) || String(b).contains(String(a)) { return 1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }
}

struct RecentTranslation: Identifiable {
    let id = UUID()
    let key: String
    let original: String
    let translation: String
}

@MainActor final class Controller: ObservableObject {
    @Published var live = false
    @Published var provider = ProviderChoice.apple
    @Published var manualRegions = false
    @Published var objectiveRegion = CGRect(x: 0.55, y: 0.10, width: 0.45, height: 0.40)
    @Published var enabled = true {
        didSet {
            if enabled { receive(lastLines) } else { clearTracks() }
        }
    }
    @Published var shortcutEnabled = true { didSet { configureShortcut() } }
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var recent: [RecentTranslation] = []
    let shortcut = GlobalShortcut()
    private var overlays: [UUID: Overlay] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var lastLines: [Detection] = []
    private var expiry: [UUID: Task<Void, Never>] = [:]
    private var overlayLevel = NSWindow.Level.floating
    private var captureRect: CGRect?
    private var anchor: CGRect?
    private var engine: (any TranslationProvider)?
    @Published var names = ""
    @Published var address = "http://localhost:5000/translate"
    @Published var ollamaModel = OllamaTranslator.defaultModel
    @Published var video = Bundle.main.url(forResource: "Deneme", withExtension: "mp4")
    @Published var targets: [CaptureTarget] = []
    @Published var selection = ""
    @Published var x = 0
    @Published var y = 50
    @Published var width = 100
    @Published var height = 50
    @Published var running = false
    @Published var loading = false
    @Published var status = "Hazır"
    @Published var original = ""
    @Published var translated = ""
    @Published var ocrMS = 0.0
    @Published var translationMS = 0.0
    @Published var needsPermission = false
    @Published var style = OverlayStyle() {
        didSet {
            for overlay in overlays.values { overlay.style = style }
            if oldValue.subtitleBand != style.subtitleBand, running { render() }
        }
    }
    // Every caption has its own box, so translations placed next to each line moved with every
    // new line. Lower-half captions share one band above them; only its text changes.
    private let bandKey = UUID()
    private var bandSamples: [(time: Double, top: CGFloat)] = []
    private var bandTop: CGFloat?
    private var trackingTask: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var capture: LiveCapture?
    private var generation = UUID()
    private var reader = SubtitleReader()
    private var history = SubtitleHistory()
    private(set) var translations = 0, hits = 0

    // Start loading the accurate OCR model at launch, before the user presses start.
    init() { SubtitleReader.prewarm() }

    func previewImage() async throws -> CGImage {
        if live, let target = targets.first(where: { $0.id == selection }) {
            let config = SCStreamConfiguration()
            let size = target.filter.contentRect.size
            config.width = 900
            config.height = max(1, Int(900 * size.height / max(size.width, 1)))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: config)
        }
        guard !live, let video else { throw AppFailure("Önce yakalama kaynağını seçin.") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 650)
        return try await generator.image(at: .zero).image
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.prompt = "Seç"
        if panel.runModal() == .OK { video = panel.url }
    }
    private let picker = WindowPicker()
    private var selectedWithPicker: CaptureTarget?
    private var returningFromSettings = false
    @Published var picking = false

    func chooseWindow() {
        guard !running, !loading, !picking else { return }
        picking = true
        picker.present { [weak self] outcome in
            guard let self else { return }
            picking = false
            switch outcome {
            case .selected(let target):
                targets.removeAll { $0.id == target.id }
                targets.append(target)
                selectedWithPicker = target
                selection = target.id
                status = "Seçilen pencere hazır."
            case .cancelled: status = "Pencere seçimi iptal edildi."
            case .failed(let error): status = (error as? AppFailure)?.message ?? "Sistem seçicisi açılamadı. Hata kodu: \((error as NSError).code)"
            }
        }
    }

    func closePicker() {
        picker.close()
        picking = false
    }

    func openCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        returningFromSettings = NSWorkspace.shared.open(url)
    }

    func becameActive() async {
        guard returningFromSettings, live, !running else { return }
        returningFromSettings = false
        await refresh()
    }

    func refresh(list: () async throws -> [CaptureTarget] = CaptureTarget.list) async {
        guard !running, !loading, !picking else { return }
        loading = true
        defer { loading = false }
        do {
            targets = try await list()
            needsPermission = false
            if !targets.contains(where: { $0.id == selection }) {
                selection = Self.preferredSource(targets.map { ($0.id, $0.isRemotePlay, $0.area) }) ?? ""
            }
            status = targets.isEmpty ? "Açık pencere veya ekran bulunamadı." : "Kaynaklar hazır."
        } catch {
            targets = selectedWithPicker.map { [$0] } ?? []
            selection = targets.first?.id ?? ""
            let failure = error as NSError
            needsPermission = failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue
            if needsPermission {
                status = "macOS bu ConsoleTR kopyasının kaynakları listelemesine izin vermedi. Sistem seçicisinden bir pencere seçebilir veya ekran kaydı ayarlarını açabilirsiniz."
            } else {
                status = "Kaynak listesi alınamadı (\(failure.domain), \(failure.code)). Yeniden deneyin veya sistem seçicisinden bir pencere seçin."
            }
        }
    }
    // Remote Play's video window is its largest; its other windows are dialogs and toolbars.
    static func preferredSource(_ candidates: [(id: String, isRemotePlay: Bool, area: CGFloat)]) -> String? {
        candidates.filter { $0.isRemotePlay }.max { $0.area < $1.area }?.id ?? candidates.first?.id
    }

    func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        lastLines = []
        clearTracks()
        engine = nil
        generation = UUID()
        job?.cancel()
        job = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        running = false
        status = "Durduruldu."
    }
    func start(using translationProvider: (any TranslationProvider)? = nil) {
        guard !running else { return }
        let target = targets.first { $0.id == selection }
        guard live ? target != nil : video != nil else { status = "Önce bir kaynak seçin."; return }
        guard !manualRegions || (x >= 0 && y >= 0 && width > 0 && height > 0 && width <= 100 && height <= 100 && x <= 100 - width && y <= 100 - height) else {
            status = "Seçilen alan ekranın sınırları içinde kalmalı."; return
        }
        let subtitle = CGRect(x: Double(x)/100, y: Double(y)/100, width: Double(width)/100, height: Double(height)/100)
        let token = UUID()
        generation = token
        do { engine = try translationProvider ?? provider.make(address: address, names: names, ollamaModel: ollamaModel) }
        catch { status = error.localizedDescription; return }
        (engine as? OllamaTranslator)?.prewarm()
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let zones = manualRegions
            ? [ScanZone(role: .subtitle, rect: subtitle), ScanZone(role: .objective, rect: objectiveRegion)]
            : [ScanZone(role: nil, rect: region)]
        history = SubtitleHistory()
        bandSamples = []
        bandTop = nil
        reader = SubtitleReader()
        translations = 0; hits = 0
        recent = []
        translationMS = 0; ocrMS = 0
        original = ""; translated = ""
        status = "Altyazı bekleniyor…"
        running = true
        let isLive = live
        let screen = isLive ? NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target?.displayID } : NSScreen.main
        moveOverlays(to: screen?.visibleFrame)
        job = Task {
            guard generation == token, !Task.isCancelled else { return }
            do {
                if isLive, let target {
                    let source = LiveCapture()
                    capture = source
                    try await source.start(target, region: region)
                    if generation != token { await source.stop(); return }
                    captureRect = nil
                    let initial = target.placement(lastFrame: nil, captureRect: nil)
                    moveOverlays(to: initial.frame, level: initial.level)
                    if target.windowID != nil {
                        trackingTask = Task {
                            var lastSize = initial.frame?.size
                            while !Task.isCancelled, generation == token {
                                let placement = target.placement(lastFrame: anchor, captureRect: captureRect)
                                let frame = placement.frame
                                moveOverlays(to: frame, level: placement.level)
                                if let size = frame?.size, size != lastSize, size.width > 1, size.height > 1 {
                                    do {
                                        try await source.resize(target, size: size, region: region)
                                        lastSize = size
                                    } catch {
                                        guard generation == token else { return }
                                        stop()
                                        status = "Yakalama alanı güncellenemedi. Pencereyi yeniden seçin."
                                        return
                                    }
                                }
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        }
                    }
                    for try await frame in source.frames {
                        switch frame {
                        case .image(let image, let rect):
                            if let rect, !rect.isEmpty { captureRect = rect }
                            try await process(image, zones: zones, token: token)
                        case .empty: if generation == token { receive([]) }
                        }
                    }
                } else if let video {
                    try await movieFrames(video, region: region) { image in
                        try await self.process(image, zones: zones, token: token)
                    }
                }
                guard generation == token else { return }
                stop()
                status = isLive ? "Yakalama sona erdi." : "Video tamamlandı."
            } catch {
                guard generation == token else { return }
                stop()
                status = (error as? AppFailure)?.message ?? "İşlem tamamlanamadı. \(provider == .libre ? "Çeviri sunucusunun erişilebilir olduğunu kontrol edin." : provider == .gemma ? "Ollama’nın açık olduğunu kontrol edin." : "Kaynağı ve çeviri ayarlarını kontrol edin.") Hata kodu: \((error as NSError).code)"
            }
        }
    }
    private func moveOverlays(to frame: CGRect?, level: NSWindow.Level = .floating) {
        overlayLevel = level
        anchor = frame
        for overlay in overlays.values { overlay.move(to: frame, level: level) }
    }

    func configureShortcut() {
        shortcut.remove()
        guard shortcutEnabled else { return }
        shortcut.toggle = { [weak self] in self?.enabled.toggle() }
        if !shortcut.install() { status = "⌃⌥T kaydedilemedi. Çeviriyi ana pencereden açıp kapatabilirsiniz." }
    }

    private func clearTracks() {
        for overlay in overlays.values { overlay.hide() }
        overlays.removeAll()
        for task in expiry.values { task.cancel() }
        expiry.removeAll()
        tracks.removeAll()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        original = ""
        translated = ""
    }

    private func process(_ frame: CGImage, zones: [ScanZone], token: UUID) async throws {
        try Task.checkCancellation()
        let result = try await reader.read(frame, zones: zones)
        guard token == generation else { return }
        if let elapsed = result.milliseconds { ocrMS = elapsed }
        receive(result.lines)
    }

    private func receive(_ lines: [Detection]) {
        lastLines = lines
        guard enabled, engine != nil else { return }
        var remaining = tracks
        var next: [Track] = []
        for line in lines {
            // Match the closest occurrence; identical text can appear in two places.
            let key = Track.key(for: line.text)
            let candidates = remaining.indices.filter { remaining[$0].line.role == line.role && remaining[$0].translationKey == key }
            var matched = candidates.min {
                func distance(_ index: Int) -> Double {
                    let old = remaining[index].line.box
                    return hypot(old.midX - line.box.midX, old.midY - line.box.midY)
                }
                return distance($0) < distance($1)
            }
            if matched == nil {
                // An OCR variant of a line at the same place keeps that line's track, overlay
                // and pending translation. Its role can flip with the misread, so ignore role.
                let scored = remaining.indices.compactMap { index -> (Int, Double)? in
                    let old = remaining[index].line.box
                    guard old.insetBy(dx: -old.height, dy: -old.height * 0.5).intersects(line.box) else { return nil }
                    let score = Track.similarity(remaining[index].translationKey, key)
                    return score >= 0.6 ? (index, score) : nil
                }
                matched = scored.max { $0.1 < $1.1 }?.0
            }
            if let matched {
                var track = remaining.remove(at: matched)
                expiry.removeValue(forKey: track.id)?.cancel()
                // Half a line height, at least 4 px, of OCR box jitter keeps the overlay still.
                let size = anchor?.size ?? CGSize(width: 1600, height: 900)
                let jitter = max(4, track.line.box.height * size.height * 0.5)
                track.observe(line.text, box: line.box, tolerance: CGSize(width: jitter / size.width, height: jitter / size.height))
                next.append(track)
            } else {
                let cached = history.cached(key)
                if cached != nil { hits += 1 }
                next.append(Track(line: line, value: cached))
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for lost in remaining {
            // Without a translation there is nothing to read, so a replacement wins at once.
            let replaced = lines.contains { $0.role == lost.line.role && $0.box.intersects(lost.line.box) }
            if replaced && lost.value == nil {
                expiry.removeValue(forKey: lost.id)?.cancel()
                overlays.removeValue(forKey: lost.id)?.hide()
                continue
            }
            next.append(lost)
            guard expiry[lost.id] == nil else { continue }
            // A missed OCR sample gets 650 ms. A shown translation stays until it has been on
            // screen for its reading time, or until a newer translation takes its place (render).
            let delay = lost.value.flatMap { value in lost.shownAt.map { max(0.65, Track.readingTime(value) - (now - $0)) } } ?? 0.65
            expiry[lost.id] = Task {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                expiry.removeValue(forKey: lost.id)
                tracks.removeAll { $0.id == lost.id }
                overlays.removeValue(forKey: lost.id)?.hide()
                render()
                requestTranslations()
            }
        }
        let bandMoved = updateBand(next)
        if tracks != next || bandMoved {
            tracks = next
            render()
        }
        requestTranslations()
    }

    // Lines on screen first, then untranslated ones, captions before objectives.
    private func priority(_ track: Track) -> (Int, Int, Int) {
        (expiry[track.id] == nil ? 1 : 0, track.value == nil ? 1 : 0, track.line.role == .subtitle ? 1 : 0)
    }

    private func requestTranslations() {
        // Keep a request while its track exists, even if a newer reading came in since.
        let wanted = Set(tracks.flatMap { [$0.translationKey, $0.requestedKey].compactMap { $0 } })
        for key in Array(pending.keys) where !wanted.contains(key) {
            pending.removeValue(forKey: key)?.cancel()
        }
        guard enabled, let engine else { return }
        var reused = false
        for index in tracks.indices where tracks[index].needsTranslation {
            // A switch to a reading translated earlier needs no new request.
            guard let cached = history.cached(tracks[index].translationKey) else { continue }
            tracks[index].value = cached
            tracks[index].valueKey = tracks[index].translationKey
            hits += 1
            reused = true
        }
        if reused { render() }
        func keyPriority(_ key: String) -> (Int, Int, Int) {
            tracks.filter { $0.translationKey == key || $0.requestedKey == key }.map(priority).max { $0 < $1 } ?? (-1, -1, -1)
        }
        // With a single-slot engine (Ollama) every queued request delays the next caption, so
        // the newest caption on screen goes first and anything less important yields to it.
        let queue = tracks.filter(\.needsTranslation).sorted {
            let a = priority($0), b = priority($1)
            return a != b ? a > b : $0.since > $1.since
        }
        for track in queue where pending[track.translationKey] == nil {
            if pending.count >= engine.maxConcurrentRequests {
                guard let weakest = pending.keys.min(by: { keyPriority($0) < keyPriority($1) }),
                      keyPriority(weakest) < priority(track) else { break }
                pending.removeValue(forKey: weakest)?.cancel()
            }
            request(track, from: engine)
        }
    }

    private func request(_ track: Track, from engine: any TranslationProvider) {
        let text = track.line.text, key = track.translationKey, token = generation
        for index in tracks.indices where tracks[index].translationKey == key { tracks[index].requestedKey = key }
        pending[key] = Task {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let value = try await engine.translate(text)
                guard !Task.isCancelled, token == generation else { return }
                pending.removeValue(forKey: key)
                history.save(value, for: key)
                translations += 1
                translationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                // A track whose reading changed while waiting shows this result until the
                // newer reading is translated.
                for index in tracks.indices where tracks[index].translationKey == key ||
                    (tracks[index].requestedKey == key && tracks[index].needsTranslation) {
                    tracks[index].value = value
                    tracks[index].valueKey = key
                }
                render()
                requestTranslations()
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                stop()
                status = (error as? AppFailure)?.message ?? "Çeviri sağlayıcısına ulaşılamadı. Hizmet adresini ve sunucuyu kontrol edin."
            }
        }
    }

    private func inBand(_ track: Track) -> Bool {
        style.subtitleBand && track.line.role == .subtitle && track.line.box.midY >= 0.5
    }

    // The band sits just above the tallest caption of the last 10 s and ignores OCR jitter.
    private func updateBand(_ lines: [Track]) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        for track in lines where expiry[track.id] == nil && inBand(track) { bandSamples.append((now, track.line.box.minY)) }
        bandSamples.removeAll { now - $0.time > 10 }
        guard let top = bandSamples.map(\.top).min() else { return false }
        if let bandTop, abs(top - bandTop) * (anchor?.height ?? 900) < 8 { return false }
        bandTop = top
        return true
    }

    private func render() {
        // A newer translation over the place of a line that is gone replaces it.
        let onScreen = tracks.filter { expiry[$0.id] == nil }
        let covered = Set(tracks.filter { old in
            expiry[old.id] != nil && onScreen.contains { $0.value != nil && $0.line.box.intersects(old.line.box) }
        }.map(\.id))
        for id in covered {
            expiry.removeValue(forKey: id)?.cancel()
            overlays.removeValue(forKey: id)?.hide()
        }
        if !covered.isEmpty { tracks.removeAll { covered.contains($0.id) } }
        original = onScreen.map { $0.line.text }.joined(separator: "\n")
        translated = onScreen.compactMap(\.value).joined(separator: "\n")
        // Keep the latest pairs in memory so a translation can be checked after it is gone.
        for track in onScreen {
            guard let value = track.value, let key = track.valueKey, !recent.contains(where: { $0.key == key }) else { continue }
            recent.insert(RecentTranslation(key: key, original: track.line.text, translation: value), at: 0)
            if recent.count > 8 { recent.removeLast() }
        }
        func overlay(_ key: UUID) -> Overlay {
            if let existing = overlays[key] { return existing }
            let created = Overlay()
            overlays[key] = created
            created.style = style
            created.move(to: anchor, level: overlayLevel)
            return created
        }
        for track in tracks {
            guard let value = track.value else { continue }
            if inBand(track) {
                overlays.removeValue(forKey: track.id)?.hide()
                continue
            }
            overlay(track.id).show(value, box: track.line.box)
        }
        // The band shows the newest caption on screen, or the newest one still being read.
        let band = tracks.filter { inBand($0) && $0.value != nil }
        if let shown = band.filter({ expiry[$0.id] == nil }).max(by: { $0.since < $1.since }) ?? band.max(by: { $0.since < $1.since }),
           let value = shown.value, let bandTop {
            overlay(bandKey).show(value, box: CGRect(x: 0.1, y: bandTop, width: 0.8, height: 0), above: true)
        } else {
            overlays.removeValue(forKey: bandKey)?.hide()
        }
        status = tracks.isEmpty ? "Metin bekleniyor…" : "Metinler izleniyor."
    }
}
