import CoreGraphics
import Foundation

/// Portrait full-screen screenshot sizes. A size that is not in this table is not cropped.
/// Heights are the status-bar point size times the screen scale. New phones stay uncropped
/// until a row is added here.
struct StatusBarModel: Equatable {
    var width: Int
    var height: Int
    var topPixels: Int
    var scale: CGFloat
    var label: String
}

struct StatusBarCrop: Equatable {
    var topPixels: Int
    var scale: CGFloat
    var modelLabel: String

    func cropRect(width: Int, height: Int) -> CGRect? {
        guard topPixels > 0, width > 0, height > topPixels else { return nil }
        return CGRect(x: 0, y: CGFloat(topPixels), width: CGFloat(width), height: CGFloat(height - topPixels))
    }
}

enum StatusBarCropTable {
    static let models: [StatusBarModel] = [
        StatusBarModel(width: 1320, height: 2868, topPixels: 162, scale: 3, label: "iPhone 16 Pro Max"),
        StatusBarModel(width: 1206, height: 2622, topPixels: 162, scale: 3, label: "iPhone 16 Pro"),
        StatusBarModel(width: 1290, height: 2796, topPixels: 162, scale: 3, label: "6.7-inch Dynamic Island"),
        StatusBarModel(width: 1179, height: 2556, topPixels: 162, scale: 3, label: "6.1-inch Dynamic Island"),
        StatusBarModel(width: 1284, height: 2778, topPixels: 141, scale: 3, label: "6.7-inch notch"),
        StatusBarModel(width: 1170, height: 2532, topPixels: 141, scale: 3, label: "6.1-inch notch"),
        StatusBarModel(width: 1242, height: 2688, topPixels: 132, scale: 3, label: "6.5-inch notch"),
        StatusBarModel(width: 1125, height: 2436, topPixels: 132, scale: 3, label: "5.8-inch notch"),
        StatusBarModel(width: 1080, height: 2340, topPixels: 150, scale: 3, label: "5.4-inch mini"),
        StatusBarModel(width: 828, height: 1792, topPixels: 88, scale: 2, label: "6.1-inch notch @2x"),
        StatusBarModel(width: 750, height: 1334, topPixels: 40, scale: 2, label: "4.7-inch"),
    ]

    static func match(width: Int, height: Int) -> StatusBarCrop? {
        guard let model = models.first(where: { $0.width == width && $0.height == height }) else { return nil }
        return StatusBarCrop(topPixels: model.topPixels, scale: model.scale, modelLabel: model.label)
    }
}
