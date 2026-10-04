import Foundation
import PrettyShotCore

/// The one bottom bar under the stitch preview (frames 38–43, 51–61): the ⚠ gate line and the primary button.
/// Every preview state reads it from here; there is no second bar.
///
/// - The line is `StitchCopy.bottomBar` word for word. N is the sum of all items; zero items are left out;
///   with nothing left the whole line is hidden.
/// - Items keep the order 待对齐 · 待确认 · 固定栏待确认, one entry each.
/// - The primary button walks seams → sticky bar → duplicates, and each step counts only its own kind.
struct StitchBottomBar: Equatable {
    enum ItemKind: Equatable {
        /// Unresolved seams: failed, waiting for alignment, or position not unique (L5b).
        case unaligned
        /// Duplicate-segment candidates with no choice yet.
        case duplicates
        /// The one uncertain sticky band.
        case sticky
    }

    struct Item: Equatable {
        var kind: ItemKind
        var count: Int
        /// 「待对齐 x」「待确认 n」「固定栏待确认 1」
        var label: String
    }

    var items: [Item]
    /// N in 「还有 N 处没处理」.
    var count: Int
    /// Full ⚠ line, or nil when the bar is hidden.
    var line: String?
    var step: StitchGate.Step
    var primaryTitle: String
    var canAdvance: Bool

    var isGateHidden: Bool { line == nil }

    init(_ remainder: StitchCopy.Remainder) {
        var items: [Item] = []
        if remainder.unaligned > 0 {
            items.append(Item(kind: .unaligned, count: remainder.unaligned, label: "待对齐 \(remainder.unaligned)"))
        }
        if remainder.pendingConfirm > 0 {
            items.append(Item(kind: .duplicates, count: remainder.pendingConfirm, label: "待确认 \(remainder.pendingConfirm)"))
        }
        if remainder.stickyPending {
            items.append(Item(kind: .sticky, count: 1, label: "固定栏待确认 1"))
        }
        self.items = items
        count = remainder.count
        line = IOSCopy.bottomBar(remainder)

        if remainder.unaligned > 0 {
            step = .seams(remainder.unaligned)
            primaryTitle = IOSCopy.handleNext(remainder.unaligned)
        } else if remainder.stickyPending {
            step = .sticky
            primaryTitle = IOSCopy.handleNext(1)
        } else if remainder.pendingConfirm > 0 {
            step = .duplicates(remainder.pendingConfirm)
            primaryTitle = IOSCopy.confirmDuplicates(remainder.pendingConfirm)
        } else {
            step = .ready
            primaryTitle = IOSCopy.nextBeautify
        }
        canAdvance = step == .ready
    }

    static func evaluate(_ assembly: ScrollAssembly) -> StitchBottomBar {
        StitchBottomBar(assembly.reviewRemainder)
    }
}

/// Top toast on the stitch preview. Same `.toast` + text button as 「已撤销：打码 · 重做」.
struct StitchToast: Equatable {
    var title: String
    var detail: String?
    /// 「撤销」 while the action can still be undone.
    var actionTitle: String?
}

/// What one duplicate-segment card shows (frames 56–60).
struct DuplicateCardState: Equatable {
    var id: String
    /// 1-based, same order as `duplicateCandidates`. Used in 「第 n 处重复段」.
    var displayIndex: Int
    var isPending: Bool
    var question: String
    /// 「第 a、b 张接缝处 · 程序判断不了是重叠还是本来就重复」
    var detail: String
    /// 「已处理 · 只保留一次」 or 「已处理 · 都保留」 once chosen. Nil while pending.
    var handledLabel: String?
}

/// Summary row above the stitch preview: 「N 张 · M 处接缝」 plus state chips (frame 38; L7i adds 「固定栏待确认 1」).
/// Chip order follows the prototype: ✓ aligned · 待对齐 · 直接拼 · 固定栏待确认 1.
struct StitchSummary: Equatable {
    enum ChipKind: Equatable {
        case aligned
        case unaligned
        case joinedAsIs
        case sticky
    }

    struct Chip: Equatable {
        var kind: ChipKind
        var label: String
    }

    /// 「4 张 · 3 处接缝」. Nil when there is nothing to stitch.
    var title: String?
    var chips: [Chip]

    static func evaluate(_ assembly: ScrollAssembly) -> StitchSummary {
        let shots = assembly.segments.reduce(0) { $0 + $1.confidentSeamYs.count + 1 }
        guard shots > 0 else { return StitchSummary(title: nil, chips: []) }
        let seamTotal = assembly.confidentSeamCount + assembly.seams.count
        var aligned = assembly.confidentSeamCount
        var unaligned = 0
        var joined = 0
        for seam in assembly.seams {
            switch seam.kind {
            case .aligned: aligned += 1
            case .needsAlignment: unaligned += 1
            case .joinedAsIs: joined += 1
            }
        }
        var chips: [Chip] = []
        if seamTotal > 0 {
            chips.append(Chip(kind: .aligned, label: "\(aligned)"))
        }
        if unaligned > 0 {
            chips.append(Chip(kind: .unaligned, label: IOSCopy.summaryUnaligned(unaligned)))
        }
        if joined > 0 {
            chips.append(Chip(kind: .joinedAsIs, label: IOSCopy.summaryJoinedAsIs(joined)))
        }
        if assembly.pendingSticky?.isUnresolved == true {
            chips.append(Chip(kind: .sticky, label: IOSCopy.summaryStickyPending))
        }
        return StitchSummary(title: IOSCopy.stitchSummaryTitle(shots: shots, seams: seamTotal), chips: chips)
    }
}

/// The 「固定栏只保留一次」 row in the bottom bar (L4 / L7i): switch, detail, and the 「还原固定栏」 mini button.
struct StitchStickyRow: Equatable {
    var title: String
    var detail: String
    /// 「还原固定栏」 while the sticky bars are kept once. Nil once restored.
    var restoreTitle: String?

    static func evaluate(_ assembly: ScrollAssembly) -> StitchStickyRow {
        StitchStickyRow(
            title: IOSCopy.keepOnce,
            detail: IOSCopy.keepOnceDetail,
            restoreTitle: assembly.dedupeStickyBars ? IOSCopy.restoreSticky : nil
        )
    }
}
