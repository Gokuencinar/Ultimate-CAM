import SwiftUI

enum ColorPanel: String, CaseIterable, Identifiable {
    case basic = "Color", curves = "Curvas", hsl = "HSL", grading = "Ruedas", effects = "Efectos"
    var id: String { rawValue }
}

enum CameraPalette {
    // Resolved fallback colors from AGC Material3 dark XML. Android dynamic
    // color may override these on the original phone.
    static let accent = Color(red:208.0/255,green:188.0/255,blue:1)
    static let surface = Color(red:33.0/255,green:31.0/255,blue:38.0/255)
}

struct ColorRecipeEditor: View {
    let panel: ColorPanel
    @Binding var recipe: ColorRecipe
    @State private var band = HueBand.red
    @State private var channel = 0

    var body: some View {
        Group {
            switch panel {
            case .basic: EmptyView()
            case .hsl: hsl
            case .curves: curves
            case .grading: grading
            case .effects: effects
            }
        }
    }
    private var hsl: some View {
        Section("Mezclador de color") {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack {
                    ForEach(HueBand.allCases) { item in
                        Button { band=item } label: {
                            Circle().fill(Color(hue:item.center,saturation:0.85,brightness:0.95))
                                .frame(width:30,height:30).padding(6)
                                .overlay(Circle().stroke(band==item ? .white : .clear,lineWidth:2))
                        }.accessibilityLabel(item.label)
                    }
                }
            }
            Text(band.label).font(.headline)
            slider("Matiz (°)",value:Binding(get:{ recipe.hsl[band.rawValue].hue*360 },set:{ recipe.hsl[band.rawValue].hue=$0/360 }),range:-45...45)
            slider("Saturación",value:$recipe.hsl[band.rawValue].saturation,range:-1...1)
            slider("Luminosidad",value:$recipe.hsl[band.rawValue].lightness,range:-0.5...0.5)
            Button("Restablecer este color") { recipe.hsl[band.rawValue]=HSLAdjustment() }
        }
    }
    private var curve: Binding<[Double]> {
        switch channel { case 1:return $recipe.redCurve;case 2:return $recipe.greenCurve;case 3:return $recipe.blueCurve;default:return $recipe.masterCurve }
    }
    private var curves: some View {
        Section("Curvas de tono") {
            Picker("Canal",selection:$channel) { Text("RGB").tag(0);Text("Rojo").tag(1);Text("Verde").tag(2);Text("Azul").tag(3) }.pickerStyle(.segmented)
            CurvePlot(points:curve).frame(height:180)
            ForEach(0..<5,id:\.self) { index in
                slider(["Negros","Sombras","Medios tonos","Luces","Blancos"][index],
                    value:Binding(get:{ curve.wrappedValue[index] },set:{ curve.wrappedValue[index]=$0 }),range:0...1)
            }
            Button("Restablecer curva") { curve.wrappedValue=[0,0.25,0.5,0.75,1] }
        }
    }
    private var grading: some View {
        Group {
            Section("Gradación por zonas") {
                HStack {
                    GradeWheelView(title:"Sombras",wheel:$recipe.shadows)
                    Spacer(minLength:4)
                    GradeWheelView(title:"Medios",wheel:$recipe.midtones)
                    Spacer(minLength:4)
                    GradeWheelView(title:"Luces",wheel:$recipe.highlights)
                }
                slider("Balance de zonas",value:$recipe.balance,range:-1...1)
                slider("Mezcla de zonas",value:$recipe.blending,range:0...1)
            }
            Section("Intensidad") {
                slider("Sombras",value:$recipe.shadows.amount,range:0...1)
                slider("Medios tonos",value:$recipe.midtones.amount,range:0...1)
                slider("Luces",value:$recipe.highlights.amount,range:0...1)
                Button("Restablecer ruedas") { recipe.shadows=GradeWheel();recipe.midtones=GradeWheel();recipe.highlights=GradeWheel() }
            }
        }
    }
    private var effects: some View {
        Section("Efectos") {
            slider("Borrar neblina",value:$recipe.dehaze,range:-0.5...0.5)
            slider("Grano",value:$recipe.grain,range:0...1)
            slider("Tamaño de grano",value:$recipe.grainSize,range:0.5...4)
            Text("Borrar neblina es una aproximación tonal. Estos efectos modifican el JPEG final; no el sensor ni el DNG.").font(.footnote).foregroundStyle(.secondary)
            Button("Restablecer efectos") { recipe.dehaze=0;recipe.grain=0;recipe.grainSize=1 }
        }
    }
    private func slider(_ title: String,value: Binding<Double>,range: ClosedRange<Double>) -> some View {
        VStack(alignment:.leading) {
            HStack { Text(title);Spacer();Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit().foregroundStyle(CameraPalette.accent) }
            Slider(value:value,in:range).accessibilityLabel(title)
        }
    }
}

private struct GradeWheelView: View {
    let title: String
    @Binding var wheel: GradeWheel
    var body: some View {
        VStack(spacing:8) {
            ZStack {
                Circle().fill(AngularGradient(colors:[.red,.yellow,.green,.cyan,.blue,.purple,.red],center:.center))
                Circle().fill(RadialGradient(colors:[Color(white:0.55),.clear],center:.center,startRadius:0,endRadius:44))
                Circle().stroke(.white,lineWidth:2).frame(width:12,height:12)
                    .offset(x:cos(wheel.hue/180 * .pi)*wheel.amount*37,y:sin(wheel.hue/180 * .pi)*wheel.amount*37)
            }.frame(width:82,height:82)
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    let x=Double(value.location.x)-41,y=Double(value.location.y)-41
                    wheel.hue=(atan2(y,x)*180 / .pi+360).truncatingRemainder(dividingBy:360)
                    wheel.amount=min(1,hypot(x,y)/37)
                })
                .accessibilityLabel("Rueda de "+title)
                .accessibilityValue(String(format:"%.0f grados, %.0f por ciento",wheel.hue,wheel.amount*100))
                .accessibilityAdjustableAction { direction in wheel.hue=(wheel.hue+(direction == .increment ? 5 : 355)).truncatingRemainder(dividingBy:360) }
            Text(title).font(.caption)
        }
    }
}

private struct CurvePlot: View {
    @Binding var points: [Double]
    var body: some View {
        GeometryReader { proxy in
            Canvas { context,size in
                var grid=Path()
                for i in 0...4 { let f=CGFloat(i)/4;grid.move(to:CGPoint(x:f*size.width,y:0));grid.addLine(to:CGPoint(x:f*size.width,y:size.height));grid.move(to:CGPoint(x:0,y:f*size.height));grid.addLine(to:CGPoint(x:size.width,y:f*size.height)) }
                context.stroke(grid,with:.color(.white.opacity(0.12)),lineWidth:1)
                var line=Path()
                for (index,value) in points.enumerated() {
                    let p=CGPoint(x:CGFloat(index)/4*size.width,y:CGFloat(1-value)*size.height)
                    if index==0 { line.move(to:p) } else { line.addLine(to:p) }
                    context.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.white))
                }
                context.stroke(line,with:.color(CameraPalette.accent),lineWidth:2)
            }.gesture(DragGesture(minimumDistance:0).onChanged { value in
                let index=min(4,max(0,Int((value.location.x/proxy.size.width*4).rounded())))
                points[index]=min(1,max(0,1-Double(value.location.y/proxy.size.height)))
            })
        }.accessibilityLabel("Curva editable; los deslizadores permiten ajustar cada punto.")
    }
}
