import SwiftUI

struct Controls: View {
    @ObservedObject var model: Controller
    @State private var role = TextRole.subtitle
    @State private var selectingRegion = false
    @State private var showRecent = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ConsoleTR").font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Picker("Kaynak", selection: $model.live) {
                    Text("Yerel video").tag(false)
                    Text("Pencere veya ekran").tag(true)
                }.pickerStyle(.segmented)
                if model.live {
                    HStack {
                        Picker("Yakalama kaynağı", selection: $model.selection) {
                            if model.targets.isEmpty { Text("Kaynak seçin").tag("") }
                            ForEach(model.targets) { Text($0.title).tag($0.id) }
                        }
                        Button(model.loading ? "Aranıyor…" : "Kaynakları getir") { Task { await model.refresh() } }.disabled(model.loading || model.picking)
                    }
                    if model.targets.first(where: { $0.id == model.selection })?.kind == .obsMain {
                        Text("OBS’in ana penceresi seçili: ConsoleTR oyunu küçük önizlemeden ve OBS’in kendi yazılarıyla birlikte okur. Oyun için “Projektör” penceresini seçin.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("macOS ile pencere seç…") { model.chooseWindow() }.disabled(model.loading || model.picking)
                    if model.needsPermission {
                        Button("Ekran kaydı ayarlarını aç") { model.openCaptureSettings() }
                    }
                } else {
                    HStack {
                        Text(model.video?.lastPathComponent ?? "Video seçilmedi")
                        Spacer()
                        Button("Video seç…") { model.pick() }
                    }
                }
                Picker("Tarama", selection: $model.manualRegions) {
                    Text("Otomatik · Tüm görüntü").tag(false)
                    Text("Manuel alanlar").tag(true)
                }.pickerStyle(.segmented)
                if model.manualRegions {
                    HStack {
                        Picker("İzlenen bölge", selection: $role) { ForEach(TextRole.allCases) { Text($0.rawValue).tag($0) } }
                        Spacer()
                        Button("Görüntüden alan seç…") { selectingRegion = true }
                            .disabled(model.live ? model.selection.isEmpty : model.video == nil)
                    }
                    if role == .subtitle { HStack {
                        field("Sol", $model.x); field("Üst", $model.y)
                        field("Genişlik", $model.width); field("Yükseklik", $model.height)
                    }
                    } else {
                        HStack {
                            Text("Görev bildirimi").font(.caption)
                            Button("Sol üst") { model.objectiveRegion = CGRect(x: 0, y: 0.04, width: 0.50, height: 0.45) }
                            Button("Sağ üst") { model.objectiveRegion = CGRect(x: 0.55, y: 0.10, width: 0.45, height: 0.40) }
                        }
                    }
                }
                SettingsLink { Text("Çeviri sağlayıcısı ve kısayol…") }
            }.disabled(model.running)
            Toggle("Çeviriyi göster", isOn: $model.enabled)
            DisclosureGroup("Katman görünümü") {
                Grid(alignment: .leading) {
                    GridRow { Text("Yazı boyutu"); Slider(value: $model.style.fontSize, in: 18...64, step: 1); Text("\(Int(model.style.fontSize)) pt") }
                    GridRow { Text("Metinden uzaklık"); Slider(value: $model.style.position, in: 0...40); Text("\(Int(model.style.position)) pt") }
                    GridRow { Text("Arka plan opaklığı"); Slider(value: $model.style.opacity, in: 0...1); Text("%\(Int(model.style.opacity * 100))") }
                }
                Toggle("Açık renk arka plan", isOn: $model.style.lightBackground)
                Toggle("Altyazı çevirisini altta sabit şeritte göster", isOn: $model.style.subtitleBand)
                if model.style.subtitleBand {
                    HStack {
                        Text("Şeridin alttan uzaklığı")
                        Slider(value: $model.style.bandBottom, in: 0...0.4)
                        Text("%\(Int(model.style.bandBottom * 100))")
                    }
                }
            }
            HStack {
                Button(model.running ? "Durdur" : "Başlat") { if model.running { model.stop() } else { model.start() } }
                    .keyboardShortcut(.defaultAction)
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("Son işlem · OCR \(model.ocrMS, specifier: "%.0f") ms · Çeviri \(model.translationMS, specifier: "%.0f") ms").font(.caption)
            ForEach(model.tracks.prefix(6)) { track in
                LabeledContent(track.line.role.rawValue, value: track.value ?? track.line.text)
            }
            if !model.recent.isEmpty {
                DisclosureGroup("Son çeviriler", isExpanded: $showRecent) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.recent) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.translation)
                                    Text(item.original).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 220)
                }
            }
        }.padding(24).frame(width: 620)
            .sheet(isPresented: $selectingRegion) { RegionPicker(model: model, role: role) }
    }
    private func field(_ title: String, _ value: Binding<Int>) -> some View {
        HStack { Text(title); TextField(title, value: value, format: .number).labelsHidden().frame(width: 44) }
    }
}

private struct RegionPicker: View {
    let role: TextRole
    init(model: Controller, role: TextRole) { self.model = model; self.role = role }
    @ObservedObject var model: Controller
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var message = "Önizleme hazırlanıyor…"
    @State private var selection: CGRect = .zero
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(role.rawValue) alanını sürükleyerek seçin").font(.headline)
            if let image {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable()
                        Rectangle().fill(.blue.opacity(0.22)).border(.white, width: 2)
                            .frame(width: selection.width * size.width, height: selection.height * size.height)
                            .offset(x: selection.minX * size.width, y: selection.minY * size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        func point(_ raw: CGPoint) -> CGPoint {
                            CGPoint(x: min(1, max(0, raw.x / size.width)), y: min(1, max(0, raw.y / size.height)))
                        }
                        let a = point(drag.startLocation), b = point(drag.location)
                        selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
                    })
                }
                .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                .frame(maxHeight: 450)
            } else { Text(message) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                Button("Alanı kullan") {
                    if role == .objective { model.objectiveRegion = selection; dismiss(); return }
                    let left = Int(floor(selection.minX * 100)), top = Int(floor(selection.minY * 100))
                    model.x = left; model.y = top
                    model.width = min(100, Int(ceil(selection.maxX * 100))) - left
                    model.height = min(100, Int(ceil(selection.maxY * 100))) - top
                    dismiss()
                }.disabled(image == nil || selection.width < 0.01 || selection.height < 0.01)
            }
        }.padding(20).frame(width: 640)
        .task {
            selection = CGRect(x: Double(model.x)/100, y: Double(model.y)/100, width: Double(model.width)/100, height: Double(model.height)/100)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if role == .objective { selection = model.objectiveRegion }
            if selection.isNull { selection = .zero }
            do { image = try await model.previewImage() }
            catch { message = "Önizleme alınamadı. Kaynağı yeniden seçin veya alanı yüzde olarak girin." }
        }
    }
}

@main struct ConsoleTRApp: App {
    @StateObject private var model = Controller()
    var body: some Scene {
        Window("ConsoleTR", id: "main") {
            Controls(model: model)
                .environment(\.locale, Locale(identifier: "tr_TR"))
                .onAppear { model.configureShortcut() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.becameActive() } }
                .onDisappear { model.stop(); model.closePicker(); model.shortcut.remove() }
        }.windowResizability(.contentSize)
        Settings {
            Form {
                Section("Çeviri sağlayıcısı") {
                    Picker("Sağlayıcı", selection: $model.provider) {
                        ForEach(ProviderChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.provider == .demo { Text("Demo, algılanan metnin başına “TR:” ekler.").font(.caption) }
                    else { TextField("Korunacak karakter adları", text: $model.names) }
                    if model.provider == .libre {
                        TextField("Sunucu adresi", text: $model.address)
                        Text("Algılanan metin seçtiğiniz sunucuya gönderilir.").font(.caption)
                    }
                    if model.provider == .gemma {
                        TextField("Ollama modeli", text: $model.ollamaModel)
                        Text("Çeviri bu Mac’te Ollama ile yapılır, metin dışarı gönderilmez. Daha doğal Türkçe verir ama Apple Çeviri’den yavaştır. Ollama açık olmalı; model yoksa Terminal’de “ollama pull \(model.ollamaModel)” ile indirin.").font(.caption)
                    }
                    if model.running { Text("Sağlayıcıyı değiştirmek için izlemeyi durdurun.").font(.caption) }
                }.disabled(model.running)
                Section("Klavye kısayolu") {
                    Toggle("⌃⌥T ile çeviriyi aç/kapat", isOn: $model.shortcutEnabled)
                }
            }.formStyle(.grouped).frame(width: 420)
        }
    }
}
