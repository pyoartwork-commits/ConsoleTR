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
        // A full-screen Remote Play session has a large video window and small dialogs; the
        // video window must win over other apps and over those dialogs.
        let candidates: [(id: String, isRemotePlay: Bool, area: CGFloat)] = [
            ("w-claude", false, 1_200_000), ("w-dialog", true, 864 * 432), ("w-video", true, 1920 * 1080), ("d-1", false, 0)]
        guard Controller.preferredSource(candidates) == "w-video",
              Controller.preferredSource([("w-claude", false, 1_200_000), ("d-1", false, 0)]) == "w-claude",
              Controller.preferredSource([]) == nil else { throw AppFailure("Remote Play oyun penceresi seçilmedi.") }
        print("İzin reddi, servis hatası, başarılı yeniden deneme ve Remote Play pencere seçimi doğrulandı.")
    }
}
