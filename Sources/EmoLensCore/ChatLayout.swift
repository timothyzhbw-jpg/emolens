import CoreGraphics
import Foundation

/// 聊天区域截图的像素，RGBA，原点在左上。先缩小到大约每个点一个像素，分析起来快。
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public init?(_ image: CGImage, maxWidth: Int = 480) {
        let scale = min(1, Double(maxWidth) / Double(max(1, image.width)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, rgba: data)
    }

    @inline(__always) func color(_ index: Int) -> RGB {
        RGB(Int(rgba[index * 4]), Int(rgba[index * 4 + 1]), Int(rgba[index * 4 + 2]))
    }
}

struct RGB: Equatable {
    var r, g, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }

    func distance(_ other: RGB) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
    /// 4 位量化后的颜色编号，用来统计主色。
    var bin: Int { (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4) }
    var saturation: Double {
        let high = max(r, g, b), low = min(r, g, b)
        return high == 0 ? 0 : Double(high - low) / Double(high)
    }
    var value: Double { Double(max(r, g, b)) / 255 }
    /// 色相，0–360。
    var hue: Double {
        let high = max(r, g, b), low = min(r, g, b)
        guard high > low else { return 0 }
        let d = Double(high - low)
        let h: Double = high == r ? Double(g - b) / d : high == g ? 2 + Double(b - r) / d : 4 + Double(r - g) / d
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// 截图里的一块东西：文字气泡、表情包或图片、头像。坐标都是归一化的（原点左上）。
public struct LayoutBlock: Equatable, Sendable {
    public enum Kind: String, Sendable { case bubble, media, avatar }

    public var kind: Kind
    public var box: CGRect
    /// 气泡里 OCR 读不出来的彩色小图（表情）。一个框里可能挨着好几个，count 是估计的个数。
    public var emoji: [Emoji] = []
    /// 气泡的底色（0–1），重新识别时用它把表情涂掉。
    public var fill: [Double]?
    /// 气泡里有像是文字、但 OCR 没读到的笔画。
    public var uncoveredText = false

    public struct Emoji: Codable, Equatable, Sendable {
        public var box: CGRect
        public var count: Int
        public init(box: CGRect, count: Int = 1) { self.box = box; self.count = count }
    }

    public init(kind: Kind, box: CGRect, emoji: [Emoji] = []) {
        self.kind = kind
        self.box = box
        self.emoji = emoji
    }
}

/// 不靠文字、只看像素，把聊天区域切成一块块：背景色是最多的那种颜色，和它不一样的连通区域就是一块。
/// 气泡是一大片纯色，表情包和图片颜色杂，头像是和气泡顶端对齐的小方块。
public enum LayoutDetector {
    /// textBoxes 是 OCR 行的框（归一化），用来估计字号，并且排除文字本身。
    public static func detect(_ image: PixelBuffer, textBoxes: [CGRect]) -> [LayoutBlock] {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return [] }
        let heights = textBoxes.map { Double($0.height) * Double(h) }.sorted()
        // 一个字的高度（像素）。文字大小决定了气泡、表情、头像大概多大。
        let unit = max(6, heights.isEmpty ? Double(w) / 24 : heights[heights.count / 2])

        let background = dominantColor(image)
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where image.color(i).distance(background) > 3 { mask[i] = true }
        let components = connectedComponents(mask, width: w, height: h)

        // 太小的是气泡外面的字（时间、昵称）或者小圆点，交给 OCR。
        let minSide = Int(unit * 1.5)
        var blocks: [Candidate] = components.filter { $0.box.width >= minSide && $0.box.height >= minSide }.map { component in
            let (fill, share) = dominant(of: component, in: image)
            // 气泡是几乎填满外框的圆角矩形；同样是一片纯色的圆形卡通脸，是表情包
            let flat = share >= 0.45 && component.density >= 0.9
            return Candidate(kind: flat ? .bubble : .media, box: component.box, fill: flat ? fill : nil)
        }
        markAvatars(&blocks, width: w, unit: unit)

        // 透明底的表情包会碎成几块（连同上面的字），把挨得很近的碎块并进来。头像和别的气泡不并。
        let reach = Int(unit * 0.5)
        let smallPieces = components.filter { $0.box.width < minSide || $0.box.height < minSide }.map(\.box)
        for i in blocks.indices where blocks[i].kind == .media {
            var grew = true
            while grew {
                grew = false
                for piece in smallPieces where !blocks[i].box.contains(piece) && blocks[i].box.near(piece, within: reach) {
                    blocks[i].box = blocks[i].box.union(piece)
                    grew = true
                }
                for j in blocks.indices where j != i && blocks[j].kind == .media && !blocks[j].merged
                    && blocks[i].box.near(blocks[j].box, within: reach) {
                    blocks[i].box = blocks[i].box.union(blocks[j].box)
                    blocks[j].merged = true
                    grew = true
                }
            }
        }
        blocks.removeAll { $0.merged }
        let mediaBoxes = blocks.filter { $0.kind == .media }.map(\.box)
        blocks.removeAll { block in
            block.kind != .media && mediaBoxes.contains { $0 != block.box && $0.contains(block.box) }
        }
        blocks.sort { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }

        let texts = textBoxes.map { PixelRect(normalized: $0, width: w, height: h).inset(by: -Int(unit * 0.15)) }
        return blocks.map { block in
            var result = LayoutBlock(kind: block.kind, box: block.box.normalized(width: w, height: h))
            if block.kind == .bubble, let fill = block.fill {
                let found = drawings(in: block.box, fill: fill, image: image,
                                     texts: texts.filter { $0.near(block.box, within: 0) }, unit: unit)
                if found.picture {
                    result.kind = .media   // 白底的表情包：一大块图画，不是文字
                } else {
                    result.emoji = found.emoji.map {
                        LayoutBlock.Emoji(box: $0.box.normalized(width: w, height: h), count: $0.count)
                    }
                    result.fill = [Double(fill.r) / 255, Double(fill.g) / 255, Double(fill.b) / 255]
                    result.uncoveredText = found.uncoveredText
                }
            }
            return result
        }
    }

    struct Candidate {
        var kind: LayoutBlock.Kind
        var box: PixelRect
        var fill: RGB?
        var merged = false
    }

    /// 头像：方的、不大，旁边紧挨着一个顶端对齐（或低一行昵称）的气泡或图片。
    /// 头像旁边是只有一个表情的小气泡时，两个都是小方块，靠外的那个才是头像。
    static func markAvatars(_ blocks: inout [Candidate], width: Int, unit: Double) {
        func squareish(_ box: PixelRect) -> Bool {
            let aspect = Double(box.width) / Double(box.height)
            return (0.75...1.33).contains(aspect) && Double(box.width) >= unit * 1.6 && Double(box.width) <= unit * 5
        }
        // 群聊里气泡上面有一行昵称，气泡顶端比头像低一行字左右
        func besideEachOther(_ a: PixelRect, _ b: PixelRect) -> Bool {
            let drop = b.minY - a.minY
            guard drop >= -Int(unit * 0.8), drop <= Int(unit * 2.2) else { return false }
            let gap = b.minX >= a.maxX ? b.minX - a.maxX : a.minX - b.maxX
            return gap >= 0 && gap <= Int(unit * 2.5)
        }
        let outer = { (box: PixelRect) in min(box.minX, width - box.maxX) }
        for i in blocks.indices where squareish(blocks[i].box) {
            let neighbors = blocks.indices.filter { $0 != i && besideEachOther(blocks[i].box, blocks[$0].box) }
            guard !neighbors.isEmpty else { continue }
            // 旁边还有个更靠外的小方块，那个才是头像
            let outermost = !neighbors.contains { squareish(blocks[$0].box) && outer(blocks[$0].box) < outer(blocks[i].box) }
            if outermost { blocks[i].kind = .avatar }
        }
    }

    // MARK: - 气泡里的图

    /// 找气泡里 OCR 没读到的东西：彩色小图是表情；除去文字后还有很大的一块图画，说明这其实是白底的表情包。
    /// 表情只按颜色认：OCR 给文字画的框常常把旁边的表情也框进去，不能按框排除。
    static func drawings(in box: PixelRect, fill: RGB, image: PixelBuffer, texts: [PixelRect], unit: Double)
        -> (emoji: [(box: PixelRect, count: Int)], picture: Bool, uncoveredText: Bool) {
        let inner = box.inset(by: 2)
        guard inner.width > 2, inner.height > 2 else { return ([], false, false) }
        let fillSaturated = fill.saturation > 0.25
        var ink = [Bool](repeating: false, count: inner.width * inner.height)
        var colorful = [Bool](repeating: false, count: inner.width * inner.height)
        for y in inner.minY..<inner.maxY {
            for x in inner.minX..<inner.maxX {
                let color = image.color(y * image.width + x)
                guard color.distance(fill) > 40 else { continue }
                let local = (y - inner.minY) * inner.width + (x - inner.minX)
                // 彩色：饱和、不太暗；绿色气泡上的黑字抗锯齿后仍是绿色色相，不算。
                if color.saturation >= 0.35, color.value >= 0.3 {
                    let d = abs(color.hue - fill.hue)
                    if !fillSaturated || min(d, 360 - d) >= 30 { colorful[local] = true }
                }
                if !texts.contains(where: { $0.contains(x: x, y: y) }) { ink[local] = true }
            }
        }
        let offset = { (r: PixelRect) in
            PixelRect(minX: r.minX + inner.minX, minY: r.minY + inner.minY, maxX: r.maxX + inner.minX, maxY: r.maxY + inner.minY)
        }
        // 不在任何 OCR 框里的笔画：很大一块是图画；字那么大的，是 OCR 漏读的字
        let strokes = connectedComponents(ink.indices.map { ink[$0] && !colorful[$0] }, width: inner.width, height: inner.height, bridge: 1)
        let picture = connectedComponents(ink, width: inner.width, height: inner.height, bridge: 1).contains {
            Double($0.box.width) > unit * 3.5 && Double($0.box.height) > unit * 3.5
        }
        guard !picture else { return ([], true, false) }
        // 有一个字那么大的笔画没被任何 OCR 框盖住（字和字之间有空隙，连不成一整行，按单个字算）
        let uncoveredText = strokes.contains {
            Double(min($0.box.width, $0.box.height)) >= unit * 0.4 && Double(max($0.box.width, $0.box.height)) >= unit * 0.6
        }

        var emoji: [(box: PixelRect, count: Int)] = []
        for piece in connectedComponents(colorful, width: inner.width, height: inner.height, bridge: 2) {
            let pieceBox = offset(piece.box)
            guard Double(min(pieceBox.width, pieceBox.height)) >= unit * 0.55, Double(pieceBox.height) <= unit * 3,
                  piece.density >= 0.25 else { continue }
            // 链接是蓝色的字，不是表情
            let blue = piece.pixels.filter { index in
                let hue = image.color((index / inner.width + inner.minY) * image.width + index % inner.width + inner.minX).hue
                return (190...260).contains(hue)
            }.count
            guard Double(blue) < Double(piece.pixels.count) * 0.6 else { continue }
            let count = max(1, Int((Double(pieceBox.width) / Double(pieceBox.height)).rounded()))
            emoji.append((pieceBox, count))
        }
        emoji.sort { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
        return (emoji, false, uncoveredText)
    }

    // MARK: - 基础

    /// 背景色：出现最多的精确颜色。先按量化后的颜色找出最多的一类，再在这一类里找最多的那个具体颜色——
    /// 新版微信的转文字框、引用框和白色背景只差几个色阶，平均一下就分不开了。
    static func dominantColor(_ image: PixelBuffer) -> RGB {
        var counts = [Int](repeating: 0, count: 4096)
        let total = image.width * image.height
        var i = 0
        while i < total {
            counts[image.color(i).bin] += 1
            i += 3
        }
        let best = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        var exact: [Int: Int] = [:]
        i = 0
        while i < total {
            let color = image.color(i)
            if color.bin == best { exact[color.r << 16 | color.g << 8 | color.b, default: 0] += 1 }
            i += 3
        }
        let key = exact.max { $0.value < $1.value }?.key ?? 0
        return RGB(key >> 16 & 255, key >> 8 & 255, key & 255)
    }

    /// 区域里最多的颜色和它所占的比例。
    static func dominant(of component: Component, in image: PixelBuffer) -> (RGB, Double) {
        var counts: [Int: Int] = [:]
        var sums: [Int: (Int, Int, Int)] = [:]
        let step = max(1, component.pixels.count / 4000)
        var sampled = 0
        var k = 0
        while k < component.pixels.count {
            let color = image.color(component.pixels[k])
            counts[color.bin, default: 0] += 1
            let s = sums[color.bin] ?? (0, 0, 0)
            sums[color.bin] = (s.0 + color.r, s.1 + color.g, s.2 + color.b)
            sampled += 1
            k += step
        }
        guard let (bin, count) = counts.max(by: { $0.value < $1.value }), let s = sums[bin] else { return (RGB(0, 0, 0), 0) }
        return (RGB(s.0 / count, s.1 / count, s.2 / count), Double(count) / Double(max(1, sampled)))
    }

    struct Component {
        var box: PixelRect
        var pixels: [Int]
        var density: Double { Double(pixels.count) / Double(max(1, box.width * box.height)) }
    }

    /// 4 连通区域。bridge > 0 时，相隔不超过 bridge 个像素的也算连在一起（把一个表情的几笔连起来）。
    static func connectedComponents(_ mask: [Bool], width: Int, height: Int, bridge: Int = 0) -> [Component] {
        var offsets: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        if bridge > 0 {
            let reach = bridge + 1
            offsets = (-reach...reach).flatMap { dy in (-reach...reach).map { dx in (dx, dy) } }.filter { $0 != (0, 0) }
        }
        var labeled = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !labeled[start] {
            var pixels: [Int] = []
            var minX = width, minY = height, maxX = 0, maxY = 0
            labeled[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                pixels.append(index)
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in offsets {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if mask[next] && !labeled[next] {
                        labeled[next] = true
                        stack.append(next)
                    }
                }
            }
            result.append(Component(box: PixelRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1), pixels: pixels))
        }
        return result
    }
}

/// 像素坐标的矩形，max 不包含在内。
struct PixelRect: Equatable {
    var minX, minY, maxX, maxY: Int
    var width: Int { maxX - minX }
    var height: Int { maxY - minY }

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    init(normalized r: CGRect, width: Int, height: Int) {
        self.init(minX: Int((r.minX * CGFloat(width)).rounded(.down)), minY: Int((r.minY * CGFloat(height)).rounded(.down)),
                  maxX: Int((r.maxX * CGFloat(width)).rounded(.up)), maxY: Int((r.maxY * CGFloat(height)).rounded(.up)))
    }

    func normalized(width: Int, height: Int) -> CGRect {
        CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
               width: Double(self.width) / Double(width), height: Double(self.height) / Double(height))
    }

    func contains(x: Int, y: Int) -> Bool { x >= minX && x < maxX && y >= minY && y < maxY }
    func contains(_ other: PixelRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }
    func inset(by d: Int) -> PixelRect { PixelRect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d) }
    func union(_ o: PixelRect) -> PixelRect {
        PixelRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }
    /// 两个框的间距不超过 d（重叠也算）。
    func near(_ o: PixelRect, within d: Int) -> Bool {
        o.minX <= maxX + d && o.maxX >= minX - d && o.minY <= maxY + d && o.maxY >= minY - d
    }
}
