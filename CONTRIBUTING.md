# Katkı rehberi

ConsoleTR'ye katkı vermek istediğiniz için teşekkürler. Hata bildirimleri, gerçek oyunda yapılan testler, çeviri örnekleri ve kod katkılarının hepsi değerlidir.

## Nereden başlamalı?

- **Test edin:** Özellikle Windows sürümünü gerçek bir bilgisayarda deneyip sonucu issue olarak yazmak şu an en çok ihtiyaç duyulan katkı.
- **Örnek paylaşın:** Yanlış algılanan veya çevrilen satırları, oyun adıyla birlikte metin olarak paylaşın. Kişisel bilgi içeren ekran görüntüsü eklemeyin.
- **Kod:** Küçük ve odaklı pull request'ler tercih edilir. Büyük değişiklikler için önce bir issue açıp tartışalım.

## Geliştirme ortamı

- **macOS:** Xcode 26, macOS 26, Apple Silicon. `cd macos && ./build.sh`, testler `macos/Tests/run.sh`.
- **Windows:** .NET 10 SDK. `cd windows && dotnet test tests/ConsoleTR.Core.Tests && dotnet build ConsoleTR.Windows.slnx`.
  Ortak mantık (`ConsoleTR.Core`) ve testleri macOS ve Linux'ta da derlenip çalışır.

## Kurallar

- Kod, tanımlayıcılar ve kod yorumları **İngilizce**; kullanıcı arayüzü metinleri **Türkiye Türkçesi**.
- Metin işlemlerinde kültürden bağımsız dönüşüm kullanın (`ToLowerInvariant`, `StringComparison.Ordinal`). Türkçe Windows'ta `"I".ToLower()` sonucu `"ı"` olur.
- Algılama veya takip kuralını değiştirirseniz iki platformu birlikte güncelleyin (`macos/Sources/Core.swift`, `macos/Sources/Controller.swift` ↔ `windows/src/ConsoleTR.Core`) ve test ekleyin.
- Davranış değişikliği içeren her PR bir test içermelidir.

## Güvenlik kuralları (PR'lar bu yüzden ayrıntılı incelenir)

ConsoleTR ekran kaydı izniyle çalıştığı için şu değişiklikler bakımcı onayı olmadan kabul edilmez:

- Yeni bir ağ adresi, telemetri, analiz veya otomatik güncelleme eklemek.
- Ekran görüntülerini veya okunan metni varsayılan olarak diske yazmak.
- Ollama bağlantısını `localhost` dışına açmak.
- Yeni bir paket bağımlılığı eklemek (gerekçesiyle birlikte önerin).
- `.github/workflows` altındaki dosyaları değiştirmek.
- Derlenmiş dosya (`.app`, `.exe`, `.dll`, arşiv) eklemek. Depoya yalnızca kaynak kod girer.

## Pull request süreci

1. Depoyu fork'layın, bir dal açın.
2. Değişikliğinizi yapın, testleri çalıştırın.
3. PR şablonundaki kontrol listesini doldurun; gerçek oyunda denediyseniz hangi oyun ve sahne olduğunu yazın.
4. CI'nın geçmesini ve bir bakımcının incelemesini bekleyin.

Katkıda bulunarak katkınızın [MIT lisansı](LICENSE) altında yayınlanmasını kabul etmiş olursunuz.
