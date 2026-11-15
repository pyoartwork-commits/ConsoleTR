import AppKit
import ScreenCaptureKit

@main struct CaptureAccessTest {
    @MainActor static func main() async throws {
        let model = Controller()
        model.live = true
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        await model.refresh { throw denied }
        guard model.needsPermission, !model.loading else { throw AppFailure("İzin reddi ayırt edilemedi.") }
        await model.refresh { throw NSError(domain: "TestService", code: denied.code) }
        guard !model.needsPermission, model.status.contains("TestService") else { throw AppFailure("Servis hatası izin reddi olarak gösterildi.") }
        await model.refresh { throw denied }
        await model.refresh { [] }
        guard !model.needsPermission, model.targets.isEmpty, !model.loading else { throw AppFailure("Başarılı sorgudan sonra izin uyarısı temizlenmedi.") }
        print("İzin reddi, servis hatası ve başarılı yeniden deneme doğrulandı.")
    }
}
