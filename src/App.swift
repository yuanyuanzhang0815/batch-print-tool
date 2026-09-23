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

    func scaleAll(to dir: URL) -> [URL] {
        var outs: [URL] = []
        for it in items {
            let want = parseRange(it.range, total: it.pages)
            for copy in 0..<max(1, it.copies) {
                let suffix = it.copies > 1 ? "-c\(copy + 1)" : ""
                if let o = scaledPDF(input: it.url, outDir: dir, mode: mode, percent: percent,
                                     pages: want, suffix: suffix, paper: paper, margin: margin,
                                     rotation: it.rotation) {
                    outs.append(o)
                }
            }
        }
        return outs
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
        let outs = scaleAll(to: dir)
        flash(outs.isEmpty ? "导出失败，检查 PDF 是否损坏" : "已导出 \(outs.count) 个文件 → \(dir.lastPathComponent)")
    }

    func doPrint() {
        guard !items.isEmpty else { return }
        guard !printer.isEmpty else { flash("没找到打印机"); return }
        busy = true
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bp-\(UUID().uuidString)")
        let outs = scaleAll(to: tmp)
        guard !outs.isEmpty else {
            busy = false
            flash("生成失败，检查 PDF 是否损坏", seconds: 6)
            return
        }
        var args = ["-d", printer, "-o", "Collate=\(outs.count > 1 ? "True" : "False")"]
        if duplex { args += ["-o", "sides=two-sided-long-edge"] }
        args += outs.map { $0.path }
        let out = runCmd("/usr/bin/lp", args)
        busy = false
        let ok = out.lowercased().contains("request id") || out.contains("请求id")
            || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ok {
            for i in items.indices { items[i].status = .sent }
            flash("已发送到 \(shortPrinter(printer))：\(outs.count) 个文件 / \(totalSheets) 页")
        } else {
            for i in items.indices { items[i].status = .failed }
            flash("打印失败：\(out.prefix(90))", seconds: 8)
        }
    }
}

// ── 动效：按 animate 决策，frequency 低→弹簧；reduce motion 降级 ──
func motion(_ reduce: Bool) -> Animation? {
    reduce ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.82)
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

// ── 主界面：文件队列 34% ｜ 打印设置 23% ｜ 预览 43% ─────
struct ContentView: View {
    var sampleDir: String? = nil
    @StateObject var model = Model()
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    FileTable(model: model, reduce: reduce, targeted: targeted)
                        .frame(width: max(340, geo.size.width * 0.34))
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
            }
        }
    }
}

// ── 文件队列 ────────────────────────────────────────────
struct FileTable: View {
    @ObservedObject var model: Model
    let reduce: Bool
    var targeted = false

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
                empty
            } else {
                columns
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                            FileRow(model: model, item: item, index: idx, reduce: reduce)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .background(Color.clear)
        .onDeleteCommand { withAnimation(motion(reduce)) { model.removeSelected() } }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Text("文件名").frame(maxWidth: .infinity, alignment: .leading)
            Text("页数").frame(width: 32, alignment: .center)
            Text("页码范围").frame(width: 74, alignment: .center)
            Text("旋转").frame(width: 70, alignment: .center)
            Text("份数").frame(width: 56, alignment: .center)
            Text("状态").frame(width: 44, alignment: .center)
            Text("").frame(width: 22)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(targeted ? "松手即可加入队列" : "将文件或文件夹拖到这里")
                .font(.system(size: 13))
                .foregroundStyle(targeted ? Color.accentColor : Color.primary)
            Text("PDF · 图片 · Word/Excel/PPT，支持批量").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addViaPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
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
    @State private var hover = false
    @State private var showRange = false

    private var isSelected: Bool { model.current == index }
    private var badRange: Bool { !isValidRange(item.range, total: item.pages) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: item.isImage ? "photo" : (item.isOffice ? "doc.text" : "doc.richtext"))
                    .font(.system(size: 12))
                    .foregroundStyle(item.isImage
                        ? Color(red: 0.16, green: 0.48, blue: 0.88)
                        : (item.isOffice ? Color(red: 0.13, green: 0.55, blue: 0.32)
                                         : Color(red: 0.84, green: 0.27, blue: 0.22)))
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(item.pages)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44)

            // 页码范围：主窗口内不放文本输入框（避免 field editor 把 I-beam 卡到整窗），
            // 改成按钮 + popover 编辑
            Button {
                showRange = true
            } label: {
                Text(item.range)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(width: 54)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hover ? 0.07 : 0.0)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(badRange ? Color.red.opacity(0.75) : Color.primary.opacity(0.12),
                                      lineWidth: badRange ? 1.6 : 1))
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
            .frame(width: 74)

            // 旋转：逐文件 90° 步进（逆时针 / 顺时针），非 0 时显示当前角度
            HStack(spacing: 0) {
                HoverButton(kind: .mini, tip: "逆时针旋转 90°") { rotate(-90) } label: {
                    Image(systemName: "rotate.left").font(.system(size: 11))
                        .accessibilityLabel("逆时针旋转 90°")
                }
                Text(item.rotation == 0 ? "—" : "\(item.rotation)°")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(item.rotation == 0 ? Color.secondary : Color.accentColor)
                    .frame(width: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { if item.rotation != 0 { rotate(-item.rotation) } }
                    .help(item.rotation == 0 ? "未旋转" : "点击归零")
                HoverButton(kind: .mini, tip: "顺时针旋转 90°") { rotate(90) } label: {
                    Image(systemName: "rotate.right").font(.system(size: 11))
                        .accessibilityLabel("顺时针旋转 90°")
                }
            }
            .frame(width: 70)

            // 份数：步进器（无文本输入）
            HStack(spacing: 1) {
                HoverButton(kind: .mini, tip: "减少一份", off: item.copies <= 1) { bump(-1) } label: {
                    Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
                }
                Text("\(item.copies)")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 14)
                HoverButton(kind: .mini, tip: "增加一份", off: item.copies >= 99) { bump(1) } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 56)

            StatusBadge(status: item.status).frame(width: 44)

            HoverButton(kind: .mini, tip: "从队列移除") {
                withAnimation(motion(reduce)) { model.remove(item) }
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 12))
                    .accessibilityLabel("从队列移除 \(item.name)")
            }
            .frame(width: 22)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(background)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { model.current = index }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.13) }
        return hover ? Color.primary.opacity(scheme == .dark ? 0.11 : 0.06) : Color.clear
    }

    @Environment(\.colorScheme) private var scheme

    private func bump(_ d: Int) {
        if let i = model.items.firstIndex(where: { $0.id == item.id }) {
            model.items[i].copies = min(99, max(1, model.items[i].copies + d))
        }
    }

    private func rotate(_ d: Int) {
        guard let i = model.items.firstIndex(where: { $0.id == item.id }) else { return }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                paneTitle("预览")
                Spacer()
                if item != nil {
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
            let want = parseRange(it.range, total: it.pages)
            let src = want.indices.contains(page - 1) ? want[page - 1] : (want.first ?? 1)
            image = renderPage(url: it.url, mode: model.mode, percent: model.percent,
                               sourcePage: src, paper: model.paper, margin: model.margin,
                               rotation: it.rotation)
        }
        .onChange(of: model.current) { _ in page = 1 }
    }
}

// ── 底栏 ────────────────────────────────────────────────
struct BottomBar: View {
    @ObservedObject var model: Model

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
    let delay = Double(ProcessInfo.processInfo.environment["BATCHPRINT_SNAPSHOT_DELAY"] ?? "") ?? 2.2
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
