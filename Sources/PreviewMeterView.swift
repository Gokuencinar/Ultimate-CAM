import SwiftUI

struct PreviewMeterView:View {
    let metrics:PreviewLumaMetrics
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Canvas { context,size in
                let peak=max(metrics.histogram.max() ?? 1,0.0001)
                for (i,value) in metrics.histogram.enumerated() {
                    let height=CGFloat(value/peak)*size.height
                    context.fill(Path(CGRect(x:CGFloat(i)*size.width/64,y:size.height-height,width:size.width/64,height:height)),with:.color(.white.opacity(0.85)))
                }
            }.frame(width:128,height:48)
            Text("Sombras \(Int(metrics.shadows*100))% · Luces \(Int(metrics.highlights*100))%")
                .font(.system(size:8,design:.monospaced))
        }.padding(7).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:8))
            .accessibilityLabel("Histograma del visor. Luces extremas \(Int(metrics.highlights*100)) por ciento")
            .allowsHitTesting(false)
    }
}
