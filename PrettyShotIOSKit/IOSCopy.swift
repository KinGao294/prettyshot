import Foundation
import PrettyShotCore

/// iOS 界面文案的唯一入口。底栏和重新识别如果还要改字，只改这里。
///
/// r5（PRD v0.3.20 / v0.3.21）：底栏与 `StitchCopy.bottomBar` 逐字一致。
/// 主按钮每一步只数自己那一类：「处理下一处 · N」（接缝或固定栏）、「先确认 N 处重复段」。
/// 帧 56–61 的重复段界面后接；文案先定在 `redetectToast` / `duplicateSeamDetail`。
enum IOSCopy {
    // MARK: - 首页 · 帧 15 A1

    static let homeTitle = "截完再美化"
    static let pickFromLibrary = "从相册选图"
    static let stitchCardTitle = "拼长图"
    static let stitchCardDetail = "多张截图拼成一张"
    static let pdfCardTitle = "导入整页 PDF"
    static let pdfCardDetail = "Safari「整页」截图"
    static let homeShareHint = "更快：截图后直接分享"
    static let homeShareHintDetail = "截图后点分享 → PrettyShot"
    static let homeFooter = "全部在本机处理 · 不上传 · 免费开源"

    // MARK: - 编辑 · 帧 04–09 / 17

    static let brand = "PrettyShot"
    static let cancel = "取消"
    static let copy = "复制"
    static let saveToPhotos = "存入相册"
    static let toolBackground = "背景"
    static let toolStyle = "样式"
    static let toolCrop = "裁切"
    static let toolArrow = "箭头"
    static let toolRedact = "打码"
    static let styleRadius = "圆角"
    static let stylePadding = "边距"
    static let styleShadow = "阴影"
    static let removeStatusBar = "去状态栏"
    static let undo = "撤销"
    static let redo = "重做"
    static let delete = "删除"
    static let defaultBadge = "默认"

    static let chipStatusRemoved = "已去状态栏"
    static let chipStatusKept = "保留状态栏"
    static let chipNotScreenshot = "未自动裁切"
    static let chipManualCrop = "手动裁"
    static let chipUndoCrop = "撤回"
    static let chipRemoveAgain = "去除"
    static let chipDownsampled = "预览已降采样"
    static let arrowHint = "在空白处拖一条直线。短于 18pt 的拖动会忽略。"
    static let redactHint = "框选要打码的区域。导出时写入像素，不能还原。"
    static let redactRule = "编辑过程中可以撤销。存入相册或复制之后不能还原。"
    static let cropUnavailable = "尺寸对不上已知机型，没有自动裁。可以用手动裁切调整四边。"
    static let cropApplied = "已按机型裁掉顶部状态栏，没有裁到下面的内容。"

    static func backgroundName(_ preset: BackgroundPreset) -> String {
        "\(preset.localizedName) \(preset.name)"
    }

    // MARK: - 导出 · 帧 10 / 14 / 32 / 33

    static let toastSaved = "已存入相册"
    static let toastSavedDetail = "原图未改动"
    static let toastCopied = "已复制"
    static let toastCopiedDetail = "可直接粘贴到聊天、备忘录等"
    static let toastPreviewResolution = "已按预览尺寸保存"
    static let toastPreviewResolutionDetail = "原图未改动。这张图太大，扩展里没有按原分辨率导出。"
    static let photoUsage = "用于把美化后的图片存为一张新照片。PrettyShot 不会读取、修改或删除你已有的照片。"
    static let deniedTitle = "没法存入相册"
    static let deniedBody = "PrettyShot 还没有「添加照片」权限，这张图暂未保存。可以先复制，再粘贴到聊天、备忘录等 App。"
    static let deniedPath = "设置 › PrettyShot › 照片 › 仅添加照片"
    static let useCopyInstead = "改为复制"
    static let openSettings = "前往设置开启"
    static let later = "稍后再说"
    static let readFailedTitle = "没能读取这张图片"
    static let readFailedBody = "收到的可能不是图片，或文件已损坏。原图没有被改动。"
    static let retry = "重试"
    static let memoryFailedTitle = "打不开这张图"
    static let memoryFailedBody = "内存不够，或文件已损坏。原图没有被改动。"

    static let largeTitle = "图片较大，去 App 里处理"
    static let largeBody = "如果没有自动打开 App：图片已暂存，手动打开 PrettyShot 即可从这里继续。"
    static let largeInlineBody = "免费签名不能把原图交给 App。请打开 PrettyShot，从相册选同一张继续。扩展里可以先按预览尺寸保存。"
    static let openApp = "打开 PrettyShot"
    static let savePreviewAnyway = "按预览尺寸保存"
    static let handoffInterruptedTitle = "还没交到 App"
    static let handoffInterruptedBody = "图片还在这里，没有丢掉。可以再试一次，或先按预览尺寸保存。"
    static let handoffInlineInterruptedBody = "当前签名不能把原图交给 App。原图还在，可以按预览尺寸保存，或打开 PrettyShot 从相册再选。"
    static let handoffRetry = "再试一次"

    // MARK: - 分享多张 · 帧 12 S11

    static func multiTitle(count: Int) -> String {
        "收到 \(count) 张截图"
    }
    static let multiQuestion = "拼成一张长图？"
    static let multiStitch = "在 PrettyShot 中拼成长图"
    static let multiDetail = "拼接在 App 内完成，可以调整顺序、删掉某一张。扩展里不拼接。"
    static let multiFootnote = "若没有自动打开，手动打开 PrettyShot 即可继续。"
    static let multiInlineFootnote = "当前签名不能把这些图交给 App。请打开 PrettyShot，用「拼长图」从相册再选一次。"
    static func pdfShareTitle(count: Int) -> String {
        "收到 \(count) 个整页 PDF"
    }
    static let pdfShareQuestion = "转成一张长图？"

    // MARK: - 拼长图 · 帧 35–48 / 51–55

    static let stitchNeedTwo = "至少选 2 张"
    static let stitchOrderHint = "按住一张拖到另一张上 = 交换位置"
    static let stitchResort = "按时间重排"
    static let stitchStart = "开始拼接"
    static let stitchRemoved = "已移除 1 张 · 原图未删除"
    static let stitchSizeMismatch = "有的图尺寸不一致，拼接时被跳过。请用同一台手机的竖屏截图。"
    static let stitchPreviewNote = "骨架按加载后的宽度拼接。原宽导出等真机内存实测（M4）。"
    static let keepOnce = "固定栏只保留一次"
    static let keepOnceDetail = "顶栏只留第 1 张 · 底栏只留最后 1 张"
    static let exclusionBands = "排除带"
    static let exclusionStub = "上下排除带的拖动手柄还是占位，开关和还原已经接上共用模块。"
    static let nextBeautify = "下一步 · 美化"
    static let alignTitle = "手动对齐"
    static let alignDragHint = "上下拖动调整重叠。接近重合时可以停在建议值。"
    static let alignDone = "完成"
    static let joinAsIs = "直接拼"
    static let exportSeparate = "分开导出"
    static let failBody = "没找到可靠的重叠部分。可以手动对齐、直接上下拼接，或分开导出。"
    static let untrustedTitle = "接缝不太确定"
    static let untrustedBody = "重叠的位置没法唯一确定，不会静默拼上。"
    static let confirmCurrent = "确认当前位置"
    static let laterSeam = "稍后再说"

    /// 接缝和固定栏共用。N 只数这一步自己的类：接缝 = 待对齐数，固定栏固定为 1。
    static func handleNext(_ count: Int) -> String {
        "处理下一处 · \(count)"
    }

    static let stickyKeepOnce = "当固定栏，只留一次"
    static let stickyKeepAll = "当内容，全部保留"

    static func confirmDuplicates(_ count: Int) -> String {
        "先确认 \(count) 处重复段"
    }

    /// 1-based sheet pair. Seam 0 is between shot 1 and shot 2.
    static func shotPair(seamIndex: Int) -> (Int, Int) {
        (seamIndex + 1, seamIndex + 2)
    }

    static func shotPairTitle(_ first: Int, _ second: Int) -> String {
        "第 \(first)、\(second) 张"
    }

    static func seamMissTitle(seamIndex: Int) -> String {
        let pair = shotPair(seamIndex: seamIndex)
        return "\(shotPairTitle(pair.0, pair.1))没对上"
    }

    static func duplicateSeamDetail(first: Int, second: Int) -> String {
        "\(shotPairTitle(first, second))接缝处 · 程序判断不了是重叠还是本来就重复"
    }

    /// 帧 61。识别接线等 #9 / #10；文案先定死。不带撤销。
    static func redetectToast(first: Int, second: Int, pending: Int) -> String {
        "\(shotPairTitle(first, second))已对齐 · 重复段已重新识别，\(pending) 处待确认"
    }

    static let duplicateQuestion = "这一行出现了两次"
    static let duplicateDetail = "程序判断不了是重叠还是本来就重复"
    static let duplicateKeepOnce = "只保留一次"
    static let duplicateKeepBoth = "都保留"
    static let duplicateRestore = "还原"
    static let duplicateMark = "重复？"

    /// 帧 56–60 的卡片结构在，识别本身等 #9 / #10 合入后再接。
    static let duplicateWiringNote = "重复段候选由共用模块给出。识别规则在另外两个 PR 里，这里不新写一套。"

    /// 设计师还会改「重新识别」的文案。对齐页上的按钮目前用「还原自动」。
    static let reDetect = "还原自动"

    static let tooLongTitle = "长图太长，建议分段导出"
    static let tooLongBody = "超过可稳定导出的长度上限（iOS 具体数值等真机实测）。段与段之间不缺内容。"
    static let tooLongCopy = "超大图无法复制到剪贴板，请用「存入相册」。"
    static func saveSegments(_ count: Int) -> String {
        "分 \(count) 段存入相册"
    }
    static func toastSegments(_ count: Int) -> String {
        "已存入相册 \(count) 张"
    }
    static let keepDedupe = "保持去重"

    static let pdfTitle = "导入整页截图（PDF）"
    static let pdfBody = "只有 Safari 等少数 App 提供「整页」截图。其他 App 的长内容，请截多张后用「拼长图」。"
    static let pdfPick = "从「文件」选取 PDF"
    static let pdfUseStitch = "改用 拼长图"
    static let pdfStub = "PDF 转成图片还没接上。选中文件后会停在这一步，不会假装已经拼好。"
    static let pdfPickedStub = "已选中 PDF。光栅化留到下一轮，这一步不会生成长图。"

    static let handoffBannerTitle = "继续上次分享"
    static func handoffBannerDetail(count: Int) -> String {
        "有 \(count) 张图从分享扩展暂存过来，可以接着拼。"
    }

    static let longEditorChip = "长图"
    static let doneStickyChip = "已去掉重复固定栏 · 还原固定栏"

    /// 底栏。设计师若改 iOS 措辞，只改这个函数。
    static func bottomBar(_ remainder: StitchCopy.Remainder) -> String? {
        StitchCopy.bottomBar(remainder)
    }
}
