import Foundation

/// Per-pixel texture modifiers shared by the 16 px node-atlas path and the
/// native-resolution model/HUD path. Formulas follow imagesource.cpp; our
/// buffers are premultiplied RGBA, so colour-space ops un-premultiply first.
extension TextureAtlas {
    /// Apply one "[name:args" modifier that needs no second image. Returns
    /// false when `part` isn't one of ours so the caller can try the rest.
    static func applyPixelModifier(_ part: String, px: inout [UInt8], count: Int) -> Bool {
        let spec = part.replacingOccurrences(of: "]", with: "")
        if spec.hasPrefix("[multiply:") {
            guard let c = parseColorRGBA(String(spec.dropFirst("[multiply:".count))) else { return true }
            for i in 0..<count {   // premultiplied rgb scales the same as straight rgb
                let j = i * 4
                px[j]   = UInt8(Int(px[j])   * Int(c[0]) / 255)
                px[j+1] = UInt8(Int(px[j+1]) * Int(c[1]) / 255)
                px[j+2] = UInt8(Int(px[j+2]) * Int(c[2]) / 255)
            }
            return true
        }
        if spec.hasPrefix("[screen:") {
            guard let c = parseColorRGBA(String(spec.dropFirst("[screen:".count))) else { return true }
            mapStraight(&px, count: count) { r, g, b, a in
                (255 - (255 - r) * (255 - c[0]) / 255, 255 - (255 - g) * (255 - c[1]) / 255, 255 - (255 - b) * (255 - c[2]) / 255, a)
            }
            return true
        }
        if spec.hasPrefix("[brighten") {
            mapStraight(&px, count: count) { r, g, b, a in (127.5 + 0.5 * r, 127.5 + 0.5 * g, 127.5 + 0.5 * b, a) }
            return true
        }
        if spec.hasPrefix("[noalpha") {
            for i in 0..<count { px[i * 4 + 3] = 255 }
            return true
        }
        if spec.hasPrefix("[makealpha:") {
            let f = spec.dropFirst("[makealpha:".count).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard f.count == 3 else { return true }
            mapStraight(&px, count: count) { r, g, b, a in
                (Int(r.rounded()) == f[0] && Int(g.rounded()) == f[1] && Int(b.rounded()) == f[2]) ? (r, g, b, 0) : (r, g, b, a)
            }
            return true
        }
        if spec.hasPrefix("[opacity:") {
            let ratio = max(0, min(255, Int(spec.dropFirst("[opacity:".count)) ?? 255))
            for i in 0..<count {   // alpha' = floor(a*ratio/255 + 0.5); premultiplied rgb scales with it
                let j = i * 4
                for c in 0..<4 { px[j+c] = UInt8((Int(px[j+c]) * ratio * 2 + 255) / 510) }
            }
            return true
        }
        if spec.hasPrefix("[invert:") {
            let mode = spec.dropFirst("[invert:".count).lowercased()
            let ir = mode.contains("r"), ig = mode.contains("g"), ib = mode.contains("b"), ia = mode.contains("a")
            mapStraight(&px, count: count) { r, g, b, a in
                (ir ? 255 - r : r, ig ? 255 - g : g, ib ? 255 - b : b, ia ? 255 - a : a)
            }
            return true
        }
        if spec.hasPrefix("[hsl:") || spec.hasPrefix("[colorizehsl:") {
            let colorize = spec.hasPrefix("[colorizehsl:")
            let f = spec.split(separator: ":", omittingEmptySubsequences: false).dropFirst().map { Float($0) ?? 0 }
            let hue = f.count > 0 ? f[0] : 0
            let sat = f.count > 1 ? f[1] : (colorize ? 50 : 0)
            let light = f.count > 2 ? f[2] : 0
            hueSaturation(&px, count: count, hue: hue, saturation: sat, lightness: light, colorize: colorize)
            return true
        }
        return false
    }

    /// Run `f` on straight (un-premultiplied) 0..255 channels, then re-premultiply.
    static func mapStraight(_ px: inout [UInt8], count: Int,
                            _ f: (Float, Float, Float, Float) -> (Float, Float, Float, Float)) {
        for i in 0..<count {
            let j = i * 4
            let a = Float(px[j+3])
            let inv: Float = a > 0 ? 255 / a : 0
            let (r, g, b, na) = f(Float(px[j]) * inv, Float(px[j+1]) * inv, Float(px[j+2]) * inv, a)
            let ca = max(0, min(255, na)), k = ca / 255
            px[j]   = UInt8(max(0, min(255, r)) * k)
            px[j+1] = UInt8(max(0, min(255, g)) * k)
            px[j+2] = UInt8(max(0, min(255, b)) * k)
            px[j+3] = UInt8(ca)
        }
    }

    /// apply_hue_saturation: GIMP-style Hue-Saturation (0 = unchanged), or
    /// with `colorize` a grey image seen through coloured glass.
    static func hueSaturation(_ px: inout [UInt8], count: Int, hue: Float, saturation: Float, lightness: Float, colorize: Bool) {
        let normS = max(-100, min(1000, saturation)) / 100
        let normL = max(-100, min(100, lightness)) / 100
        mapStraight(&px, count: count) { r, g, b, a in
            var h: Float, s: Float, l: Float
            if colorize {
                var lum = (r * 0.299 + g * 0.587 + b * 0.114) / 255   // SColor::getBrightness
                lum = normL < 0 ? lum * (normL + 1) : lum * (1 - normL) + normL
                h = 0; s = max(0, min(100, saturation)); l = lum * 100
            } else {
                (h, s, l) = rgbToHSL(r, g, b)
                l = normL < 0 ? l * (normL + 1) : l + normL * (100 - l)
                s = max(0, min(100, s * (normS + 1)))
            }
            h = (h + hue).truncatingRemainder(dividingBy: 360)
            if h < 0 { h += 360 }
            let (nr, ng, nb) = hslToRGB(h, s, l)
            return (nr, ng, nb, a)
        }
    }

    /// Irrlicht SColorHSL conventions: hue 0..360, saturation and luminance 0..100.
    static func rgbToHSL(_ r8: Float, _ g8: Float, _ b8: Float) -> (Float, Float, Float) {
        let r = r8 / 255, g = g8 / 255, b = b8 / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, 0, l * 100) }
        let d = mx - mn
        let s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
        var h: Float
        if mx == r { h = (g - b) / d }
        else if mx == g { h = 2 + (b - r) / d }
        else { h = 4 + (r - g) / d }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s * 100, l * 100)
    }

    static func hslToRGB(_ h: Float, _ s100: Float, _ l100: Float) -> (Float, Float, Float) {
        let s = s100 / 100, l = l100 / 100
        if s == 0 { return (l * 255, l * 255, l * 255) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func chan(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hk = h / 360
        return (chan(hk + 1 / 3) * 255, chan(hk) * 255, chan(hk - 1 / 3) * 255)
    }

    /// [mask:file, imageApplyMask: bitwise AND of the two images' straight
    /// bytes. `sample` maps a base pixel index to the mask's premultiplied
    /// RGBA (so a differently sized mask can be stretched by the caller).
    static func applyMask(_ px: inout [UInt8], count: Int, mask: (Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        for i in 0..<count {
            let j = i * 4
            let (mr, mg, mb, ma) = mask(i)
            let minv: Float = ma > 0 ? 255 / Float(ma) : 0
            let a = Float(px[j+3]), inv: Float = a > 0 ? 255 / a : 0
            let na = px[j+3] & ma
            let k = Float(na) / 255
            func andC(_ v: UInt8, _ m: UInt8) -> UInt8 {
                let sv = UInt8(max(0, min(255, Float(v) * inv))), sm = UInt8(max(0, min(255, Float(m) * minv)))
                return UInt8(Float(sv & sm) * k)
            }
            px[j] = andC(px[j], mr); px[j+1] = andC(px[j+1], mg); px[j+2] = andC(px[j+2], mb); px[j+3] = na
        }
    }

    /// "[sheet:WxH:X,Y" -> (tiles across, tiles down, tile x, tile y).
    static func parseSheet(_ part: String) -> (w: Int, h: Int, x: Int, y: Int)? {
        let f = part.replacingOccurrences(of: "]", with: "").dropFirst("[sheet:".count).split(separator: ":")
        guard f.count == 2 else { return nil }
        let wh = f[0].split(separator: "x").compactMap { Int($0) }, xy = f[1].split(separator: ",").compactMap { Int($0) }
        guard wh.count == 2, xy.count == 2, wh[0] > 0, wh[1] > 0, xy[0] < wh[0], xy[1] < wh[1] else { return nil }
        return (wh[0], wh[1], xy[0], xy[1])
    }
}
