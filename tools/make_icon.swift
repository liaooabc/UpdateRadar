import AppKit
import CoreGraphics

// 生成图标：超椭圆底 + 青绿圆润箭头，接近 macOS 26 原生图标的观感。
// 用法：make_icon <bleed|art> <out.png> [size] [light|dark]
//   bleed: 铺满整张画布（给 .icon 用，系统自己套圆角）
//   art:   带留白的成品图（给 .icns 兜底用）
//   最后一个参数是外观：light = 白天（浅底深箭头）、dark = 暗夜（深底亮箭头）

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: make_icon <bleed|art> <out.png> [size]\n".data(using: .utf8)!)
    exit(2)
}
let mode = args[1]
let outPath = args[2]
let size: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024
let bleed = (mode == "bleed")
let isDark = (args.count > 4 ? args[4] : "light") == "dark"

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

let inset = bleed ? 0 : size * (100.0 / 1024.0)
let box = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

/// 超椭圆（squircle），n≈5 接近 Apple 的连续曲率圆角
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let shape = bleed ? CGPath(rect: box, transform: nil) : squircle(box)

// MARK: 底：近黑，顶部略亮，像原生深色图标
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// 白天：浅色玻璃底；暗夜：近黑底（原来那版）
let top = isDark ? rgb(0.165, 0.180, 0.200) : rgb(0.988, 0.992, 1.0)
let bottom = isDark ? rgb(0.055, 0.060, 0.070) : rgb(0.855, 0.882, 0.918)
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: box.midX, y: box.maxY),
                       end: CGPoint(x: box.midX, y: box.minY), options: [])

// 顶部柔光
let hi = CGGradient(colorsSpace: cs,
                    colors: [rgb(1, 1, 1, isDark ? 0.10 : 0.85), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(hi,
                       startCenter: CGPoint(x: box.midX, y: box.maxY - box.height * 0.02),
                       startRadius: 0,
                       endCenter: CGPoint(x: box.midX, y: box.maxY - box.height * 0.02),
                       endRadius: box.width * 0.75,
                       options: [.drawsAfterEndLocation])
ctx.restoreGState()

// MARK: 字形：青绿圆润箭头 + 底部横线
// 暗夜用亮青绿；白天用压深的青绿，浅底上才够对比
let accent = isDark ? rgb(0.235, 0.855, 0.720) : rgb(0.045, 0.545, 0.415)
let cx = box.midX
let cy = box.midY
let w = box.width

// 先画一层柔和辉光，模拟原生图标的发光
ctx.saveGState()
if isDark {
    ctx.setShadow(offset: .zero, blur: w * 0.035, color: accent.copy(alpha: 0.55))
} else {
    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.010), blur: w * 0.030,
                  color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.22])!)
}
ctx.setFillColor(accent)
ctx.setStrokeColor(accent)
drawGlyph(ctx: ctx, cx: cx, cy: cy, w: w)
ctx.restoreGState()

// 主体
ctx.setFillColor(accent)
ctx.setStrokeColor(accent)
drawGlyph(ctx: ctx, cx: cx, cy: cy, w: w)

// 内描边，暗色下勾出圆角边缘
if !bleed {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(isDark ? rgb(1, 1, 1, 0.10) : rgb(0, 0, 0, 0.07))
    ctx.setLineWidth(size * 0.005)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawGlyph(ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat) {
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    // 箭杆：全圆头
    let shaftW = w * 0.125
    let shaftTop = cy + w * 0.340
    let shaftBottom = cy + w * 0.040
    let shaft = CGRect(x: cx - shaftW / 2, y: shaftBottom, width: shaftW, height: shaftTop - shaftBottom)
    ctx.addPath(CGPath(roundedRect: shaft, cornerWidth: shaftW / 2, cornerHeight: shaftW / 2, transform: nil))
    ctx.fillPath()

    // 箭头：三角 + 同色粗描边，把三个角都磨圆
    let headHalf = w * 0.150
    let headY = shaftBottom + w * 0.040
    let tipY = cy - w * 0.190
    let head = CGMutablePath()
    head.move(to: CGPoint(x: cx - headHalf, y: headY))
    head.addLine(to: CGPoint(x: cx + headHalf, y: headY))
    head.addLine(to: CGPoint(x: cx, y: tipY))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.fillPath()
    ctx.setLineWidth(w * 0.064)
    ctx.addPath(head)
    ctx.strokePath()

    // 底部横线
    let barW = w * 0.360
    let barH = w * 0.070
    let bar = CGRect(x: cx - barW / 2, y: cy - w * 0.345, width: barW, height: barH)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    ctx.fillPath()
}

guard let cg = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cg)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
