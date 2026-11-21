// 总图 → 宠物皮肤（theme.cursor + idle.plist + MenuIcon.png）。
// 总图：同一只宠物 20 个姿势，4 列 5 行，纯色背景。1–16 格对应 16 种指针状态，17–19 格跳舞，20 格睡觉。
// 指针符号（箭头、I 形、双向箭头…）在这里画，点击点固定，不靠 AI 画，换什么动物都对得准。
// 坐标一律用 256×256 画布、y 轴向下。
import AppKit
import CoreText

enum SkinMaker {
    struct Failure: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    static let names = ["01_正常", "02_文字输入", "03_链接", "04_不可用", "05_忙碌", "06_移动", "07_左右调整", "08_上下调整",
                        "09_斜向调整_左上右下", "10_斜向调整_右上左下", "11_帮助", "12_十字瞄准", "13_复制", "14_张开爪",
                        "15_抓紧爪", "16_放大"]
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, a])!
    }
    static let outline = rgb(58, 32, 20)
    static let white = rgb(255, 255, 255)
    static let textFill = rgb(70, 38, 22)            // 音符和 z：深棕字白描边，亮暗背景都看得见
    static let ow: CGFloat = 5                        // 描边粗细
    static let petH: CGFloat = 162                    // 「正常」姿势宠物的高度
    static let footY: CGFloat = 251, petCX: CGFloat = 166, petMaxW: CGFloat = 170
    static let points = 40                            // 指针在屏幕上 40pt 见方

    // MARK: 画布工具
    static func ctx(_ w: Int, _ h: Int, flipped: Bool = true) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        if flipped { c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1) }
        return c
    }

    /// 在 y 向下的画布上正着画图
    static func drawUp(_ c: CGContext, _ img: CGImage, _ r: CGRect) {
        c.saveGState()
        c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1)
        c.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        c.restoreGState()
    }

    struct RGBA { let w: Int; let h: Int; var p: [UInt8] }   // 不预乘，第 0 行是最上面一行

    static func read(_ img: CGImage) -> RGBA {
        let w = img.width, h = img.height
        let c = ctx(w, h, flipped: false)
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = c.bytesPerRow
        let src = c.data!.assumingMemoryBound(to: UInt8.self)
        var p = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * bpr + x * 4, d = (y * w + x) * 4
                let a = Int(src[s + 3])
                p[d + 3] = UInt8(a)
                for k in 0..<3 { p[d + k] = a == 0 ? 0 : UInt8(min(255, Int(src[s + k]) * 255 / a)) }
            }
        }
        return RGBA(w: w, h: h, p: p)
    }

    static func image(_ b: RGBA) -> CGImage {
        CGImage(width: b.w, height: b.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.w * 4, space: srgb,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: Data(b.p) as CFData)!, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)!
    }

    static func png(_ img: CGImage) -> Data {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    }

    // MARK: 1. 抠图、切格
    /// 背景色取四边像素的中位数；按颜色距离抠掉，边缘半透明像素反混合掉背景色
    static func removeBg(_ img: CGImage) -> RGBA {
        let src = read(img); let w = src.w, h = src.h
        var border: [[Double]] = [[], [], []]
        func add(_ x: Int, _ y: Int) { let i = (y * w + x) * 4; for k in 0..<3 { border[k].append(Double(src.p[i + k])) } }
        for x in 0..<w { add(x, 0); add(x, h - 1) }
        for y in 0..<h { add(0, y); add(w - 1, y) }
        let bg = border.map { v -> Double in let s = v.sorted(); return (s[s.count / 2] + s[(s.count - 1) / 2]) / 2 }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let r = Double(src.p[i * 4]), g = Double(src.p[i * 4 + 1]), b = Double(src.p[i * 4 + 2])
            let dr = r - bg[0], dg = g - bg[1], db = b - bg[2]
            let d: Double = (dr * dr + dg * dg + db * db).squareRoot()
            let a: Double = min(max((d - 60) / 80, 0), 1)
            let al: Double = max(a, 1e-3)
            let c: [Double] = [r, g, b]
            for k in 0..<3 {
                let v: Double = (c[k] - (1 - al) * bg[k]) / al
                out[i * 4 + k] = UInt8(min(max(v, 0), 255))
            }
            out[i * 4 + 3] = UInt8(a * 255)
        }
        return RGBA(w: w, h: h, p: out)
    }

    static func dilate(_ m: [Bool], _ w: Int, _ h: Int, _ n: Int) -> [Bool] {
        var cur = m
        for _ in 0..<n {
            var nx = cur
            for y in 0..<h {
                for x in 0..<w where !cur[y * w + x] {
                    let i = y * w + x
                    if (x > 0 && cur[i - 1]) || (x < w - 1 && cur[i + 1]) || (y > 0 && cur[i - w]) || (y < h - 1 && cur[i + w]) {
                        nx[i] = true
                    }
                }
            }
            cur = nx
        }
        return cur
    }

    static func label(_ m: [Bool], _ w: Int, _ h: Int) -> ([Int32], Int) {
        var lab = [Int32](repeating: 0, count: w * h)
        var n: Int32 = 0
        var stack: [Int] = []
        for s in 0..<(w * h) where m[s] && lab[s] == 0 {
            n += 1; lab[s] = n; stack.append(s)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                    where j >= 0 && m[j] && lab[j] == 0 {
                    lab[j] = n; stack.append(j)
                }
            }
        }
        return (lab, Int(n))
    }

    /// 按连通块归格：每块按重心落在哪一格归到哪一格，不怕图里的格子画得不齐
    static func split(_ im: RGBA, cols: Int = 4, rows: Int = 5) throws -> [CGImage] {
        let w = im.w, h = im.h
        let solid = (0..<(w * h)).map { im.p[$0 * 4 + 3] > 100 }
        let (lab, n) = label(dilate(solid, w, h, 3), w, h)        // 稍微膨胀，汗滴这类小件并进身体
        var size = [Double](repeating: 0, count: n + 1), sx = size, sy = size
        for i in 0..<(w * h) where solid[i] {
            let k = Int(lab[i]); size[k] += 1; sx[k] += Double(i % w); sy[k] += Double(i / w)
        }
        var cellOf = [Int](repeating: -1, count: n + 1)
        for k in stride(from: 1, through: n, by: 1) where size[k] >= 200 {   // 零星杂点不要
            let r = min(Int(sy[k] / size[k] / Double(h) * Double(rows)), rows - 1)
            let c = min(Int(sx[k] / size[k] / Double(w) * Double(cols)), cols - 1)
            cellOf[k] = r * cols + c
        }
        var out: [CGImage] = []
        for cell in 0..<(cols * rows) {
            var m = [Bool](repeating: false, count: w * h)
            var x0 = w, y0 = h, x1 = -1, y1 = -1
            for i in 0..<(w * h) {
                let k = Int(lab[i])
                if k > 0 && cellOf[k] == cell {
                    m[i] = true
                    let x = i % w, y = i / w
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            if x1 < 0 { throw Failure(msg: "第 \(cell + 1) 格是空的：总图要 4 列 5 行、每格一只，宠物之间留够空白。请重新出图。") }
            let md = dilate(m, w, h, 2)
            let cx0 = max(0, x0 - 2), cy0 = max(0, y0 - 2), cx1 = min(w, x1 + 3), cy1 = min(h, y1 + 3)
            let cw = cx1 - cx0, ch = cy1 - cy0
            var p = [UInt8](repeating: 0, count: cw * ch * 4)
            for y in 0..<ch {
                for x in 0..<cw {
                    let si = (y + cy0) * w + (x + cx0)
                    guard md[si] else { continue }
                    for k in 0..<4 { p[(y * cw + x) * 4 + k] = im.p[si * 4 + k] }
                }
            }
            out.append(image(RGBA(w: cw, h: ch, p: p)))
        }
        return out
    }

    /// 宠物按统一比例缩放，脚底对齐、放在画布右下；太宽的姿势单独缩小
    static func placeRect(_ pet: CGImage, _ sc: CGFloat) -> CGRect {
        var w = (CGFloat(pet.width) * sc).rounded(), h = (CGFloat(pet.height) * sc).rounded()
        if w > petMaxW { h = (h * petMaxW / w).rounded(); w = petMaxW }
        if h > 200 { w = (w * 200 / h).rounded(); h = 200 }
        let x = min((petCX - w / 2).rounded(), 256 - 2 - w)
        return CGRect(x: x, y: footY - h, width: w, height: h)
    }

    // MARK: 2. 指针符号
    enum Shape { case poly([CGPoint]), ellipse(CGRect), rrect(CGRect, CGFloat) }

    static func symCtx() -> CGContext {              // 4 倍画再缩小，边缘平滑
        let c = ctx(1024, 1024); c.scaleBy(x: 4, y: 4); c.setLineJoin(.round); return c
    }

    static func down(_ c: CGContext) -> CGImage {
        let s = ctx(256, 256)
        drawUp(s, c.makeImage()!, CGRect(x: 0, y: 0, width: 256, height: 256))
        return s.makeImage()!
    }

    /// 先把所有形状加粗画成描边色，再统一填白：多个形状合成一个外轮廓
    static func strokeFill(_ c: CGContext, _ shapes: [Shape], fill: CGColor = white) {
        for pass in 0..<2 {
            let col = pass == 0 ? outline : fill
            c.setFillColor(col); c.setStrokeColor(outline)
            for s in shapes {
                switch s {
                case .poly(let pts):
                    let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
                    c.addPath(path)
                    if pass == 0 { c.setLineWidth(ow * 2); c.drawPath(using: .fillStroke) } else { c.fillPath() }
                case .ellipse(let r):
                    c.fillEllipse(in: pass == 0 ? r.insetBy(dx: -ow, dy: -ow) : r)
                case .rrect(let r, let rad):
                    let e = pass == 0 ? ow : 0
                    let rr = r.insetBy(dx: -e, dy: -e)
                    let cr = min(rad + e, rr.width / 2 - 0.01, rr.height / 2 - 0.01)
                    c.addPath(CGPath(roundedRect: rr, cornerWidth: cr, cornerHeight: cr, transform: nil)); c.fillPath()
                }
            }
        }
    }

    static func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func arrowPts(_ tip: CGPoint = CGPoint(x: 8, y: 6), _ k: CGFloat = 1.15) -> [CGPoint] {
        [(0, 0), (0, 96), (23, 75), (38, 109), (54, 102), (39, 69), (69, 69)].map { CGPoint(x: tip.x + $0.0 * k, y: tip.y + $0.1 * k) }
    }

    static func doubleArrow(_ c: CGPoint, _ ang: CGFloat, _ L: CGFloat = 96, sw: CGFloat = 8, hw: CGFloat = 22, hl: CGFloat = 26) -> [CGPoint] {
        let pts: [(CGFloat, CGFloat)] = [(L / 2, 0), (L / 2 - hl, hw), (L / 2 - hl, sw), (-L / 2 + hl, sw), (-L / 2 + hl, hw), (-L / 2, 0),
                                         (-L / 2 + hl, -hw), (-L / 2 + hl, -sw), (L / 2 - hl, -sw), (L / 2 - hl, -hw)]
        let ca = cos(ang * .pi / 180), sa = sin(ang * .pi / 180)
        return pts.map { CGPoint(x: c.x + $0.0 * ca - $0.1 * sa, y: c.y + $0.0 * sa + $0.1 * ca) }
    }

    /// 以 c 为原点、按 k 缩放的椭圆
    static func oval(_ c: CGPoint, _ k: CGFloat, _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
        box(c.x + (x - rx) * k, c.y + (y - ry) * k, c.x + (x + rx) * k, c.y + (y + ry) * k)
    }

    /// 爪子（同自带橘猫）：一整只圆手套，上沿 4 个鼓包当趾头；
    /// point=true 时最左边的趾头沿手套左边伸长成粗粗的「食指」
    static func paw(_ c: CGPoint, _ k: CGFloat = 1, point: Bool = false) -> [Shape] {
        var sh: [Shape] = [.ellipse(oval(c, k, 0, 6, 38, 36))]
        if point {
            sh.append(.rrect(box(c.x - 38 * k, c.y - 92 * k, c.x - 6 * k, c.y + 4 * k), 16 * k))
            sh += [(6, -26, 14), (22, -22, 14), (33, -10, 12)].map { .ellipse(oval(c, k, $0.0, $0.1, $0.2, $0.2)) }
        } else {
            sh += [(-25, -22, 15), (-9, -32, 16), (9, -32, 16), (25, -22, 15)].map { .ellipse(oval(c, k, $0.0, $0.1, $0.2, $0.2)) }
        }
        return sh
    }

    /// 大粉肉垫：三瓣掌垫 + 每个趾头一颗
    static func pinkPads(_ g: CGContext, _ c: CGPoint, _ k: CGFloat = 1, point: Bool = false) {
        g.setFillColor(rgb(245, 140, 160))
        let beans: [(CGFloat, CGFloat, CGFloat, CGFloat)] = point
            ? [(-22, -74, 9, 11), (6, -22, 8, 9), (22, -18, 8, 9), (33, -7, 6, 7)]
            : [(-25, -18, 8, 9), (-9, -28, 9, 10), (9, -28, 9, 10), (25, -18, 8, 9)]
        for (x, y, rx, ry) in beans + [(0, 20, 22, 15), (-11, 9, 11, 10), (11, 9, 11, 10)] {
            g.fillEllipse(in: oval(c, k, x, y, rx, ry))
        }
    }

    /// 握拳：拳身 + 4 个指节
    static func fist(_ c: CGPoint) -> [Shape] {
        var sh: [Shape] = [.rrect(box(c.x - 36, c.y - 16, c.x + 36, c.y + 38), 22)]
        for dx: CGFloat in [-27, -9, 9, 27] { sh.append(.ellipse(box(c.x + dx - 12, c.y - 30, c.x + dx + 12, c.y - 4))) }
        return sh
    }

    // 链接 / 张开爪 / 抓紧爪：爪子本身就是指针，往左上斜着，像在指；宠物照常坐在右下，不用举爪
    static let signTilt: CGFloat = -22 * .pi / 180     // 往左上倾
    static let linkC = CGPoint(x: 74, y: 95), openC = CGPoint(x: 64, y: 76), fistC = CGPoint(x: 66, y: 78)
    static let linkK: CGFloat = 0.95, openK: CGFloat = 1.0, fistK: CGFloat = 1.15

    /// 绕 c 转 signTilt（和画爪子时的画布旋转一致），用来算点击点
    static func turn(_ p: CGPoint, _ c: CGPoint) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y, a = signTilt
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    static func tilt(_ g: CGContext, _ c: CGPoint, scale k: CGFloat = 1) {
        g.translateBy(x: c.x, y: c.y); g.rotate(by: signTilt); g.scaleBy(x: k, y: k); g.translateBy(x: -c.x, y: -c.y)
    }

    static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

    /// 画字：at = 左上（字的上沿）；centered 时 at = 字形中心。stroke 为白描边粗细
    static func text(_ c: CGContext, _ s: String, _ f: CTFont, at p: CGPoint, fill: CGColor, stroke: CGFloat = 0,
                     alpha: CGFloat = 1, centered: Bool = false) {
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let origin = centered ? CGPoint(x: p.x - b.midX, y: p.y + b.midY) : CGPoint(x: p.x, y: p.y + CTFontGetAscent(f))
        c.saveGState()
        c.setAlpha(alpha); c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if stroke > 0 {
            c.setTextDrawingMode(.stroke); c.setStrokeColor(white); c.setLineWidth(stroke * 2); c.setLineJoin(.round)
            c.textPosition = origin; CTLineDraw(line, c)
        }
        c.setTextDrawingMode(.fill); c.setFillColor(fill)
        c.textPosition = origin; CTLineDraw(line, c)
        c.endTransparencyLayer(); c.restoreGState()
    }

    static func symbols() -> [String: (CGImage, CGPoint)] {
        var out: [String: (CGImage, CGPoint)] = [:]
        let tip = CGPoint(x: 8, y: 6)
        var g = symCtx(); strokeFill(g, [.poly(arrowPts(tip))]); out["01_正常"] = (down(g), tip)

        g = symCtx()
        strokeFill(g, [.rrect(box(32, 26, 40, 126), 3), .rrect(box(18, 20, 54, 30), 4), .rrect(box(18, 122, 54, 132), 4)])
        out["02_文字输入"] = (down(g), CGPoint(x: 36, y: 76))

        g = symCtx(); let lc = linkC; tilt(g, lc)
        strokeFill(g, paw(lc, linkK, point: true)); pinkPads(g, lc, linkK, point: true)
        out["03_链接"] = (down(g), turn(CGPoint(x: lc.x - 22 * linkK, y: lc.y - 92 * linkK), lc))   // 「食指」的尖

        g = symCtx(); var c = CGPoint(x: 60, y: 62); let r: CGFloat = 46
        let red = rgb(225, 45, 40)
        for (rad, col) in [(r + ow, outline), (r, red), (r - 13, outline), (r - 13 - ow, white)] {
            g.setFillColor(col); g.fillEllipse(in: box(c.x - rad, c.y - rad, c.x + rad, c.y + rad))
        }
        let d = (r - 8) * cos(.pi / 4)
        g.setLineCap(.butt)
        for (lw, col) in [(13 + 2 * ow, outline), (13, red)] {
            g.setStrokeColor(col); g.setLineWidth(lw)
            g.strokeLineSegments(between: [CGPoint(x: c.x - d, y: c.y - d), CGPoint(x: c.x + d, y: c.y + d)])
        }
        out["04_不可用"] = (down(g), c)

        c = CGPoint(x: 60, y: 64)
        g = symCtx(); strokeFill(g, [.poly(doubleArrow(c, 0, 104)), .poly(doubleArrow(c, 90, 104))]); out["06_移动"] = (down(g), c)
        g = symCtx(); strokeFill(g, [.poly(doubleArrow(CGPoint(x: 66, y: 44), 0, 118))]); out["07_左右调整"] = (down(g), CGPoint(x: 66, y: 44))
        g = symCtx(); strokeFill(g, [.poly(doubleArrow(CGPoint(x: 40, y: 74), 90, 118))]); out["08_上下调整"] = (down(g), CGPoint(x: 40, y: 74))
        g = symCtx(); strokeFill(g, [.poly(doubleArrow(c, 45, 116))]); out["09_斜向调整_左上右下"] = (down(g), c)
        g = symCtx(); strokeFill(g, [.poly(doubleArrow(c, -45, 116))]); out["10_斜向调整_右上左下"] = (down(g), c)

        c = CGPoint(x: 54, y: 54)
        g = symCtx(); strokeFill(g, [.ellipse(box(c.x - 40, c.y - 40, c.x + 40, c.y + 40))])
        text(g, "?", font("ArialRoundedMTBold", 60), at: c, fill: outline, centered: true)
        out["11_帮助"] = (down(g), c)

        c = CGPoint(x: 60, y: 64); g = symCtx(); g.setLineCap(.butt)
        for (lw, col) in [(CGFloat(19), white), (CGFloat(6), outline)] {
            g.setStrokeColor(col); g.setLineWidth(lw)
            g.strokeEllipse(in: box(c.x - 34, c.y - 34, c.x + 34, c.y + 34))
            for (a, b) in [((0, -56), (0, -14)), ((0, 14), (0, 56)), ((-56, 0), (-14, 0)), ((14, 0), (56, 0))] {
                g.strokeLineSegments(between: [CGPoint(x: c.x + CGFloat(a.0), y: c.y + CGFloat(a.1)), CGPoint(x: c.x + CGFloat(b.0), y: c.y + CGFloat(b.1))])
            }
        }
        out["12_十字瞄准"] = (down(g), c)

        g = symCtx(); strokeFill(g, [.poly(arrowPts(tip))]); c = CGPoint(x: 84, y: 100)
        for (rad, col) in [(22 + ow, outline), (22, rgb(52, 168, 83))] {
            g.setFillColor(col); g.fillEllipse(in: box(c.x - rad, c.y - rad, c.x + rad, c.y + rad))
        }
        g.setFillColor(white)
        for b in [box(c.x - 13, c.y - 3.5, c.x + 13, c.y + 3.5), box(c.x - 3.5, c.y - 13, c.x + 3.5, c.y + 13)] {
            g.addPath(CGPath(roundedRect: b, cornerWidth: 2, cornerHeight: 2, transform: nil)); g.fillPath()
        }
        out["13_复制"] = (down(g), tip)

        c = openC
        g = symCtx(); tilt(g, c); strokeFill(g, paw(c, openK)); pinkPads(g, c, openK)
        out["14_张开爪"] = (down(g), turn(CGPoint(x: c.x, y: c.y + 8), c))
        c = fistC
        g = symCtx(); tilt(g, c, scale: fistK); strokeFill(g, fist(c))
        g.setStrokeColor(outline); g.setLineWidth(4); g.setLineCap(.round)
        for dx: CGFloat in [-18, 0, 18] {                        // 指缝
            g.strokeLineSegments(between: [CGPoint(x: c.x + dx, y: c.y - 16), CGPoint(x: c.x + dx, y: c.y + 2)])
        }
        let thumb = CGMutablePath()                              // 横在拳前的大拇指
        thumb.move(to: CGPoint(x: c.x - 34, y: c.y + 8))
        thumb.addQuadCurve(to: CGPoint(x: c.x + 10, y: c.y + 14), control: CGPoint(x: c.x - 14, y: c.y + 26))
        g.addPath(thumb); g.strokePath()
        out["15_抓紧爪"] = (down(g), c)

        c = CGPoint(x: 50, y: 50)
        g = symCtx()
        strokeFill(g, [.poly(doubleArrow(CGPoint(x: c.x + 46, y: c.y + 46), 45, 40, sw: 8, hw: 8, hl: 1)),
                       .ellipse(box(c.x - 36, c.y - 36, c.x + 36, c.y + 36))])
        g.setFillColor(outline)
        for b in [box(c.x - 20, c.y - 5, c.x + 20, c.y + 5), box(c.x - 5, c.y - 20, c.x + 5, c.y + 20)] {
            g.addPath(CGPath(roundedRect: b, cornerWidth: 3, cornerHeight: 3, transform: nil)); g.fillPath()
        }
        out["16_放大"] = (down(g), c)

        // 链接 / 张开爪 / 抓紧爪：App 里带了画好的爪子图（Resources/Pointers，256 画布、已摆在左上）就用图，没有就用上面画的
        for (n, file, hot) in [("03_链接", "03_link", CGPoint(x: 18.8, y: 39.8)),      // 最左上那个趾头
                               ("14_张开爪", "14_open", CGPoint(x: 54.2, y: 48.9)),
                               ("15_抓紧爪", "15_grab", CGPoint(x: 52.2, y: 47.8))] {
            if let u = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "Pointers"),
               let s = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) {
                out[n] = (img, hot)
            }
        }
        return out
    }

    /// 忙碌：分段加载圈，领头那段最亮，12 帧转一圈
    static func busyFrames(_ n: Int = 12, _ c: CGPoint = CGPoint(x: 74, y: 70), R: CGFloat = 54, W: CGFloat = 20) -> [CGImage] {
        (0..<n).map { f in
            let g = symCtx()
            let ro = R + W / 2, ri = R - W / 2
            g.setFillColor(outline); g.fillEllipse(in: box(c.x - ro - 2.5, c.y - ro - 2.5, c.x + ro + 2.5, c.y + ro + 2.5))
            for k in 0..<n {
                let t = CGFloat((f - k + n) % n) / CGFloat(n - 1)
                g.setFillColor(rgb(255, Int(160 * (1 - t) + 236 * t), Int(50 * (1 - t) + 210 * t)))
                let a0 = (-90 + CGFloat(k) * 360 / CGFloat(n) + 3) * .pi / 180
                let a1 = a0 + (360 / CGFloat(n) - 6) * .pi / 180
                let p = CGMutablePath(); p.move(to: c); p.addArc(center: c, radius: ro, startAngle: a0, endAngle: a1, clockwise: false)
                p.closeSubpath(); g.addPath(p); g.fillPath()
            }
            g.setFillColor(outline); g.fillEllipse(in: box(c.x - ri - 2.5, c.y - ri - 2.5, c.x + ri + 2.5, c.y + ri + 2.5))
            g.setBlendMode(.clear); g.fillEllipse(in: box(c.x - ri, c.y - ri, c.x + ri, c.y + ri)); g.setBlendMode(.normal)
            return down(g)
        }
    }

    // MARK: 3. 待机动画
    static func hop(_ p: CGFloat, _ hop: CGFloat = 14) -> (CGFloat, CGFloat, CGFloat) {
        if p < 0.3 { return (hop * (1 - pow(p / 0.3, 2)), 0.98, 1.03) }
        if p < 0.5 { let q = sin(.pi * (p - 0.3) / 0.2); return (0, 1 + 0.08 * q, 1 - 0.1 * q) }
        return (hop * (1 - pow((1 - p) / 0.5, 2)), 0.98, 1.03)
    }

    /// 3 个舞姿各跳一拍：最高点 → 落下 → 落地压扁 → 弹起；最高点换舞姿。脚底中点对齐「正常」姿势
    static func danceFrames(_ arrow: CGImage, _ poses: [CGImage], _ sc: CGFloat, perBeat: Int = 8, tilt: CGFloat = 5) -> [CGImage] {
        let nf = font("ArialUnicodeMS", 46)
        var out: [CGImage] = []
        for (b, pet) in poses.enumerated() {
            let rect = placeRect(pet, sc)
            let mid = rect.midX, top = rect.minY
            let sign: CGFloat = b % 2 == 0 ? 1 : -1
            for j in 0..<perBeat {
                let p = CGFloat(j) / CGFloat(perBeat)
                let (y, kx, ky) = hop(p)
                let g = ctx(256, 256)
                g.saveGState()
                g.translateBy(x: mid, y: footY - y)
                g.rotate(by: -sign * tilt * sin(.pi * p) * .pi / 180)
                g.scaleBy(x: kx, y: ky)
                g.translateBy(x: -mid, y: -footY)
                drawUp(g, pet, rect)
                g.restoreGState()
                drawUp(g, arrow, CGRect(x: 0, y: 0, width: 256, height: 256))
                for k in 0..<2 {                                 // 本拍和上一拍的音符同时在飘
                    let age = (p + CGFloat(k)) / 2
                    let side: CGFloat = (b - k) % 2 == 0 ? 1 : -1
                    let nx = mid + 50 + side * 10 + age * 8, ny = top - 40 - age * 30
                    if nx < 226 && ny > -10 {
                        text(g, (b - k) % 2 == 0 ? "♪" : "♫", nf, at: CGPoint(x: nx, y: ny), fill: textFill, stroke: 3,
                             alpha: pow(1 - age, 0.8))
                    }
                }
                out.append(g.makeImage()!)
            }
        }
        return out
    }

    static func sleepFrames(_ arrow: CGImage, _ pet: CGImage, _ sc: CGFloat, n: Int = 6) -> [CGImage] {
        let rect = placeRect(pet, sc)
        let head = CGPoint(x: rect.maxX - 60, y: rect.minY - 4)
        return (0..<n).map { f in
            let t = CGFloat(f) / CGFloat(n)
            let g = ctx(256, 256)
            g.saveGState()
            g.translateBy(x: 0, y: 256); g.scaleBy(x: 1, y: 1 + 0.025 * sin(2 * .pi * t)); g.translateBy(x: 0, y: -256)
            drawUp(g, pet, rect)
            g.restoreGState()
            drawUp(g, arrow, CGRect(x: 0, y: 0, width: 256, height: 256))
            for (k, (size, phase)) in [(CGFloat(34), CGFloat(0)), (42, 0.33), (50, 0.66)].enumerated() {
                let p = (t + phase).truncatingRemainder(dividingBy: 1)
                text(g, "z", font("ArialRoundedMTBold", size), at: CGPoint(x: head.x + CGFloat(k) * 8 + p * 16, y: head.y - 8 - p * 44),
                     fill: textFill, stroke: 3, alpha: pow(1 - p, 0.7))
            }
            return g.makeImage()!
        }
    }

    // MARK: 4. 写成皮肤文件
    // Mac 系统指针标识 → 哪张图（标识取自 MaCursor 源码 MACCursorDefinitions.swift）
    static let macMap: [String: String] = {
        var m: [String: String] = [
            "com.apple.coregraphics.Arrow": "01_正常", "com.apple.coregraphics.ArrowS": "01_正常", "com.apple.coregraphics.ArrowCtx": "01_正常",
            "com.apple.coregraphics.IBeam": "02_文字输入", "com.apple.coregraphics.IBeamS": "02_文字输入", "com.apple.cursor.26": "02_文字输入",
            "com.apple.cursor.13": "03_链接", "com.apple.cursor.3": "04_不可用",
            "com.apple.coregraphics.Wait": "05_忙碌", "com.apple.cursor.4": "05_忙碌", "com.apple.coregraphics.Move": "06_移动",
            "com.apple.cursor.40": "11_帮助", "com.apple.cursor.7": "12_十字瞄准", "com.apple.cursor.8": "12_十字瞄准",
            "com.apple.coregraphics.Copy": "13_复制", "com.apple.cursor.5": "13_复制",
            "com.apple.cursor.12": "14_张开爪", "com.apple.cursor.11": "15_抓紧爪", "com.apple.cursor.42": "16_放大"]
        for i in [17, 18, 19, 27, 28, 38] { m["com.apple.cursor.\(i)"] = "07_左右调整" }
        for i in [21, 22, 23, 31, 32, 36] { m["com.apple.cursor.\(i)"] = "08_上下调整" }
        for i in [33, 34, 35] { m["com.apple.cursor.\(i)"] = "09_斜向调整_左上右下" }
        for i in [29, 30, 37] { m["com.apple.cursor.\(i)"] = "10_斜向调整_右上左下" }
        return m
    }()

    /// 同一尺寸的各帧竖着拼成一张
    static func sheet(_ frames: [CGImage], _ s: Int) -> Data {
        let g = ctx(s, s * frames.count)
        for (i, f) in frames.enumerated() { drawUp(g, f, CGRect(x: 0, y: i * s, width: s, height: s)) }
        return png(g.makeImage()!)
    }

    static func entry(_ frames: [CGImage], _ hot: CGPoint, _ dur: Double) -> [String: Any] {
        let k = CGFloat(points) / 256
        return ["FrameCount": frames.count, "FrameDuration": frames.count > 1 ? dur : 0.0,
                "HotSpotX": Double(hot.x * k), "HotSpotY": Double(hot.y * k),
                "PointsWide": Double(points), "PointsHigh": Double(points),
                "Representations": [1, 2, 4].map { sheet(frames, points * $0) }]
    }

    struct Result {
        var sprites: [String: [CGImage]] = [:]     // 指针名 / 跳舞 / 睡觉 → 256 画布帧
        var hot: [String: CGPoint] = [:]
        var pet: CGImage?
    }

    static func render(sheet path: URL) throws -> Result {
        guard let src = CGImageSourceCreateWithURL(path as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure(msg: "图片打不开：\(path.lastPathComponent)") }
        let pets = try split(removeBg(img))
        let hs = pets.prefix(16).map { CGFloat($0.height) }.sorted()
        let sc = petH / ((hs[7] + hs[8]) / 2)                   // 16 个姿势高度的中位数缩放到 petH
        let syms = symbols()
        var r = Result()
        for (i, n) in names.enumerated() {
            let rect = placeRect(pets[i], sc)
            func compose(_ sym: CGImage) -> CGImage {
                let g = ctx(256, 256)
                drawUp(g, pets[i], rect); drawUp(g, sym, CGRect(x: 0, y: 0, width: 256, height: 256))
                return g.makeImage()!
            }
            if n == "05_忙碌" {
                r.sprites[n] = busyFrames().map(compose); r.hot[n] = CGPoint(x: 74, y: 70)
            } else {
                let (sym, hot) = syms[n]!
                r.sprites[n] = [compose(sym)]; r.hot[n] = hot
            }
        }
        let g = ctx(256, 256); drawUp(g, pets[0], placeRect(pets[0], sc)); r.pet = g.makeImage()
        let arrow = syms["01_正常"]!.0
        r.sprites["跳舞"] = danceFrames(arrow, Array(pets[16...18]), sc)
        r.sprites["睡觉"] = sleepFrames(arrow, pets[19], sc)
        return r
    }

    /// 写出皮肤文件夹 <dir>/<name>/
    static func write(_ r: Result, name: String, to dir: URL) throws -> URL {
        let skin = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skin, withIntermediateDirectories: true)
        var cursors: [String: Any] = [:]
        for (ident, stem) in macMap { cursors[ident] = entry(r.sprites[stem]!, r.hot[stem]!, 0.08) }
        let theme = try PropertyListSerialization.data(fromPropertyList: ["ThemeName": name, "Cursors": cursors], format: .binary, options: 0)
        try theme.write(to: skin.appendingPathComponent("theme.cursor"))
        let hot = r.hot["01_正常"]!
        let idle = try PropertyListSerialization.data(fromPropertyList: [
            "dance": entry(r.sprites["跳舞"]!, hot, 0.06), "sleep": entry(r.sprites["睡觉"]!, hot, 0.25)], format: .binary, options: 0)
        try idle.write(to: skin.appendingPathComponent("idle.plist"))
        if let pet = r.pet {                                  // 菜单栏图标：宠物本身，裁边、补成正方形、36px
            let b = read(pet)
            var x0 = b.w, y0 = b.h, x1 = 0, y1 = 0
            for y in 0..<b.h { for x in 0..<b.w where b.p[(y * b.w + x) * 4 + 3] > 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
            let crop = pet.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))!
            let s = CGFloat(max(crop.width, crop.height)), k = 36 / s
            let g = ctx(36, 36)
            drawUp(g, crop, CGRect(x: (36 - CGFloat(crop.width) * k) / 2, y: (36 - CGFloat(crop.height) * k) / 2,
                                   width: CGFloat(crop.width) * k, height: CGFloat(crop.height) * k))
            try png(g.makeImage()!).write(to: skin.appendingPathComponent("MenuIcon.png"))
        }
        return skin
    }

    /// 调试用：把所有切图存成 PNG（文件名同旧版 Python 工具，便于对比）
    static func dump(_ r: Result, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (key, frames) in r.sprites {
            if frames.count == 1 { try png(frames[0]).write(to: dir.appendingPathComponent("\(key).png")); continue }
            for (i, f) in frames.enumerated() { try png(f).write(to: dir.appendingPathComponent(String(format: "%@_f%02d.png", key, i))) }
            if key == "05_忙碌" { try png(frames[0]).write(to: dir.appendingPathComponent("\(key).png")) }
        }
        let hs = r.hot.mapValues { [Int($0.x), Int($0.y)] }
        try JSONSerialization.data(withJSONObject: hs).write(to: dir.appendingPathComponent("hotspots.json"))
    }

    // MARK: 出图提示词（菜单「复制出图提示词」）
    static let prompt = """
    A character sprite sheet of ONE cute chibi [在这里写你的宠物：品种、毛色、特征，如 grey-and-white British Shorthair cat with round face and yellow eyes, matching the attached photo], drawn 20 times in a strict grid of 4 columns x 5 rows. Every cell shows the exact same character (same markings, same proportions, same colors) in a different pose. Style: kawaii sticker, big head, big shiny eyes, small body, thick dark brown outline (#3A2014) around the whole figure, flat colors, soft pink blush, no gradients, no shadows, no ground. Background: one flat solid pure green #00FF00 everywhere (if the pet has any green on it, use pure magenta #FF00FF instead), no texture, no grid lines, no borders. Each figure is centered in its cell, fully inside it, with wide empty space between figures; figures never touch or overlap. No text, no letters, no numbers, no arrows, no symbols, no props.
    Anatomy: in every cell the pet has exactly TWO front legs and TWO hind legs, never an extra paw, arm or leg.
    Rows 1-4 (16 poses): the pet sits facing forward with both front paws resting on the ground in front of her; she never raises a paw in these 16; vary only the face and head mood:
    1 happy smile, 2 calm focused, 3 excited sparkling eyes, 4 pouty grumpy, 5 waiting with a sweat drop, 6 determined, 7 leaning to one side, 8 sitting up tall, 9 head tilted left, 10 head tilted right, 11 confused, 12 one eye closed aiming, 13 winking, 14 cheerful open mouth, 15 tense gritting teeth, 16 curious wide eyes.
    Row 5: 17 dancing with both front paws up, 18 dancing waving one paw, 19 dancing with eyes closed and arms out, 20 curled up asleep with eyes closed.
    """
}
