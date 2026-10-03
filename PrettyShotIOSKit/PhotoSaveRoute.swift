import Foundation

enum PhotoAddAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
}

enum PhotoSaveRoute: Equatable {
    case requestThenSave
    case save
    case offerCopy
}

enum PhotoSaveRouter {
    static func route(for status: PhotoAddAuthorization) -> PhotoSaveRoute {
        switch status {
        case .notDetermined: return .requestThenSave
        case .authorized: return .save
        case .denied: return .offerCopy
        }
    }
}
