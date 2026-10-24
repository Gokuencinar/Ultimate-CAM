import SwiftUI
import UniformTypeIdentifiers

struct ProfileFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ResultHistogram: View {
    let statistics: ImageStatistics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Histograma del resultado JPEG").font(.subheadline.bold())
            Canvas { context, size in
                let peak = max(0.0001, statistics.histogram.max() ?? 0)
                let width = size.width / CGFloat(statistics.histogram.count)
                for (index, count) in statistics.histogram.enumerated() {
                    let height = size.height * CGFloat(count / peak)
                    context.fill(Path(CGRect(x: CGFloat(index) * width, y: size.height-height, width: max(1, width-1), height: height)), with: .color(CameraPalette.accent))
                }
            }.frame(height: 70).accessibilityLabel("Distribución de luminosidad del JPEG")
            Text(String(format: "Negros ≤3: %.1f %% · Luces ≥252: %.1f %%", statistics.shadows * 100, statistics.highlights * 100))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
