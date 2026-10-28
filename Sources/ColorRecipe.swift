import Foundation

enum HueBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var label: String { ["Rojo", "Naranja", "Amarillo", "Verde", "Aguamarina", "Azul", "Púrpura", "Magenta"][rawValue] }
    var center: Double {
        let centers:[Double]=[0,1.0/12,1.0/6,1.0/3,0.5,2.0/3,0.75,5.0/6]
        return centers[rawValue]
    }
}

struct HSLAdjustment: Codable, Equatable {
    var hue: Double = 0 // Fraction of a turn, ±45 degrees.
    var saturation: Double = 0
    var lightness: Double = 0
}

struct GradeWheel: Codable, Equatable {
    var hue: Double = 0 // Degrees.
    var amount: Double = 0
}

struct ColorRecipe: Codable, Equatable {
    var hsl = [HSLAdjustment](repeating: HSLAdjustment(), count: 8)
    var masterCurve: [Double] = [0,0.25,0.5,0.75,1]
    var redCurve: [Double] = [0,0.25,0.5,0.75,1]
    var greenCurve: [Double] = [0,0.25,0.5,0.75,1]
    var blueCurve: [Double] = [0,0.25,0.5,0.75,1]
    var shadows = GradeWheel()
    var midtones = GradeWheel()
    var highlights = GradeWheel()
    var balance: Double = 0
    var blending: Double = 0.5
    var dehaze: Double = 0
    var grain: Double = 0
    var grainSize: Double = 1

    var needsCube: Bool {
        let neutral = ColorRecipe()
        return hsl != neutral.hsl || masterCurve != neutral.masterCurve || redCurve != neutral.redCurve ||
            greenCurve != neutral.greenCurve || blueCurve != neutral.blueCurve ||
            shadows.amount > 0 || midtones.amount > 0 || highlights.amount > 0 || dehaze != 0
    }
    var isActive: Bool { needsCube || grain > 0 }

    func validated() throws -> ColorRecipe {
        func range(_ value: Double, _ limits: ClosedRange<Double>) -> Bool { value.isFinite && limits.contains(value) }
        guard hsl.count == 8, hsl.allSatisfy({ range($0.hue,-0.125...0.125) && range($0.saturation,-1...1) && range($0.lightness,-0.5...0.5) }),
              [masterCurve,redCurve,greenCurve,blueCurve].allSatisfy({ $0.count == 5 && $0.allSatisfy({ range($0,0...1) }) }),
              [shadows,midtones,highlights].allSatisfy({ range($0.hue,0...360) && range($0.amount,0...1) }),
              range(balance,-1...1), range(blending,0...1), range(dehaze,-0.5...0.5), range(grain,0...1), range(grainSize,0.5...4) else {
            throw CameraFailure.message("Receta de color fuera de rango o incompleta.")
        }
        return self
    }
}

/// Original bounded 33³ look table. Its controls mirror the AGC menu families;
/// it is not a copy of AGC's GLSL, calibration, or Bayer processing.
enum ColorRecipeLUT {
    static func make(_ recipe: ColorRecipe, dimension: Int = 33) throws -> CubeLUT {
        _ = try recipe.validated()
        guard (2...64).contains(dimension) else { throw CameraFailure.message("Resolución de tabla fuera de rango.") }
        var values = [Float](); values.reserveCapacity(dimension*dimension*dimension*4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = transform([Double(r),Double(g),Double(b)].map { $0 / Double(dimension-1) }, recipe: recipe)
            values.append(contentsOf: rgb.map(Float.init)); values.append(1)
        } } }
        return CubeLUT(title: "Ultimate CAM · Color", dimension: dimension,
            rgba: values.withUnsafeBufferPointer { Data(buffer:$0) }, domainMin:[0,0,0], domainMax:[1,1,1])
    }

    static func transform(_ input: [Double], recipe o: ColorRecipe) -> [Double] {
        var rgb = input.map { curve($0, points:o.masterCurve) }
        rgb = [curve(rgb[0],points:o.redCurve),curve(rgb[1],points:o.greenCurve),curve(rgb[2],points:o.blueCurve)]
        if o.hsl.contains(where: { $0 != HSLAdjustment() }) {
            var hsl = toHSL(rgb)
            let originalHue = hsl[0], chroma = min(1,hsl[1]*5)
            var shift = [Double](repeating:0,count:3), total = 0.0
            for band in HueBand.allCases {
                let distance = abs(originalHue-band.center)
                let circular = min(distance,1-distance)
                let weight = exp(-0.5 * pow(circular/0.075,2))
                let adjustment = o.hsl[band.rawValue]
                shift[0] += adjustment.hue*weight; shift[1] += adjustment.saturation*weight; shift[2] += adjustment.lightness*weight
                total += weight
            }
            hsl[0] = wrap(hsl[0]+shift[0]/max(total,0.0001)*chroma)
            hsl[1] = clamp(hsl[1]*(1+shift[1]/max(total,0.0001)))
            hsl[2] = clamp(hsl[2]+shift[2]/max(total,0.0001)*chroma)
            rgb = fromHSL(hsl)
        }
        if o.shadows.amount > 0 || o.midtones.amount > 0 || o.highlights.amount > 0 {
            let y = rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722
            let split = 0.5 + o.balance*0.25, width = 0.08+o.blending*0.3
            let shadow = 1-smoothstep(split-width,split,y), highlight = smoothstep(split,split+width,y)
            let weights = [shadow,max(0,1-shadow-highlight),highlight]
            for (index,wheel) in [o.shadows,o.midtones,o.highlights].enumerated() {
                if wheel.amount == 0 { continue }
                let tint = fromHSL([wheel.hue/360,1,0.5])
                let luma = tint[0]*0.2126+tint[1]*0.7152+tint[2]*0.0722
                for c in 0..<3 { rgb[c] += (tint[c]-luma)*wheel.amount*weights[index]*0.18 }
            }
        }
        if o.dehaze > 0 {
            // Per-pixel dark-channel approximation, not a recovered depth map.
            let dark = max(0,rgb.min() ?? 0), transmission = max(0.45,1-o.dehaze*dark)
            rgb = rgb.map { ($0-(1-transmission))/transmission }
        } else if o.dehaze < 0 { rgb = rgb.map { $0*(1+o.dehaze)+(-o.dehaze)*0.75 } }
        return rgb.map(clamp)
    }
    static func curve(_ x: Double, points: [Double]) -> Double {
        let position = clamp(x)*4, lower = min(3,Int(position)), t = position-Double(lower)
        return points[lower]*(1-t)+points[lower+1]*t
    }
    private static func clamp(_ x: Double) -> Double { min(1,max(0,x)) }
    private static func wrap(_ x: Double) -> Double { x-floor(x) }
    private static func smoothstep(_ a: Double,_ b: Double,_ x: Double) -> Double { let t=clamp((x-a)/(b-a));return t*t*(3-2*t) }
    private static func toHSL(_ rgb: [Double]) -> [Double] {
        let high=rgb.max()!, low=rgb.min()!, delta=high-low, light=(high+low)/2
        guard delta>0.00001 else { return [0,0,light] }
        let hue: Double
        if high==rgb[0] { hue=(rgb[1]-rgb[2])/delta }
        else if high==rgb[1] { hue=(rgb[2]-rgb[0])/delta+2 }
        else { hue=(rgb[0]-rgb[1])/delta+4 }
        return [wrap(hue/6),delta/max(0.00001,1-abs(2*light-1)),light]
    }
    private static func fromHSL(_ hsl: [Double]) -> [Double] {
        let h=wrap(hsl[0])*6, c=(1-abs(2*hsl[2]-1))*hsl[1], x=c*(1-abs(h.truncatingRemainder(dividingBy:2)-1)), m=hsl[2]-c/2
        let v: [Double]
        switch Int(h) { case 0:v=[c,x,0];case 1:v=[x,c,0];case 2:v=[0,c,x];case 3:v=[0,x,c];case 4:v=[x,0,c];default:v=[c,0,x] }
        return v.map { $0+m }
    }
}
