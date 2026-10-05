import Foundation

/// User-facing copy for sticky bars, the over-limit restore prompt, and uncertain bands.
/// Design frames replace wording in this file only.
public enum StitchCopy {
    public static let overlayDeduped = "已去掉重复固定栏"
    public static let restoreSticky = "还原固定栏"
    public static let overlayRestored = "已还原固定栏"
    public static let undoSticky = "撤销"
    /// Space, middle dot, space. Used between chip halves and between remainder details.
    public static let joiner = " · "
    public static let overlayDedupedChip = overlayDeduped + joiner + restoreSticky
    public static let overlayRestoredChip = overlayRestored + joiner + undoSticky

    public static let keepOnceToggle = "固定栏只保留一次"
    /// ML6d tag on the long image after the bars go back on every seam.
    public static let stickyReattached = "固定栏已接回"
    /// ML6d toast after 「还原固定栏」.
    public static let stickyRestoredToast = "已还原固定栏：固定栏接回每条接缝"
    /// ML6c band label: 「− 底栏 44 · 顶栏 52」.
    public static func dedupedBand(footer: Int, header: Int) -> String {
        "− 底栏 \(footer) · 顶栏 \(header)"
    }

    /// ML6b options for a 「待确认」 seam, in design order.
    public static let confirmCurrentShift = "确认当前位移"
    public static let manualAlignOption = "手动对齐"
    public static let joinAsIsOption = "直接拼"
    public static let splitExportOption = "分开导出"
    public static let confirmationOptions = [confirmCurrentShift, manualAlignOption, joinAsIsOption, splitExportOption]
    public static let keepOnceChoice = "当固定栏，只留一次"
    public static let keepAllChoice = "当内容，全部保留"
    public static let keepDedupe = "保持去重"
    public static let exportSegments = "分段导出"
    public static let restoreHelp = "把去掉的页眉和页脚按接缝插回去"
    /// Shown on the existing seam card when a frame is too blank to align.
    public static let blankSeam = "这一段几乎是空白，看不出该接在哪"
    /// Shown on that same card when a join would reverse the last shift.
    public static let reverseSeam = "这里像是往回滚了，确认一下接在哪"
    public static let overLimitNote = "不会悄悄截断。可以分段导出（每段都不超上限），或保持去重。"

    /// en_US grouping (comma, groups of three). Does not read `Locale.current`.
    public static func grouped(_ value: Int) -> String {
        FixedThousandsFormat.string(value)
    }

    /// 「还原后约 18,240 px，超过单张上限 16,384 px」
    /// Height-only wording. Callers that know the pixel count use the overload below.
    public static func overLimit(height: Int) -> String {
        "还原后约 \(grouped(height)) px，超过单张上限 \(grouped(ScrollOutputLimit.maxHeight)) px"
    }

    /// Names whichever single-image limit the restored stack actually crosses.
    /// `{P}` is `pixels / 10_000` rounded up (2,400.3 → 2,401). The named caps are the product limits.
    public static func overLimit(
        height: Int,
        pixels: Int64,
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> String {
        let heightExceeded = height > maxHeight
        let pixelsExceeded = pixels > Int64(maxPixels)
        let heightText = grouped(height)
        let pixelText = grouped(wanRoundedUp(pixels))
        let heightCap = grouped(ScrollOutputLimit.maxHeight)
        let pixelCap = grouped(ScrollOutputLimit.maxPixels / 10_000)
        if heightExceeded && pixelsExceeded {
            return "还原后约 \(heightText) px、\(pixelText) 万像素，超过单张上限 \(heightCap) px 和总量上限 \(pixelCap) 万像素"
        }
        if pixelsExceeded && !heightExceeded {
            return "还原后约 \(pixelText) 万像素，超过单张总量上限 \(pixelCap) 万像素"
        }
        return "还原后约 \(heightText) px，超过单张上限 \(heightCap) px"
    }

    /// `pixels / 10_000`, rounded up. Exact multiples stay put (24,000,000 → 2,400).
    public static func wanRoundedUp(_ pixels: Int64) -> Int {
        if pixels <= 0 { return 0 }
        let wan = (pixels + 9_999) / 10_000
        if wan > Int64(Int.max) { return Int.max }
        return Int(wan)
    }

    public static func uncertainPrompt(headerRows: Int, footerRows: Int, seamCount: Int) -> String {
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

    public static func handleUnaligned(_ count: Int) -> String {
        "先处理 \(count) 处待对齐"
    }

    public static func exportBlocked(_ count: Int) -> String {
        "还有 \(count) 处待对齐，先处理再导出"
    }

    /// Counts for the preview bottom bar. Zero entries are left out of {明细}.
    public struct Remainder: Equatable {
        public var unaligned: Int = 0
        public var pendingConfirm: Int = 0
        public var stickyPending: Bool = false

        public init(unaligned: Int = 0, pendingConfirm: Int = 0, stickyPending: Bool = false) {
            self.unaligned = unaligned
            self.pendingConfirm = pendingConfirm
            self.stickyPending = stickyPending
        }

        public var count: Int {
            max(0, unaligned) + max(0, pendingConfirm) + (stickyPending ? 1 : 0)
        }

        public var detail: String {
            var parts: [String] = []
            if unaligned > 0 { parts.append("待对齐 \(unaligned)") }
            if pendingConfirm > 0 { parts.append("待确认 \(pendingConfirm)") }
            if stickyPending { parts.append("固定栏待确认 1") }
            return parts.joined(separator: StitchCopy.joiner)
        }
    }

    /// 「⚠ 还有 N 处没处理（明细）。…」 or nil when nothing is left.
    public static func bottomBar(_ remainder: Remainder) -> String? {
        guard remainder.count > 0 else { return nil }
        return "⚠ 还有 \(remainder.count) 处没处理（\(remainder.detail)）。为了不拼错，处理完才能继续——不会静默拼接。"
    }

    /// Preview primary while a seam or the sticky bar is the current step. N is that step's own count.
    public static func handleNext(_ count: Int) -> String {
        "处理下一处 · \(max(0, count))"
    }

    public static func confirmDuplicates(_ count: Int) -> String {
        "先确认 \(max(0, count)) 处重复段"
    }

    public static let nextBeautify = "下一步 · 美化 →"

    public static func duplicatePendingTitle(_ index: Int) -> String {
        "重复段 \(index) · 待确认"
    }

    public static let duplicateSeamMovedSuffix = "接缝动过，需要重选"

    public static func duplicateLocation(seam: Int, rows: Int, seamMoved: Bool = false) -> String {
        let line = "接缝 \(seam) 下方 · \(rows) 行"
        guard seamMoved else { return line }
        return line + joiner + duplicateSeamMovedSuffix
    }

    /// Lead sentence on a card whose choice was cleared because its boundary moved.
    public static func duplicateSeamMovedNote(seam: Int) -> String {
        "接缝 \(seam) 动过，这里之前的选择已清掉，需要重选。"
    }

    public static let duplicateDetail = "这段内容出现了两次"
    public static let keepDuplicateOnce = "只保留一次"
    public static let keepDuplicateBoth = "都保留"
    public static let restoreDuplicate = "还原"
    public static let undoDuplicate = "撤销"

    public static func duplicateHandled(_ choice: DuplicateSegmentChoice) -> String {
        switch choice {
        case .keepOnce: return "✓ 已处理 · 只保留一次"
        case .keepBoth: return "✓ 已处理 · 都保留"
        }
    }

    public static func duplicateRestoredToast(index: Int, remaining: Int) -> String {
        "重复段 \(index) 已还原为待确认 · 待确认还剩 \(remaining) 处"
    }

    /// Shown with 「撤销」 right after 「只保留一次」 or 「都保留」.
    public static func duplicateChoiceToast(index: Int, choice: DuplicateSegmentChoice, remaining: Int) -> String {
        let name = choice == .keepOnce ? keepDuplicateOnce : keepDuplicateBoth
        return "重复段 \(index) 已改为\(name) · 待确认还剩 \(remaining) 处"
    }

    public static func duplicatesRedetected(_ count: Int) -> String {
        "重复段已重新识别，\(count) 处待确认"
    }

    /// Second half of the re-detect toast. Nil when there is nothing to report.
    /// A moved seam replaces the kept-count sentence. Every choice kept uses its own sentence.
    public static func duplicateRedetectDetail(kept: Int, pending: Int, clearedSeam: Int?, clearedCount: Int) -> String? {
        if let clearedSeam, clearedCount > 0 {
            return "接缝 \(clearedSeam) 动过，那里的 \(clearedCount) 处选择已清掉，需要重选"
        }
        if pending == 0, kept > 0 {
            return "重复段的选择都保留了"
        }
        if pending > 0, kept > 0 {
            return "重复段已重新识别，保留了 \(kept) 处选择，\(pending) 处待确认"
        }
        if pending > 0 {
            return duplicatesRedetected(pending)
        }
        return nil
    }

    /// ML6l / ML6l-b, after manual alignment 「完成」. Nil when re-detect found nothing to say.
    /// Re-detect still drops the undo stack, so this toast has no 「撤销」.
    public static func manualAlignmentRedetected(
        seam: Int,
        overlap: Int,
        kept: Int,
        pending: Int,
        clearedSeam: Int?,
        clearedCount: Int
    ) -> String? {
        guard let detail = duplicateRedetectDetail(
            kept: kept,
            pending: pending,
            clearedSeam: clearedSeam,
            clearedCount: clearedCount
        ) else { return nil }
        return "接缝 \(seam) 已对齐（手动 +\(overlap) px）" + joiner + detail
    }

    /// After 「还原自动」. Same second half as 「完成」. Nil when re-detect found nothing to say.
    public static func restoreAutoRedetected(
        seam: Int,
        kept: Int,
        pending: Int,
        clearedSeam: Int?,
        clearedCount: Int
    ) -> String? {
        guard let detail = duplicateRedetectDetail(
            kept: kept,
            pending: pending,
            clearedSeam: clearedSeam,
            clearedCount: clearedCount
        ) else { return nil }
        return "接缝 \(seam) 已还原自动" + joiner + detail
    }

    public static func savedSegments(_ count: Int) -> String {
        "已把 \(count) 段分别放进历史"
    }

    public static func restoreFailed(_ reason: String) -> String {
        "还原固定栏失败：\(reason)"
    }
}

/// Primary / secondary actions on the over-limit restore prompt.
public struct RestoreOverLimitPrompt: Equatable {
    public var unalignedCount: Int
    public var primaryTitle: String
    /// The primary button exports only after every seam is aligned or joined as-is.
    public var primaryExports: Bool
    public var segmentExportEnabled: Bool
    /// Shown under the disabled 「分段导出」 while seams are still unaligned.
    public var segmentExportCaption: String?

    public static func make(unalignedCount: Int) -> RestoreOverLimitPrompt {
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

/// Groups digits by thousands with an ASCII comma, matching en_US. Independent of the user's locale.
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
