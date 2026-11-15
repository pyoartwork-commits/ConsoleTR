# ConsoleTR

Oyun penceresindeki İngilizce altyazıları ve görev bildirimlerini okuyup Türkçe çevirisini yazının hemen yanında gösteren, açık kaynaklı bir masaüstü uygulaması. İlk hedef PS Remote Play üzerinden oynanan **The Witcher 3** ve **GTA**.

> **Durum: erken sürüm (0.1).** macOS sürümü otomatik testlerden geçiyor ve gerçek bir Remote Play oturumunda kısmen denendi. **Windows sürümü deneyseldir:** GitHub Actions'ta derleniyor ve ortak mantığın testleri çalışıyor, ama gerçek bir Windows bilgisayarda henüz denenmedi. Deneyip sonucu [issue](../../issues) olarak bildirmeniz en büyük katkı olur.

*English summary at the end.*

## Ne yapar?

1. Seçtiğiniz pencereyi (ör. PS Remote Play) saniyede 4 kez yakalar.
2. Cihazın kendi metin tanımasıyla (macOS: Vision, Windows: Windows OCR) İngilizce satırları bulur.
3. Satırın altyazı mı, görev bildirimi mi, yoksa menü/arayüz yazısı mı olduğunu ayırt eder; menü başlıkları gibi yazıları çevirmez.
4. Satırları kareler arasında izler, Türkçeye çevirir ve çeviriyi oyunun üzerinde, ilgili yazının yanında gösterir.
5. Çeviri, kaynak satır kaybolsa bile okunacak kadar (1,5–6 sn) ekranda kalır; son 8 çeviri ana pencerede listelenir.

Otomatik algılama tutmazsa **manuel alan** seçeneğiyle altyazı ve görev alanını elle belirleyebilirsiniz.

## Gizlilik

- Ekran görüntüleri ve okunan metinler **diske kaydedilmez**, yalnızca bellekte işlenir.
- Apple Çeviri ve Ollama (Gemma) seçeneklerinde metin **bilgisayarınızdan çıkmaz**.
- LibreTranslate seçeneğinde metin, adresini sizin girdiğiniz sunucuya gönderilir.
- Uygulamada telemetri, analiz veya otomatik güncelleme yoktur.

## Çeviri sağlayıcıları

| Sağlayıcı | Platform | Nerede çalışır | Not |
|---|---|---|---|
| Apple Çeviri | macOS | Cihazda | macOS'ta varsayılan; en hızlısı (~0,4 sn). |
| Gemma 4 · Ollama | macOS, Windows | Cihazda | Daha doğal Türkçe, ~0,6–1 sn. Windows'ta varsayılan. [Ollama](https://ollama.com) ve `ollama pull gemma4:e4b-it-qat` gerekir (~6 GB). |
| LibreTranslate | macOS, Windows | Seçtiğiniz sunucu | Kendi sunucunuzu kurabilirsiniz. |
| Çevrimdışı demo | macOS, Windows | Cihazda | Metnin başına “TR:” ekler; algılamayı çeviri gecikmesinden ayrı denemek için. |

## macOS

**Gereksinimler:** Apple Silicon Mac, macOS 26 veya üzeri, Xcode 26.

```bash
cd macos
./build.sh                 # ConsoleTR.app'i macos/ klasörüne derler
open ConsoleTR.app
```

- İlk açılışta **Ekran Kaydı** izni istenir (Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı).
- Apple Çeviri için Sistem Ayarları'ndan İngilizce ve Türkçe çeviri dillerini indirin.
- Uygulama imzasız derlenir; Gatekeeper uyarısında uygulamaya sağ tıklayıp **Aç**'ı seçin.
- Uygulamayı yeni bir klasöre taşıdıktan sonraki ilk açılışta metin tanıma modelinin yüklenmesi ~30 sn sürer; bu sırada daha basit tanıma kullanılır.

**Testler** (ekran kaydı izni ve Apple Çeviri dilleri gerekir; Ollama testi Ollama yoksa kendini atlar):

```bash
macos/Tests/run.sh
```

## Windows (deneysel)

**Gereksinimler:** Windows 10 (2004) veya Windows 11, [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), [Ollama](https://ollama.com) (Gemma için).

```powershell
cd windows
dotnet test tests/ConsoleTR.Core.Tests
dotnet run --project src/ConsoleTR.App -c Release
```

Derlenmiş deneme sürümü: [Actions](../../actions) sekmesinde son başarılı “CI” çalışmasının **ConsoleTR-windows-x64-unsigned** artefaktı. İmzasızdır; Windows SmartScreen uyarı verebilir.

- Türkçe Windows'ta İngilizce metin tanıma paketi yüklü olmayabilir. Uygulama bunu söyler; Ayarlar > Saat ve dil > Dil ve bölge bölümünden “English (United States)” ekleyin.
- Oyun **pencereli** veya **kenarlıksız pencere** modunda olmalı; tam ekran özel moddaki oyunların üzerine katman çizilemez.
- Ctrl + Alt + T çeviriyi açıp kapatır.

## Proje yapısı

```
macos/      Swift 6 · SwiftUI · ScreenCaptureKit · Vision · Apple Translation
windows/    C# · .NET 10 · WPF · Windows OCR
  src/ConsoleTR.Core    Platformdan bağımsız mantık (sınıflandırma, takip, çeviri sırası)
  src/ConsoleTR.App     Windows uygulaması (yakalama, OCR, katmanlar)
  tests/                Ortak mantığın birim testleri
```

Algılama ve takip kuralları iki platformda aynıdır: `macos/Sources/Core.swift` + `Controller.swift` ile `windows/src/ConsoleTR.Core` birlikte değiştirilmelidir.

## Bilinen sınırlamalar

- Çeviri hızı sağlayıcıya bağlıdır; Gemma ile satır başına ~0,5–0,9 sn modelin kendi süresidir.
- Oyuna özgü terimler ve çok kısa satırlar yanlış çevrilebilir. “Son çeviriler” listesinden kontrol edip örnekleri issue olarak paylaşabilirsiniz.
- Windows'ta farklı DPI'lı çoklu monitörde katman konumu kayabilir.

## Katkı

Katkılarınızı bekliyoruz. Başlamadan önce [CONTRIBUTING.md](CONTRIBUTING.md) ve [SECURITY.md](SECURITY.md) dosyalarını okuyun. Güvenlik açıklarını herkese açık issue olarak değil, SECURITY.md'deki yolla bildirin.

## Lisans ve ticari markalar

[MIT](LICENSE). ConsoleTR bağımsız bir topluluk projesidir; Sony Interactive Entertainment, CD PROJEKT RED veya Rockstar Games ile bağlantılı değildir. PlayStation, PS Remote Play, The Witcher ve Grand Theft Auto ilgili sahiplerinin ticari markalarıdır.

---

## English summary

ConsoleTR reads English subtitles and quest notifications from a game window (e.g. PS Remote Play) with on-device OCR, tells captions from objectives and menu text, and draws a Turkish translation next to the source line. Translation runs on-device (Apple Translation on macOS, Gemma 4 via Ollama on macOS and Windows) or on a LibreTranslate server you choose. Screenshots and text are never written to disk. The macOS app (Swift 6) is tested; the Windows app (.NET 10, WPF, Windows OCR) builds in CI but has not yet been tried on real hardware, so test reports are very welcome. Code identifiers and comments are in English; the UI is Turkish. MIT licensed.
