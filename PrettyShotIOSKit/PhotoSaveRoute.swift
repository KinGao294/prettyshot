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

/// Frame 14 in the extension has no settings button. Frame 31 in the app keeps 「前往设置开启」.
enum PhotoDeniedAction: String, Equatable, Hashable {
    case useCopyInstead
    case openSettings
    case later

    static func actions(inApp: Bool) -> [PhotoDeniedAction] {
        if inApp {
            return [.useCopyInstead, .openSettings, .later]
        }
        return [.useCopyInstead, .later]
    }

    var title: String {
        switch self {
        case .useCopyInstead: return IOSCopy.useCopyInstead
        case .openSettings: return IOSCopy.openSettings
        case .later: return IOSCopy.later
        }
    }
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
