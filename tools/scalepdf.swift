import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: scalepdf <percent> <outdir> <fit|raw> <in.pdf>...")
    exit(2)
}
let mode = args[3]
let pct = CGFloat(Double(args[1]) ?? 80.0) / 100.0
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let A4W: CGFloat = 595.276, A4H: CGFloat = 841.89
for path in args.dropFirst(4) {
    let inURL = URL(fileURLWithPath: path)
    guard let src = CGPDFDocument(inURL as CFURL) else {
        FileHandle.standardError.write("SKIP \(path)\n".data(using: .utf8)!)
        continue
    }
    let outURL = outDir.appendingPathComponent(inURL.deletingPathExtension().lastPathComponent + "-x\(Int(pct*100))-\(mode).pdf")
    var box = CGRect(x: 0, y: 0, width: A4W, height: A4H)
    guard let ctx = CGContext(outURL as CFURL, mediaBox: &box, nil) else { continue }
    for i in 1...src.numberOfPages {
        guard let page = src.page(at: i) else { continue }
        let c = page.getBoxRect(.cropBox)
        let k = (mode == "fit") ? min(A4W / c.width, A4H / c.height) : 1.0
        let s0 = pct * k
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        let w = c.width * s0, h = c.height * s0
        ctx.translateBy(x: (A4W - w) / 2 - c.minX * s0, y: (A4H - h) / 2 - c.minY * s0)
        ctx.scaleBy(x: s0, y: s0)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        ctx.endPDFPage()
    }
    ctx.closePDF()
    print("OK \(outURL.path)")
}
