import Photos
import UIKit

enum PhotoLibrarySaver {
    static func addOnlyStatus() -> PhotoAddAuthorization {
        map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    static func savePNG(_ data: Data, completion: @escaping (PhotoAddAuthorization) -> Void) {
        let finish: (PHAuthorizationStatus) -> Void = { status in
            let mapped = map(status)
            guard PhotoSaveRouter.route(for: mapped) == .save else {
                DispatchQueue.main.async { completion(mapped) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { saved, _ in
                DispatchQueue.main.async {
                    completion(saved ? .authorized : .denied)
                }
            }
        }
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: finish)
        } else {
            finish(current)
        }
    }

    static func copyToPasteboard(_ image: CGImage) {
        UIPasteboard.general.image = UIImage(cgImage: image)
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAddAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .limited: return .authorized
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}
