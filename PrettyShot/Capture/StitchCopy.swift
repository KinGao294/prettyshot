import Foundation

/// User-facing copy for sticky bars, the over-limit restore prompt, and uncertain bands.
/// Swap design-frame wording in this file only.
enum StitchCopy {
    static let overlayDeduped = "已去掉重复固定栏"
    static let restoreSticky = "还原固定栏"
    static let keepOnceToggle = "固定栏只保留一次"
    static let keepOnceChoice = "当固定栏，只保留一次"
    static let keepAllChoice = "当内容，全部保留"
    static let keepDedupe = "保持去重"
    static let exportSegments = "分段导出"
    static let restoreHelp = "把去掉的页眉和页脚按接缝插回去"

    /// ASCII thousands separators. Does not read `Locale`.
    static func grouped(_ value: Int) -> String {
        FixedThousandsFormat.string(value)
    }

    static func overLimit(height: Int, limit: Int) -> String {
        "还原后约 \(grouped(height)) px，超过单张上限 \(grouped(limit)) px"
    }

    static func uncertainPrompt(headerRows: Int, footerRows: Int, seamCount: Int) -> String {
        let place: String
        if headerRows > 0 && footerRows > 0 {
            place = "顶部和底部可能是固定栏"
        } else if footerRows > 0 {
            place = "底部这条可能是固定栏"
        } else {
            place = "顶部这条可能是固定栏"
        }
        return "待确认 · \(place)（涉及 \(seamCount) 处接缝）"
    }

    static func handleUnaligned(_ count: Int) -> String {
        "先处理 \(count) 处待对齐"
    }

    static func exportBlocked(_ count: Int) -> String {
        "还有 \(count) 处待对齐，先处理再导出"
    }

    static func remainingItems(_ count: Int) -> String {
        "还有 \(count) 处没处理"
    }

    static func savedSegments(_ count: Int) -> String {
        "已把 \(count) 段分别放进历史"
    }

    static func restoreFailed(_ reason: String) -> String {
        "还原固定栏失败：\(reason)"
    }
}

/// Primary / secondary actions on the over-limit restore prompt.
struct RestoreOverLimitPrompt: Equatable {
    var unalignedCount: Int
    var primaryTitle: String
    /// The primary button exports only after every seam is aligned or joined as-is.
    var primaryExports: Bool
    var segmentExportEnabled: Bool
    /// Shown under the disabled 「分段导出」 while seams are still unaligned.
    var segmentExportCaption: String?

    static func make(unalignedCount: Int) -> RestoreOverLimitPrompt {
        let count = max(0, unalignedCount)
        if count > 0 {
            return RestoreOverLimitPrompt(
                unalignedCount: count,
                primaryTitle: StitchCopy.handleUnaligned(count),
                primaryExports: false,
                segmentExportEnabled: false,
                segmentExportCaption: StitchCopy.exportBlocked(count)
            )
        }
        return RestoreOverLimitPrompt(
            unalignedCount: 0,
            primaryTitle: StitchCopy.exportSegments,
            primaryExports: true,
            segmentExportEnabled: true,
            segmentExportCaption: nil
        )
    }
}

/// Groups digits by thousands with an ASCII comma. Independent of the user's locale.
enum FixedThousandsFormat {
    static func string(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let digits = Array(String(value.magnitude))
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3)
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                out.append(",")
            }
            out.append(digit)
        }
        return sign + out
    }
}
