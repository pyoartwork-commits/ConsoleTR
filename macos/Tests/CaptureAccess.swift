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
        // The largest game source (Remote Play video, OBS projector) wins over small dialogs and
        // other apps; OBS's main window, which shows the game only as a preview, comes last.
        let candidates: [(id: String, kind: SourceKind, area: CGFloat)] = [
            ("w-obs", .obsMain, 2_000_000), ("w-claude", .other, 1_200_000), ("w-dialog", .game, 864 * 432),
            ("w-projector", .game, 1920 * 1080), ("d-1", .other, 0)]
        guard Controller.preferredSource(candidates) == "w-projector",
              Controller.preferredSource([("w-obs", .obsMain, 2_000_000), ("w-claude", .other, 1_200_000), ("d-1", .other, 0)]) == "w-claude",
              Controller.preferredSource([("w-obs", .obsMain, 2_000_000)]) == "w-obs",
              Controller.preferredSource([]) == nil else { throw AppFailure("Oyun penceresi seçilmedi.") }
        print("İzin reddi, servis hatası, başarılı yeniden deneme ve oyun penceresi seçimi doğrulandı.")
    }
}
