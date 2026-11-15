# Güvenlik politikası

## Açık bildirme

Güvenlik açıklarını **herkese açık issue olarak açmayın.** Bunun yerine deponun **Security** sekmesindeki **Report a vulnerability** düğmesini kullanın; bildiriminiz yalnızca bakımcılara görünür. Bu düğme görünmüyorsa, ayrıntı vermeden “güvenlik bildirimi için iletişim” başlıklı bir issue açın, size gizli bir kanal önerelim.

Bildirimde şunlar yardımcı olur: etkilenen sürüm veya commit, platform (macOS/Windows), adım adım yeniden üretme, olası etki.

İlk yanıtı 7 gün içinde vermeyi hedefliyoruz. Düzeltme yayınlanana kadar ayrıntıları paylaşmamanızı rica ederiz.

## Desteklenen sürümler

Proje erken aşamada. Yalnızca `main` dalındaki en güncel kod desteklenir.

## Tehdit modeli: neler önemli?

ConsoleTR ekran kaydı iznine sahip bir uygulamadır; bu nedenle aşağıdakiler güvenlik açığı sayılır:

- Yakalanan görüntünün veya okunan metnin kullanıcının seçmediği bir yere gönderilmesi ya da diske yazılması.
- Ollama bağlantısının `localhost` dışına yönlendirilebilmesi.
- Çeviri yanıtının (ör. bir dil modelinin çıktısının) metin olarak gösterilmek dışında bir şekilde yorumlanması veya çalıştırılması.
- Uygulamanın seçilen pencere dışındaki pencereleri yakalaması.
- CI iş akışlarının gizli bilgileri veya yazma yetkisini dışarı sızdırması.

Bunlar beklenen davranıştır, açık değildir: LibreTranslate seçildiğinde metnin kullanıcının girdiği sunucuya gitmesi; imzasız derlemelerin Gatekeeper/SmartScreen uyarısı vermesi.
