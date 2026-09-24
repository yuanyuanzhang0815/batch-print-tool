import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

// ── 常量 ────────────────────────────────────────────────
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4", letter = "Letter", a5 = "A5"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.276, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        case .a5: return CGSize(width: 419.528, height: 595.276)
        }
    }
}

enum MarginMode: String, CaseIterable, Identifiable {
    case none = "无", center = "居中"
    var id: String { rawValue }
}

// ── 工具 ────────────────────────────────────────────────
func runCmd(_ path: String, _ args: [String], env extra: [String: String]? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let extra {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in extra { e[k] = v }
        p.environment = e
    }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "ERR \(error)" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func listPrinters() -> (names: [String], def: String?) {
    var res: [String] = []
    for line in runCmd("/usr/bin/lpstat", ["-p"]).split(separator: "\n") {
        var rest: Substring
        if line.hasPrefix("printer ") { rest = line.dropFirst(8) }
        else if line.hasPrefix("打印机") { rest = line.dropFirst(3) }
        else { continue }
        let ascii = String(rest.prefix { $0.isASCII })
        if let n = ascii.split(separator: " ").first, !n.isEmpty { res.append(String(n)) }
    }
    let dOut = runCmd("/usr/bin/lpstat", ["-d"])
    var def: String?
    for n in res where dOut.contains(n) { def = n; break }
    if def == nil, res.count == 1 { def = res[0] }
    return (res, def)
}

// ── 缩放：每页按百分比缩放，按纸张 / 页边距定位 ──────────
func scaleFor(_ mode: ScaleMode, _ c: CGRect, _ percent: Double, _ pg: CGSize) -> CGFloat {
    let fit = min(pg.width / c.width, pg.height / c.height)
    switch mode {
    case .custom: return CGFloat(percent / 100.0) * fit
    case .fit: return fit < 1 ? fit : 1
    case .actual: return 1
    }
}

func pdfOrigin(_ c: CGRect, _ s: CGFloat, _ pg: CGSize, _ m: MarginMode) -> (CGFloat, CGFloat) {
    let dx = m == .center ? (pg.width - c.width * s) / 2 : 0
    let dy = m == .center ? (pg.height - c.height * s) / 2 : 0
    return (dx - c.minX * s, dy - c.minY * s)
}

// ── 旋转：每个文件独立的 90° 步进，四条流水线（导出 / 打印 / 预览）共用同一套放置数学 ──
func normRotation(_ r: Int) -> Int { ((r % 360) + 360) % 360 }

/// 旋转后的内容外接盒（90/270 时长宽互换）。缩放与定位都按这个盒子算，
/// 内容真正绘制时再绕盒子中心旋转，这样缩放 / 纸张 / 页边距三套规则不用为旋转分叉。
func rotatedBox(_ c: CGRect, _ rotation: Int) -> CGRect {
    let r = normRotation(rotation)
    let size = (r == 90 || r == 270) ? CGSize(width: c.height, height: c.width) : c.size
    return CGRect(origin: .zero, size: size)
}

func placeContent(_ ctx: CGContext, _ c: CGRect, _ eff: CGRect, _ s: CGFloat,
                  _ dx: CGFloat, _ dy: CGFloat, _ rotation: Int) {
    let r = normRotation(rotation)
    ctx.translateBy(x: dx + eff.width * s / 2, y: dy + eff.height * s / 2)
    if r != 0 { ctx.rotate(by: CGFloat(r) * .pi / 180) }
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -c.midX, y: -c.midY)
}

func scaledPDF(input: URL, outDir: URL, mode: ScaleMode, percent: Double, pages: [Int],
                suffix: String = "", paper: PaperSize, margin: MarginMode,
                rotation: Int = 0) -> URL? {
    guard isSupportedFile(input) else { return nil }
    var src = input
    if isOfficeFile(input) {
        guard let converted = resolvedPDF(input) else { return nil }
        src = converted
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let name = input.deletingPathExtension().lastPathComponent + suffix + "-x\(Int(percent)).pdf"
    let outURL = outDir.appendingPathComponent(name)
    let pg = paper.size
    var box = CGRect(x: 0, y: 0, width: pg.width, height: pg.height)
    guard let ctx = CGContext(outURL as CFURL, mediaBox: &box, nil) else { return nil }

    // 图片：单页，按同一套缩放 / 页边距规则画进 PDF
    if isImageFile(src) {
        guard let img = loadCGImage(src) else { return nil }
        let c = CGRect(origin: .zero, size: imagePoints(src, img))
        let eff = rotatedBox(c, rotation)
        let s = scaleFor(mode, eff, percent, pg)
        let (dx, dy) = pdfOrigin(eff, s, pg, margin)
        ctx.interpolationQuality = .high
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        placeContent(ctx, c, eff, s, dx, dy, rotation)
        ctx.draw(img, in: c)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        return outURL
    }

    guard let doc = CGPDFDocument(src as CFURL) else { return nil }
    let total = doc.numberOfPages
    let want = pages.filter { $0 >= 1 && $0 <= total }
    guard !want.isEmpty else { return nil }
    for i in want {
        guard let page = doc.page(at: i) else { continue }
        let c = page.getBoxRect(.cropBox)
        let eff = rotatedBox(c, rotation)
        let s = scaleFor(mode, eff, percent, pg)
        let (dx, dy) = pdfOrigin(eff, s, pg, margin)
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        placeContent(ctx, c, eff, s, dx, dy, rotation)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return outURL
}

// ── 支持的输入类型：PDF + 常见图片，统一抽象成「页面」 ──────
let IMAGE_EXTS: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp"]

func isImageFile(_ u: URL) -> Bool { IMAGE_EXTS.contains(u.pathExtension.lowercased()) }
func isSupportedFile(_ u: URL) -> Bool {
    u.pathExtension.lowercased() == "pdf" || isImageFile(u) || isOfficeFile(u)
}

func loadCGImage(_ u: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// 图片按 DPI 元数据换算成「点」尺寸（无 DPI 时按 72dpi → 1px = 1pt）
func imagePoints(_ u: URL, _ img: CGImage) -> CGSize {
    var dpi: CGFloat = 72
    if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let d = props[kCGImagePropertyDPIWidth] as? CGFloat, d > 1 { dpi = d }
    let k = 72.0 / dpi
    return CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
}

func pageCount(_ url: URL) -> Int {
    if isImageFile(url) { return 1 }
    if isOfficeFile(url) { return resolvedPDF(url).map { CGPDFDocument($0 as CFURL)?.numberOfPages ?? 0 } ?? 0 }
    return CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
}

// ── Office / 文本类：经 LibreOffice 转 PDF 后进入同一条流水线 ──
let OFFICE_EXTS: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "csv", "pages", "numbers", "key"]
let SOFFICE_CANDIDATES = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                          "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]

func isOfficeFile(_ u: URL) -> Bool { OFFICE_EXTS.contains(u.pathExtension.lowercased()) }
func sofficePath() -> String? { SOFFICE_CANDIDATES.first { FileManager.default.isExecutableFile(atPath: $0) } }

func officeCacheDir() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("local.printtools.batchprint/office", isDirectory: true)
}

// LibreOffice headless 在本机的字体发现是坏的（缺 CJK → 中文转出来是空白/方块）。
// 实测：注入一份指向系统字体目录的 fontconfig 配置后中文恢复正常。
func ensureFontConfig() -> String? {
    let dir = officeCacheDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cache = dir.appendingPathComponent("fontcache", isDirectory: true)
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let conf = dir.appendingPathComponent("fonts.conf")
    let xml = """
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <dir>/System/Library/Fonts</dir>
      <dir>/System/Library/Fonts/Supplemental</dir>
      <dir>/Library/Fonts</dir>
      <dir>\(NSHomeDirectory())/Library/Fonts</dir>
      <cachedir>\(cache.path)</cachedir>
    </fontconfig>
    """
    guard (try? xml.write(to: conf, atomically: true, encoding: .utf8)) != nil else { return nil }
    return conf.path
}

// 按「转换器版本 + 路径 + mtime」缓存；同步转换（soffice 本体启动约 1-3s）
func officeToPDF(_ u: URL) -> URL? {
    guard let bin = sofficePath() else { return nil }
    let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
    let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    let key = String(UInt(bitPattern: "v2-fontconfig|\(u.path)|\(mtime)".hashValue), radix: 16)
    let dir = officeCacheDir().appendingPathComponent(key, isDirectory: true)
    let named = dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".pdf")
    if FileManager.default.fileExists(atPath: named.path) { return named }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var extraEnv: [String: String] = [:]
    if let fc = ensureFontConfig() { extraEnv["FONTCONFIG_FILE"] = fc }
    _ = runCmd(bin, ["--headless", "--norestore", "--invisible",
                     "--convert-to", "pdf", "--outdir", dir.path, u.path], env: extraEnv)
    if FileManager.default.fileExists(atPath: named.path) { return named }
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.first { $0.pathExtension.lowercased() == "pdf" }
}

// 任何“需要先转换”的类型 → 可处理的 PDF 路径
func resolvedPDF(_ u: URL) -> URL? {
    if isOfficeFile(u) { return officeToPDF(u) }
    if u.pathExtension.lowercased() == "pdf" { return u }
    return nil
}

// ── 预览渲染 ────────────────────────────────────────────
func renderPage(url: URL, mode: ScaleMode, percent: Double, sourcePage: Int,
                paper: PaperSize, margin: MarginMode, rotation: Int = 0,
                retina: CGFloat = 3) -> NSImage? {
    let pg = paper.size
    var src = url
    if isOfficeFile(url) {
        guard let converted = resolvedPDF(url) else { return nil }
        src = converted
    }
    let isImg = isImageFile(src)
    let img = isImg ? loadCGImage(src) : nil
    var pageRef: CGPDFPage? = nil
    if !isImg {
        guard let doc = CGPDFDocument(src as CFURL), let p = doc.page(at: sourcePage) else { return nil }
        pageRef = p
    }
    let c: CGRect = isImg
        ? CGRect(origin: .zero, size: imagePoints(src, img!))
        : pageRef!.getBoxRect(.cropBox)
    let eff = rotatedBox(c, rotation)
    let s = scaleFor(mode, eff, percent, pg)
    let (dx, dy) = pdfOrigin(eff, s, pg, margin)
    let w = Int(pg.width * retina), h = Int(pg.height * retina)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    ctx.scaleBy(x: retina, y: retina)
    placeContent(ctx, c, eff, s, dx, dy, rotation)
    if isImg, let img { ctx.draw(img, in: c) } else if let pageRef { ctx.drawPDFPage(pageRef) }
    guard let cg = ctx.makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: pg.width, height: pg.height))
}

// ── 模型 ────────────────────────────────────────────────
enum ItemStatus: String {
    case ready = "就绪", sent = "已发送", failed = "失败"
}

struct PrintItem: Identifiable {
    let id = UUID()
    let url: URL
    var pages: Int
    var range = "全部"
    var copies = 1
    var rotation = 0          // 0 / 90 / 180 / 270，顺时针为正，逐文件独立
    var status: ItemStatus = .ready
    var name: String { url.lastPathComponent }
    var isImage: Bool { isImageFile(url) }
    var isOffice: Bool { isOfficeFile(url) }
}

enum ScaleMode: String, CaseIterable, Identifiable {
    case fit = "适合页面"
    case actual = "实际大小"
    case custom = "自定义比例"
    var id: String { rawValue }
}

func isValidRange(_ s: String, total: Int) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.isEmpty || t == "全部" || t.lowercased() == "all" { return true }
    for part in t.split(separator: ",") {
        let p = part.trimmingCharacters(in: .whitespaces)
        if let dash = p.firstIndex(of: "-"),
           let a = Int(p[p.startIndex..<dash]), let b = Int(p[p.index(after: dash)...]) {
            if a < 1 || b > total || a > b { return false }
        } else if let n = Int(p), n >= 1, n <= total {
            continue
        } else {
            return false
        }
    }
    return true
}

func parseRange(_ s: String, total: Int) -> [Int] {
    let t = s.trimmingCharacters(in: .whitespaces)
    let all = Array(1...max(1, total))
    if t.isEmpty || t == "全部" || t.lowercased() == "all" { return all }
    var out: [Int] = []
    for part in t.split(separator: ",") {
        let p = part.trimmingCharacters(in: .whitespaces)
        if let dash = p.firstIndex(of: "-"),
           let a = Int(p[p.startIndex..<dash]),
           let b = Int(p[p.index(after: dash)...]) {
            if a <= b { for i in a...b where i >= 1 && i <= total { out.append(i) } }
        } else if let n = Int(p), n >= 1, n <= total {
            out.append(n)
        }
    }
    return out.isEmpty ? all : out
}

// ── 状态 ────────────────────────────────────────────────
final class Model: ObservableObject {
    @Published var items: [PrintItem] = []
    @Published var mode: ScaleMode = .custom
    @Published var percent: Double = 80
    @Published var paper: PaperSize = .a4
    @Published var margin: MarginMode = .center
    @Published var duplex = false
    @Published var printers: [String] = []
    @Published var printer = ""
    @Published var current = 0
    @Published var message = ""
    @Published var busy = false
    private var flashToken = 0

    init() {
        let r = listPrinters()
        printers = r.names
        printer = r.def ?? r.names.first ?? ""
        // 快照 / 演示用：覆盖本机真实打印机名，
        // 否则截图里会带出「型号 + 序列号」这种个人设备信息。
        if let fake = ProcessInfo.processInfo.environment["BATCHPRINT_PRINTER"] {
            printers = [fake]
            printer = fake
        }
    }

    var totalSheets: Int {
        items.reduce(0) { $0 + parseRange($1.range, total: $1.pages).count * max(1, $1.copies) }
    }

    func flash(_ s: String, seconds: Double = 2.4) {
        message = s
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.message = ""
        }
    }

    func add(_ urls: [URL]) {
        let needConvert = urls.contains { isOfficeFile($0) }
        if needConvert { busy = true; message = "正在用 LibreOffice 转换文档…" }
        defer { if needConvert { busy = false } }
        var added: [PrintItem] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let inner = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                for f in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where isSupportedFile(f) && !items.contains(where: { $0.url == f }) {
                    added.append(PrintItem(url: f, pages: pageCount(f)))
                }
                continue
            }
            guard isSupportedFile(u) else { continue }
            if items.contains(where: { $0.url == u }) { continue }
            added.append(PrintItem(url: u, pages: pageCount(u)))
        }
        guard !added.isEmpty else {
            flash("没有新的文件可加（可能已在队列里）")
            return
        }
        items.append(contentsOf: added)
        current = items.count - 1
        flash("已添加 \(added.count) 个文件")
    }

    func remove(_ item: PrintItem) {
        items.removeAll { $0.id == item.id }
        current = min(current, max(0, items.count - 1))
    }

    func removeSelected() {
        guard items.indices.contains(current) else { return }
        remove(items[current])
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        current = 0
        flash("已清空文件队列")
    }

    /// 把当前队列 + 打印设置快照成一份可带到后台的渲染计划。
    func batchPlan() -> BatchPlan {
        BatchPlan(items: items.map { it in
            BatchPlan.Item(url: it.url,
                           pages: parseRange(it.range, total: it.pages),
                           copies: it.copies,
                           rotation: it.rotation)
        }, mode: mode, percent: percent, paper: paper, margin: margin)
    }

    /// 导出 / 打印共用的「渲染一批文件」路径：一律走串行渲染队列，不占主线程。
    /// `Task { @MainActor in }` 保证 await 回来后仍在主线程改 @Published 状态。
    func renderBatchAsync(_ dir: URL, done: @escaping @MainActor ([URL]) -> Void) {
        let plan = batchPlan()
        Task { @MainActor in
            let outs = await renderOffMain { scaledAll(plan, to: dir) }
            done(outs)
        }
    }

    func doExport() {
        guard !items.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "导出到这里"
        let r = p.runModal()
        resetCursorRects()
        guard r == .OK, let dir = p.urls.first else { return }
        busy = true
        renderBatchAsync(dir) { outs in
            self.busy = false
            self.flash(outs.isEmpty ? "导出失败，检查 PDF 是否损坏"
                                    : "已导出 \(outs.count) 个文件 → \(dir.lastPathComponent)")
        }
    }

    func doPrint() {
        guard !items.isEmpty else { return }
        guard !printer.isEmpty else { flash("没找到打印机"); return }
        busy = true
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bp-\(UUID().uuidString)")
        renderBatchAsync(tmp) { outs in
            guard !outs.isEmpty else {
                self.busy = false
                self.flash("生成失败，检查 PDF 是否损坏", seconds: 6)
                return
            }
            var args = ["-d", self.printer, "-o", "Collate=\(outs.count > 1 ? "True" : "False")"]
            if self.duplex { args += ["-o", "sides=two-sided-long-edge"] }
            args += outs.map { $0.path }
            let out = runCmd("/usr/bin/lp", args)
            self.busy = false
            let ok = out.lowercased().contains("request id") || out.contains("请求id")
                || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if ok {
                for i in self.items.indices { self.items[i].status = .sent }
                self.flash("已发送到 \(shortPrinter(self.printer))：\(outs.count) 个文件 / \(self.totalSheets) 页")
            } else {
                for i in self.items.indices { self.items[i].status = .failed }
                self.flash("打印失败：\(out.prefix(90))", seconds: 8)
            }
        }
    }
}

// ── 动效：按 animate 决策，frequency 低→弹簧；reduce motion 降级 ──
func motion(_ reduce: Bool) -> Animation? {
    reduce ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.82)
}

// ── 动效 token（animate skill）────────────────────────
// 内置 easeOut 太弱，UI 上要用 cubic-bezier 的强曲线；
// 弹簧只留给「跟手、可中断」的操作，不要拿它当默认。
enum Motion {
    /// cubic-bezier(0.23, 1, 0.32, 1) —— 强 ease-out：进场、状态落定
    static let out = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
}

func scaleLabel(_ m: Model) -> String {
    switch m.mode {
    case .custom: return "缩放 \(Int(m.percent))%"
    case .fit: return "适合页面"
    case .actual: return "实际大小"
    }
}

// ── 交互态：hover / press（animate：tens per day → 120ms，近无感，不弹跳）──
// hover 预览钩子：离屏截图时强制显示 hover 态（用于自查，不影响正常运行）
private struct HoverPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var hoverPreview: Bool {
        get { self[HoverPreviewKey.self] }
        set { self[HoverPreviewKey.self] = newValue }
    }
}

enum BtnKind { case glyph, quiet, mini, text, cta }

struct HoverButton<Label: View>: View {
    var kind: BtnKind = .text
    var tip: String? = nil
    var off = false
    let action: () -> Void
    let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.hoverPreview) private var hoverPreview
    @State private var hover = false
    @State private var press = false

    init(kind: BtnKind = .text, tip: String? = nil, off: Bool = false,
         action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.kind = kind; self.tip = tip; self.off = off; self.action = action; self.label = label
    }

    private var isHot: Bool { (hover || hoverPreview) && !off }

    var body: some View {
        Group {
            switch kind {
            case .cta:
                Button(action: action) { label().foregroundStyle(.white).padding(.horizontal, 12) }
                    .buttonStyle(.plain)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.accentColor))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isHot ? 0.35 : 0.16), lineWidth: 1))
                    .brightness(isHot ? 0.10 : 0)
                    .scaleEffect(press && !off && !reduce ? 0.97 : (isHot ? 1.02 : 1))
            case .text:
                Button(action: action) { label() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(isHot ? Color.primary.opacity(0.11) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(isHot ? 0.28 : 0.15), lineWidth: 1))
                    .contentShape(Rectangle())
            case .glyph:
                Button(action: action) { label() }
                    .buttonStyle(.plain)
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(isHot ? Color.primary.opacity(0.12) : .clear))
            case .quiet:
                Button(action: action) { label() }
                    .buttonStyle(.plain)
                    .foregroundStyle(isHot ? Color.primary : Color.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            case .mini:   // 行内密集区专用：比 quiet 小一号
                Button(action: action) { label() }
                    .buttonStyle(.plain)
                    .foregroundStyle(isHot ? Color.primary : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(isHot ? Color.primary.opacity(0.10) : .clear))
                    .contentShape(Rectangle())
            }
        }
        .opacity(off ? 0.4 : 1)
        .disabled(off)
        .brightness(hover && !off && kind == .cta ? 0.07 : 0)
        .scaleEffect(press && !off && !reduce ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.09), value: press)
        .onHover { h in hover = h }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !press && !off { press = true } }
                .onEnded { _ in press = false }
        )
            .helpIf(tip)
    }
}

extension View {
    @ViewBuilder func helpIf(_ t: String?) -> some View {
        if let t, !t.isEmpty { self.help(t) } else { self }
    }
}

// 行/卡片这类容器：hover 时的柔和背景（120ms，仅颜色不动位移）
struct HoverRow: ViewModifier {
    var active: Bool
    var radius: CGFloat = 6
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius)
            .fill(active ? Color.primary.opacity(0.045) : .clear))
    }
}

// 窗口本身必须是实体背景：内容区不允许透桌面。
// 材质只允许出现在 chrome（底部 action bar / 菜单 / popover）。
struct WindowBG: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Hairline: View {
    var weak = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? (weak ? 0.07 : 0.10)
                                                         : (weak ? 0.045 : 0.06)))
            .frame(width: 1)
    }
}

func paneTitle(_ t: String) -> some View {
    Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
}

// ── 队列行的宽度预算 ───────────────────────────────────
/// 文件名列 = 队列栏内容宽 − 右侧合计，**硬算**，不靠 HStack 协商。
/// 之前用 `maxWidth: .infinity` + `fixedSize(vertical:)` 让 Text 自己决定宽度，
/// 结果文本会溢出自己的列压到「范围」pill 下面。硬约束 + clipped 才治得住。
enum RowMetrics {
    static let hPad: CGFloat = 14          // 行左右内边距
    static let rangeSlot: CGFloat = 50     // 范围槽（比内容宽，留出与文件名的呼吸间距）
    static let copiesSlot: CGFloat = 62    // 份数槽
    static let utilSlot: CGFloat = 62      // 行尾效用位
    static var right: CGFloat { rangeSlot + copiesSlot + utilSlot }

    static func nameWidth(paneWidth: CGFloat) -> CGFloat {
        max(96, paneWidth - hPad * 2 - right)
    }
}

// ── 渲染队列 ───────────────────────────────────────────
// 所有 PDF/图片解码、Office → PDF 转换都必须走这一个**串行后台队列**：
//   ① 这些调用是同步阻塞的（Office 还要跑 LibreOffice，1–3 秒/文件），
//      留在主线程会让整个窗口卡住 —— 转一下旋转、换一个文件都会顿。
//   ② LibreOffice 用同一个 user profile，并发跑两个实例会互相抢锁，
//      所以串行化不只是为了性能，也是正确性问题。
let renderQueue = DispatchQueue(label: "local.printtools.render", qos: .userInitiated)

/// 把一段同步渲染搬到串行后台队列上跑；`await` 返回后仍回到调用者所在的 actor。
func renderOffMain<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { cont in
        renderQueue.async { cont.resume(returning: work()) }
    }
}

/// 批量渲染所需的全部参数（队列 + 打印设置的值快照）。
/// 快照的意义：带到后台之后，用户在渲染过程中改队列 / 改设置都不会出竞态。
struct BatchPlan {
    struct Item {
        let url: URL
        let pages: [Int]
        let copies: Int
        let rotation: Int
    }
    let items: [Item]
    let mode: ScaleMode
    let percent: Double
    let paper: PaperSize
    let margin: MarginMode
}

/// 纯函数，可以在任意线程跑（只碰传入的参数，不碰 model）。
func scaledAll(_ plan: BatchPlan, to dir: URL) -> [URL] {
    var outs: [URL] = []
    for it in plan.items {
        for copy in 0..<max(1, it.copies) {
            let suffix = it.copies > 1 ? "-c\(copy + 1)" : ""
            if let o = scaledPDF(input: it.url, outDir: dir, mode: plan.mode, percent: plan.percent,
                                 pages: it.pages, suffix: suffix, paper: plan.paper,
                                 margin: plan.margin, rotation: it.rotation) {
                outs.append(o)
            }
        }
    }
    return outs
}

// ── 主界面：文件队列 34% ｜ 打印设置 23% ｜ 预览 43% ─────
struct ContentView: View {
    var sampleDir: String? = nil
    @StateObject var model = Model()
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let paneW = max(340, geo.size.width * 0.34)
                HStack(spacing: 0) {
                    FileTable(model: model, reduce: reduce, targeted: targeted,
                              nameWidth: RowMetrics.nameWidth(paneWidth: paneW))
                        .frame(width: paneW)
                    Hairline()
                    SettingsPanel(model: model)
                        .frame(width: max(272, geo.size.width * 0.23))
                    Hairline(weak: true)
                    PreviewPane(model: model, reduce: reduce)
                        .frame(maxWidth: .infinity)
                }
            }
            BottomBar(model: model)
        }
        .frame(minWidth: 1120, minHeight: 660)
        .modifier(WindowBG())
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0),
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(8)
                .animation(.easeOut(duration: 0.18), value: targeted)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let u = obj as? URL { urls.append(u) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                withAnimation(motion(reduce)) { model.add(urls) }
            }
            return true
        }
        .task {
            guard let d = sampleDir else { return }
            let dir = URL(fileURLWithPath: d)
            let inner = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let files = inner.filter { isSupportedFile($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !files.isEmpty { model.add(files) }
            if ProcessInfo.processInfo.environment["BATCHPRINT_DEMO"] == "stress", model.items.count > 1 {
                model.items[0].range = "9-2"
                model.items[1].copies = 3
            }
            if ProcessInfo.processInfo.environment["BATCHPRINT_DEMO"] == "rotate", !model.items.isEmpty {
                model.items[0].rotation = 90
                if model.items.count > 1 { model.items[1].rotation = 270 }
                model.current = 0   // 让预览头部的「已转 90° · 复位」也能被快照盖到
            }
            // 导出路径（走渲染队列的那条）也要能被无头验证：
            // NSOpenPanel 没法自动化，所以给一个直接指定输出目录的钩子
            if let out = ProcessInfo.processInfo.environment["BATCHPRINT_EXPORT_DIR"] {
                let dir = URL(fileURLWithPath: out)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                model.renderBatchAsync(dir) { outs in
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
                    print("EXPORT OK \(outs.count) files -> \(files.sorted())")
                    fflush(stdout)   // 输出重定向到文件时是全缓冲，不 flush 会被 kill 掉
                }
            }
        }
    }
}

// ── 文件队列 ────────────────────────────────────────────
struct FileTable: View {
    @ObservedObject var model: Model
    let reduce: Bool
    var targeted = false
    let nameWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                paneTitle("文件队列")
                Spacer()
                HoverButton(tip: "清空文件队列", off: model.items.isEmpty) {
                    withAnimation(motion(reduce)) { model.clear() }
                } label: {
                    Text("清空")
                }

                HoverButton(tip: "添加文件（⌘O，可多选，也可选文件夹）") {
                    addViaPanel()
                } label: {
                    Label("添加文件", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)

            if model.items.isEmpty {
                empty.transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    columns
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                FileRow(model: model, item: item, index: idx, reduce: reduce, nameWidth: nameWidth)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
                .transition(.opacity)
            }
        }
        // 空态 ↔ 队列的交接用 200ms 强 ease-out，不然第一份文件是硬跳出来的
        .animation(reduce ? .easeOut(duration: 0.16) : Motion.out, value: model.items.isEmpty)
        .background(Color.clear)
        .onDeleteCommand { withAnimation(motion(reduce)) { model.removeSelected() } }
    }

    // 列宽是硬约束：队列栏 421pt，右侧每 1pt 都是从文件名嘴里抢出来的。
    // 旧的 页数(44) / 旋转(70) / 状态(44) / 删除(22) 四列合计 180pt 全部回收给文件名。
    private var columns: some View {
        HStack(spacing: 0) {
            Text("文件").frame(width: nameWidth, alignment: .leading)
            Text("范围").padding(.trailing, 8).frame(width: RowMetrics.rangeSlot, alignment: .trailing)
            Text("份数").padding(.trailing, 8).frame(width: RowMetrics.copiesSlot, alignment: .trailing)
            Text("").frame(width: RowMetrics.utilSlot)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, RowMetrics.hPad)
        .frame(height: 28)
    }

    // 空状态：不只是拖拽提示，也给一个居中的大按钮（和顶部 tab 同样的入口，但看得见）
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(targeted ? "松手即可加入队列" : "将文件或文件夹拖到这里")
                .font(.system(size: 13))
                .foregroundStyle(targeted ? Color.accentColor : Color.primary)
            Text("PDF · 图片 · Word/Excel/PPT，支持批量")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // 一个按钮就够：同一个面板里文件和文件夹都能选（选文件夹就把它里面的文件全加进来）
            HoverButton(kind: .cta, tip: "选择文件或文件夹（⌘O，可多选）") { addViaPanel() } label: {
                Label("添加文件", systemImage: "plus")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addViaPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        // 文件和文件夹都能选：不需要记得「想加一整个文件夹得按另一个按钮」
        p.canChooseFiles = true
        p.canChooseDirectories = true
        var types: [UTType] = [.pdf, .image]
        for e in OFFICE_EXTS { if let t = UTType(filenameExtension: e) { types.append(t) } }
        p.allowedContentTypes = types
        let r = p.runModal()
        resetCursorRects()
        guard r == .OK else { return }
        withAnimation(motion(reduce)) { model.add(p.urls) }
    }
}

// ── 行 ──────────────────────────────────────────────────
struct FileRow: View {
    @ObservedObject var model: Model
    let item: PrintItem
    let index: Int
    let reduce: Bool
    let nameWidth: CGFloat
    @State private var hover = false
    @State private var showRange = false

    // hoverPreview 是项目的快照 QA 钩子（BATCHPRINT_HOVER）：让「hover 才出现的东西」
    // 能被真实渲染出来验证。BATCHPRINT_HOVER_ROW=<idx> 只点亮某一行——否则快照里
    // 所有行的 × 都同时出现，看着像 bug，其实只是钩子的产物（真实行为是逐行 onHover）。
    @Environment(\.hoverPreview) private var hoverPreview
    private static let forcedHoverRow: Int? =
        ProcessInfo.processInfo.environment["BATCHPRINT_HOVER_ROW"].flatMap(Int.init)

    private var isSelected: Bool { model.current == index }
    private var badRange: Bool { !isValidRange(item.range, total: item.pages) }
    private var isDefaultRange: Bool { item.range.trimmingCharacters(in: .whitespaces) == "全部" }
    private var hl: Bool { hover || hoverPreview || Self.forcedHoverRow == index }

    // 范围 pill 的四个风格分量单独拆出来：写在 view 里编译器会 type-check 超时。
    private var rangeTextColor: Color {
        if badRange { return .red }
        return isDefaultRange ? .secondary : .accentColor
    }
    private var rangeFill: Color {
        guard isDefaultRange else { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(hl ? 0.07 : 0)
    }
    private var rangeBorder: Color {
        if badRange { return Color.red.opacity(0.75) }
        guard isDefaultRange else { return Color.accentColor.opacity(0.35) }
        return Color.primary.opacity(hl ? 0.16 : 0.08)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 文件名：折两行显示，不截断。列宽靠右侧固定列自然得出，
            // 只有**文本**自己 clipped（绝不能裁整个 cell：那会把文件类型图标一起挤没，
            // 实测 photo 符号会整片消失）。
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: item.isImage ? "photo" : (item.isOffice ? "doc.text" : "doc.richtext"))
                    // 文件类型只用**形状**区分，不用颜色：蓝色在本 app 里只有一个含义
                    // ——「这一行的打印设置偏离了默认」。icon 也上蓝的话，
                    // 用户扫列表时就不再能靠「突然蓝一下」发现异常。
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .fixedSize()
                    .frame(width: 13, alignment: .center)
                    .padding(.top, 2)
                nameText
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .help(item.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 页码范围：主窗口内不放文本输入框（避免 field editor 把 I-beam 卡到整窗），
            // 改成按钮 + popover 编辑
            Button {
                showRange = true
            } label: {
                Text(item.range)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(rangeTextColor)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    // 默认（全部）安静：无填充 + 极淡描边；hover 才抬起；
                    // 偏离默认（1–2）走蓝。再次贯彻「默认安静、偏离才讲话」。
                    .background(RoundedRectangle(cornerRadius: 5).fill(rangeFill))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(rangeBorder, lineWidth: badRange ? 1.6 : 1))
            }
            .buttonStyle(.plain)
            .help(badRange ? "页码范围无效（共 \(item.pages) 页），将按全部页打印" : "点击设置页码范围")
            .onChange(of: showRange) { open in
                if !open { resetCursorRects() }   // popover 收起后同样清理光标残留
            }
            .popover(isPresented: $showRange, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("页码范围 · 共 \(item.pages) 页")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("全部", text: rangeBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    Text("例：全部 / 1-3 / 1,3,5").font(.system(size: 10)).foregroundStyle(.tertiary)
                    if badRange {
                        Text("输入无效，将按全部页打印").font(.system(size: 10)).foregroundStyle(.red)
                    }
                    HStack(spacing: 6) {
                        Button("全部") { rangeBinding.wrappedValue = "全部" }
                        Button("奇数页") {
                            let odd = stride(from: 1, through: max(1, item.pages), by: 2).map(String.init)
                            rangeBinding.wrappedValue = odd.joined(separator: ",")
                        }
                        Spacer()
                        Button("完成") { showRange = false }.keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .frame(width: 216)
            }
            .padding(.trailing, 8)
            .frame(width: RowMetrics.rangeSlot, alignment: .trailing)

            // 份数：保持 v1.2 的「直接可点」步进器，只是收窄到 56pt，值偏离 1 才变蓝
            HStack(spacing: 0) {
                RailButton(sys: "minus", tip: "减少一份", off: item.copies <= 1) { bump(-1) }
                Text("\(item.copies)×")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(item.copies > 1 ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                RailButton(sys: "plus", tip: "增加一份", off: item.copies >= 99) { bump(1) }
            }
            .padding(.trailing, 6)
            .frame(width: RowMetrics.copiesSlot, alignment: .trailing)

            // 行尾效用位（固定宽度、左对齐）：
            // 旋转就是**一个按钮**：点一下 +90°，0→90→180→270→0 循环，可以一直点。
            // 未旋转时是一个安静的 ↻，转过之后变成蓝色的「↻90°」——
            // 状态和入口是同一个东西，既不用 hover 才出来，也不抽动布局。
            // （逆时针 ↺ 放在行右键菜单和预览头部：那两处有地方写标签。）
            HStack(spacing: 4) {
                if item.status != .ready {
                    StatusBadge(status: item.status)
                } else {
                    Button {
                        // ⌥ 点击 = 逆时针 90°。任何宽度成本都不花，却把「反悔」
                        // （270° 想回 90°）从两下变一下；不写进 UI，只写在 tooltip 里。
                        let ccw = NSEvent.modifierFlags.contains(.option)
                        rotate(ccw ? -90 : 90)
                    } label: {
                        Group {
                            if item.rotation == 0 {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                            } else {
                                Text("↻\(item.rotation)°")
                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                        }
                        .frame(minWidth: 20, minHeight: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(item.rotation == 0 ? Color.secondary : Color.accentColor)
                    .opacity(item.rotation == 0 && !hl ? 0.6 : 1)
                    .contentShape(Rectangle())
                    .animation(Motion.out, value: item.rotation)
                    .help(item.rotation == 0
                          ? "点击顺时针旋转 90°（⌥ 点击逆时针）"
                          : "当前 \(item.rotation)°，点击继续顺时针 90°（⌥ 点击逆时针）")
                    if hl {
                        RailButton(sys: "xmark.circle", tip: "从队列移除") {
                            withAnimation(motion(reduce)) { model.remove(item) }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: RowMetrics.utilSlot, alignment: .leading)
            // ⊗ 淡入而不是硬弹出（hover 类变化：快、微）
            .animation(.easeOut(duration: 0.12), value: hl)
            // 效用位左对齐：让淡 ↻ / 箭头 / ⊗ 始终贴着份数那一列，
            // 不然孔位太宽时会变成一片空白。右端固定宽度保证状态切换不抽动布局。
            .frame(width: 62, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(background)
        // 不占宽度的熟手路径：旋转 / 页码范围 / 移除都有稳定入口，
        // 不必依赖「记得这里能 hover」。
        .contextMenu {
            Button("左转 90°") { rotate(-90) }
            Button("右转 90°") { rotate(90) }
            if item.rotation != 0 {
                Button("复位方向") { rotate(-item.rotation) }
            }
            Divider()
            Button("设置页码范围…") { showRange = true }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("从队列移除") { withAnimation(motion(reduce)) { model.remove(item) } }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { model.current = index }
        // 选中/悬停底色用 120ms 的颜色过渡（tens/day 的操作：要快到几乎察觉不到）
        .animation(reduce ? nil : .easeOut(duration: 0.12), value: isSelected)
        // 进场/退场对称，起点 scale 0.97（不是 0，也不是 0.98 那种看不出来的）
        // 进场/退场只用 opacity：列表行整体 scale 会让密集表格的竖向基准一起「呼吸」，
        // 行的出现/消失本身就是布局位移，不需要额外的形状动画。
        .transition(.opacity)
    }

    /// 文件名 + 页数尾缀（灰，>1 页才有）。
    /// 旋转角度不放这里：名字占满两行时尾缀会被截掉，状态就看不见了。
    /// 用字符串插值而不是 `Text + Text`：后者在 macOS 26 已弃用。
    private var nameText: Text {
        item.pages > 1
            ? Text("\(Text(item.name))\(Text("  \(item.pages) 页").font(.system(size: 10.5)).foregroundStyle(Color.secondary))")
            : Text(item.name)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.13) }
        return hl ? Color.primary.opacity(scheme == .dark ? 0.11 : 0.06) : Color.clear
    }

    @Environment(\.colorScheme) private var scheme

    private func bump(_ d: Int) {
        if let i = model.items.firstIndex(where: { $0.id == item.id }) {
            model.items[i].copies = min(99, max(1, model.items[i].copies + d))
        }
    }

    // 只有「结果只能在预览里看到」的操作才抢焦点：旋转完预览不跳过去，用户看不到转动效果。
    // 范围/份数的结果就在行内看得见，所以不抢焦点。
    private func rotate(_ d: Int) {
        guard let i = model.items.firstIndex(where: { $0.id == item.id }) else { return }
        model.current = i
        withAnimation(.easeOut(duration: 0.15)) {
            model.items[i].rotation = normRotation(model.items[i].rotation + d)
        }
    }

    private var rangeBinding: Binding<String> {
        Binding(get: { item.range }, set: { v in
            if let i = model.items.firstIndex(where: { $0.id == item.id }) { model.items[i].range = v }
        })
    }
}

// ── 行尾密集控制区专用按钮 ─────────────────────────────
/// 比 HoverButton(.mini) 还小一号（18pt 宽）。
/// 队列栏 421pt 是硬约束，右侧每 1pt 都要从文件名嘴里抢：
/// 三个控件用 .mini 会吃掉 74pt，换成 18pt 后只吃 62pt。
struct RailButton: View {
    let sys: String
    let tip: String
    var off = false
    let action: () -> Void
    @State private var hover = false

    init(sys: String, tip: String, off: Bool = false, action: @escaping () -> Void) {
        self.sys = sys; self.tip = tip; self.off = off; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: sys)
                .font(.system(size: 11))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? Color.primary : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(hover ? 0.10 : 0)))
        .opacity(off ? 0.35 : 1)
        .disabled(off)
        .onHover { h in withAnimation(.easeOut(duration: 0.10)) { hover = h } }
        .help(tip)
    }
}

struct StatusBadge: View {
    let status: ItemStatus
    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(status == .ready ? .clear : color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(status == .ready ? Color.primary.opacity(0.18) : .clear,
                                            lineWidth: 1))
            .foregroundStyle(color)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
    private var color: Color {
        switch status {
        case .ready: return Color.primary.opacity(0.72)
        case .sent: return Color(red: 0.13, green: 0.55, blue: 0.32)
        case .failed: return Color(red: 0.8, green: 0.2, blue: 0.2)
        }
    }
}

func shortPrinter(_ s: String) -> String {
    s.replacingOccurrences(of: "__", with: " ").replacingOccurrences(of: "_", with: " ")
}

// ── 打印设置 ────────────────────────────────────────────
struct SettingsPanel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack { paneTitle("打印设置"); Spacer() }.padding(.horizontal, 14).frame(height: 42)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    group("打印机") {
                        Picker("", selection: $model.printer) {
                            if model.printers.isEmpty { Text("未找到打印机").tag("") }
                            ForEach(model.printers, id: \.self) { Text(shortPrinter($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.printer.isEmpty ? "没有检测到打印机" : model.printer)
                    }
                    group("页面缩放") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(ScaleMode.allCases) { m in
                                RadioRow(title: m.rawValue, selected: model.mode == m) {
                                    withAnimation(motion(false)) { model.mode = m }
                                }
                            }
                            if model.mode == .custom {
                                HStack(spacing: 10) {
                                    Slider(value: $model.percent, in: 50...100, step: 1)
                                    Text("\(Int(model.percent))%")
                                        .font(.system(size: 12).monospacedDigit())
                                        .frame(width: 44, alignment: .trailing)
                                }
                                .padding(.top, 6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    group("页面设置") {
                        row("纸张大小") {
                            Picker("", selection: $model.paper) {
                                ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 120)
                        }
                        row("页边距") {
                            Picker("", selection: $model.margin) {
                                ForEach(MarginMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 120)
                        }
                    }
                    row("双面打印") {
                        Toggle("", isOn: $model.duplex).toggleStyle(.switch).controlSize(.small)
                    }
                }
                .padding(14)
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .frame(height: 24)
    }
}

struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.28),
                                      lineWidth: 1.4)
                if selected { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
            }
            .frame(width: 15, height: 15)
            Text(title).font(.system(size: 12.5))
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(perform: action)
    }
}

// ── 预览 ────────────────────────────────────────────────
struct PreviewPane: View {
    @ObservedObject var model: Model
    let reduce: Bool
    @State private var image: NSImage?
    @State private var page = 1
    @Environment(\.colorScheme) private var scheme

    private var item: PrintItem? {
        model.items.indices.contains(model.current) ? model.items[model.current] : nil
    }
    private var pages: Int { item.map { parseRange($0.range, total: $0.pages).count } ?? 0 }
    private var key: String {
        "\(model.current)-\(model.mode.rawValue)-\(Int(model.percent))-\(page)-\(pages)-\(model.paper.rawValue)-\(model.margin.rawValue)-\(item?.rotation ?? 0)"
    }

    /// 旋转主入口作用在当前选中文件上，和行内按钮、右键菜单共用同一套归一化。
    private func rotateCurrent(_ d: Int) {
        guard model.items.indices.contains(model.current) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            model.items[model.current].rotation = normRotation(model.items[model.current].rotation + d)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                paneTitle("预览")
                Spacer()
                // 旋转主入口：作用在当前选中文件上。方向问题是用户在预览里
                // 发现「倒了」的，入口就该在手边，不靠 hover 也不靠记忆。
                if item != nil {
                    // 三个按钮固定占位，**没有「出现/消失」**：
                    // 复位以前是一个会冒出来的「↻90° · 复位」文字按钮，
                    // 结果每转一次就把旁边的 ↺ ↻ 推走一段，而鼠标正停在按钮上 ——
                    // 实测会来回来去变换位置、点错。
                    // 现在复位是第三个图标按钮，未旋转时禁用发淡，位置永远不变。
                    // 当前角度不再在这里重复（行尾已经写着 `↻90°`）。
                    HStack(spacing: 1) {
                        HoverButton(kind: .glyph, tip: "逆时针旋转 90°") { rotateCurrent(-90) } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                                .accessibilityLabel("逆时针旋转 90°")
                        }
                        HoverButton(kind: .glyph, tip: "顺时针旋转 90°") { rotateCurrent(90) } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12))
                                .accessibilityLabel("顺时针旋转 90°")
                        }
                        HoverButton(kind: .glyph,
                                    tip: (item?.rotation ?? 0) == 0
                                        ? "未旋转（无需复位）"
                                        : "复位方向（当前 \(item?.rotation ?? 0)°）",
                                    off: (item?.rotation ?? 0) == 0) {
                            rotateCurrent(-(item?.rotation ?? 0))
                        } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                                .accessibilityLabel("复位方向")
                        }
                    }
                    Text("\(model.paper.rawValue) · \(scaleLabel(model))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).frame(height: 42)

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .background(Color.white)
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.14), radius: 7, y: 3)
                        .overlay(Rectangle().strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : .clear))
                        .padding(24)
                        .id(key)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("添加文件后显示预览")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: key)

            if item != nil && pages > 1 {
                HStack(spacing: 12) {
                    HoverButton(kind: .quiet, tip: "上一页", off: page <= 1) {
                        page = max(1, page - 1)
                    } label: { Image(systemName: "chevron.left").accessibilityLabel("上一页") }

                    Text("\(min(page, max(1, pages))) / \(max(1, pages))")
                        .font(.system(size: 11).monospacedDigit())

                    HoverButton(kind: .quiet, tip: "下一页", off: page >= pages) {
                        page = min(pages, page + 1)
                    } label: { Image(systemName: "chevron.right").accessibilityLabel("下一页") }
                    Spacer()
                    Text(item?.name ?? "").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 30)
            }
        }
        .task(id: key) {
            guard let it = item else { image = nil; return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            // 防抖：这一帧已经被后一次点击取代了就别再渲染。
            // （以前 `try? await Task.sleep` 被取消后还会继续往下跑，
            //   连续转几次就等于排队渲染好几次，手感是「点了没反应」）
            guard !Task.isCancelled else { return }
            let want = parseRange(it.range, total: it.pages)
            let src = want.indices.contains(page - 1) ? want[page - 1] : (want.first ?? 1)
            // 值快照：渲染在后台线程跑，不能再碰 model
            let (u, m, pc, pp, mg, rt) = (it.url, model.mode, model.percent,
                                          model.paper, model.margin, it.rotation)
            let next = await renderOffMain {
                renderPage(url: u, mode: m, percent: pc, sourcePage: src,
                           paper: pp, margin: mg, rotation: rt)
            }
            // 回来后再确认一次：后台渲染期间用户可能又点了，别用旧图盖住新图
            guard !Task.isCancelled else { return }
            // 不做「转过去」的动画：旋转是精确几何变换，内容自己换了朝向已经说明了一切，
            // 再叠一个 90° 旋转既生硬又多余（旋转本身是 tens/day 的操作，应近乎无感）。
            // 图本身还是带 opacity 交叉淡入的（.animation(.easeOut, value: key)）。
            image = next
        }
        .onChange(of: model.current) { _, _ in page = 1 }
    }
}

// ── 底栏 ────────────────────────────────────────────────
struct BottomBar: View {
    @ObservedObject var model: Model

    /// 版本号从 Info.plist 读，避免「装了新版，界面上看不出来」
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.items.count) 个文件 · \(model.totalSheets) 页")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(.secondary)

            if !model.message.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(model.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            Spacer()
            Text("v\(version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("批量打印工具版本")
            if model.busy { ProgressView().controlSize(.small) }

            HoverButton(tip: "只生成缩放后的 PDF，不打印", off: model.items.isEmpty) {
                model.doExport()
            } label: {
                Label("导出 PDF", systemImage: "square.and.arrow.down")
            }

            HoverButton(kind: .cta,
                        tip: model.items.isEmpty ? "先添加 PDF 文件"
                             : (model.printer.isEmpty ? "未检测到打印机" : "⌘P"), off: model.items.isEmpty || model.printer.isEmpty || model.busy) {
                model.doPrint()
            } label: {
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "正在发送…" : "开始打印").frame(minWidth: 78)
                }
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
        .animation(.easeOut(duration: 0.18), value: model.message)
    }
}

// ── 入口 ────────────────────────────────────────────────
// ── 光标策略（系统性修复）────────────────────────────────
// 已定位根因：AppKit/SwiftUI 在文本输入获得 first responder 后会把全局光标设为 I-beam，
// 而鼠标离开时没有可靠的复位机制（实测 cursorUpdate tracking area = 0，cursor rect 未生效）。
// 因此本 app 自己持有光标策略：窗口内除「真正可编辑的文本视图」之外，一律箭头。
func isEditableText(_ v: NSView?) -> Bool {
    var cur = v
    while let c = cur {
        if let tv = c as? NSTextView, tv.isEditable { return true }
        if let tf = c as? NSTextField, tf.isEditable { return true }
        let n = String(describing: type(of: c))
        if n.contains("FieldEditor") || n.contains("TextViewport") { return true }
        cur = c.superview
    }
    return false
}

func startCursorGuard() {
    // 根因：AppKit 每次鼠标移动都会用 cursor rect 重新 set 光标，所以“只在 monitor 里 set 一次”会被覆盖。
    // 处置：本 app 接管光标管理——禁用系统 cursor rect，自己按命中视图决定。
    func takeOver(_ w: NSWindow?) { w?.disableCursorRects() }
    // init 阶段 NSApp 还没就绪，必须等第一个 runloop 之后再接管
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        for w in NSApp.windows { takeOver(w) }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                           object: nil, queue: .main) { note in
        takeOver(note.object as? NSWindow)
    }

    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .leftMouseDragged, .leftMouseDown]) { e in
        guard let win = e.window, let cv = win.contentView else { return e }
        let p = cv.convert(e.locationInWindow, from: nil)
        let want: NSCursor = isEditableText(cv.hitTest(p)) ? .iBeam : .arrow
        if NSCursor.current != want { want.set() }
        return e
    }
    // 生命周期修复：窗口重新成为 key（从 popover / 面板 / 别的 app 回来）时废弃陈旧 cursor rect
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                           object: nil, queue: .main) { note in
        guard let w = note.object as? NSWindow, let cv = w.contentView else { return }
        func walk(_ v: NSView) {
            w.invalidateCursorRects(for: v)
            for c in v.subviews { walk(c) }
        }
        walk(cv)
    }
}

// 运行期 cursor 探针：记录鼠标位置 / 当前 cursor / 该点命中的视图类
func startCursorLog() {
    let env = ProcessInfo.processInfo.environment
    guard env["BATCHPRINT_CURSORLOG"] != nil || env["BATCHPRINT_CLICKPROBE"] != nil else { return }
    var lines: [String] = ["=== probe start ==="]
    func flush() {
        try? lines.joined(separator: "\n").write(toFile: "/tmp/bp-cursor.log", atomically: true, encoding: .utf8)
    }
    // 点击后探测：firstResponder / 共享 field editor（NSTextView）的类与 frame
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
        guard let win = e.window else { return e }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let fr = win.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let fe = win.fieldEditor(false, for: nil)
            let feClass = fe.map { String(describing: type(of: $0)) } ?? "nil"
            let feFrame = fe.map { "[\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))x\(Int($0.frame.height))]" } ?? ""
            lines.append("CLICK firstResponder=\(fr) fieldEditor=\(feClass) \(feFrame) cursor=\(NSCursor.current == NSCursor.iBeam ? "IBEAM" : "other")")
            if env["BATCHPRINT_DUMP"] != nil {
                dumpLines = []
                if let cv = win.contentView { dumpNSViews(cv, 0) }
                try? dumpLines.joined(separator: "\n").write(toFile: "/tmp/bp-viewdump.txt", atomically: true, encoding: .utf8)
            }
            flush()
        }
        return e
    }
    // 移动事件：记录坐标 / 命中的 AppKit 视图 / 该视图注册的 tracking area
    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .mouseEntered]) { e in
        guard let win = e.window, let cv = win.contentView else { return e }
        let p = cv.convert(e.locationInWindow, from: nil)
        let hit = cv.hitTest(p)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"
        var ta = ""
        if let h = hit {
            let areas = h.trackingAreas.filter { $0.options.contains(.cursorUpdate) }
            if !areas.isEmpty {
                ta = " cursorUpdateAreas=\(areas.count) rects=\(areas.map { NSStringFromRect($0.rect) }.joined(separator: "|"))"
            }
        }
        lines.append("pt \(Int(p.x)),\(Int(p.y)) cursor=\(NSCursor.current == NSCursor.iBeam ? "IBEAM" : "other") hit=\(hitName)\(ta)")
        flush()
        return e
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let w = NSApp.windows.first, let cv = w.contentView {
            let f = w.convertToScreen(cv.convert(cv.bounds, to: nil))
            lines.append("windowFrame screen=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
            lines.append("contentView=\(String(describing: type(of: cv)))")
            flush()
        }
    }
}

// 模态面板（NSOpenPanel）关闭后残余 cursor rect 会让整窗残留 I-beam——
// 根因修复：面板收起时废弃旧 cursor rect，而不是用 overlay 强行改光标。
func resetCursorRects() {
    NSCursor.arrow.set()
    guard let w = NSApp.keyWindow ?? NSApp.windows.first, let cv = w.contentView else { return }
    func walk(_ v: NSView) {
        w.invalidateCursorRects(for: v)
        for c in v.subviews { walk(c) }
    }
    walk(cv)
}

// 视图树诊断：找「覆盖大面积的可编辑文本视图」这类 cursor 污染源
var dumpLines: [String] = []
func dumpNSViews(_ v: NSView, _ d: Int) {
    let pad = String(repeating: "  ", count: d)
    let name = String(describing: type(of: v))
    let area = v.frame.width * v.frame.height
    let textish = name.contains("Text") || name.contains("Edit") || name.contains("Field")
    let flag = (textish && area > 20000) ? "   <== 大面积文本类视图" : ""
    dumpLines.append("\(pad)\(name) [\(Int(v.frame.origin.x)),\(Int(v.frame.origin.y)) \(Int(v.frame.width))x\(Int(v.frame.height))]\(flag)")
    for c in v.subviews { dumpNSViews(c, d + 1) }
}

func snapshotIfRequested() {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["BATCHPRINT_SNAPSHOT"] else { return }
    let delay = Double(ProcessInfo.processInfo.environment["BATCHPRINT_SNAPSHOT_DELAY"] ?? "") ?? 3.0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let v = win.contentView else {
            print("SNAPSHOT FAILED: no window")
            NSApp.terminate(nil)
            return
        }
        v.layoutSubtreeIfNeeded()
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("SNAPSHOT OK \(out) \(Int(v.bounds.width))x\(Int(v.bounds.height))")
            }
        } else {
            print("SNAPSHOT FAILED: no rep")
        }
        if ProcessInfo.processInfo.environment["BATCHPRINT_DUMP"] != nil {
            dumpNSViews(v, 0)
            try? dumpLines.joined(separator: "\n").write(toFile: "/tmp/bp-viewdump.txt", atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}

@main
struct BatchPrintApp: App {
    init() { snapshotIfRequested(); startCursorGuard(); startCursorLog() }
    var body: some Scene {
        WindowGroup("批量打印工具") {
            ContentView(sampleDir: ProcessInfo.processInfo.environment["BATCHPRINT_SAMPLE_DIR"])
                .preferredColorScheme(ProcessInfo.processInfo.environment["BATCHPRINT_DARK"] != nil ? .dark : nil)
                .environment(\.hoverPreview, ProcessInfo.processInfo.environment["BATCHPRINT_HOVER"] != nil)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1240, height: 730)
    }
}
