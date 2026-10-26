import Foundation

enum OutputColor: String, Codable, CaseIterable, Identifiable {
    case sRGB, displayP3
    var id: String { rawValue }
    var label: String { self == .sRGB ? "sRGB" : "Display P3" }
}
enum PhotoAspect: String, Codable, CaseIterable, Identifiable {
    case original, square, wide
    var id: String { rawValue }
    var label: String { switch self { case .original: return "Original"; case .square: return "1:1"; case .wide: return "16:9" } }
}

struct ProcessingOptions: Codable, Equatable {
    var zeroShutterLagFusion:Bool = false
    var nightMetalRAW:Bool = false
    var nightMotionMetering:Bool = true
    var singlePhotoQuality: SinglePhotoQuality = .quality
    var nightBudget: Double = 8
    var nightShutterLimit: Double = 1
    var nightWeightedFusion: Bool = true
    var nightSpectralFusion: Bool = false
    var nightSpectralStrength: Double = 1
    var hdrBracketing: Bool = false
    var hdrSpan: Double = 2
    var color = ColorRecipe()
    var nightStatic: Bool = false
    var nightRAW: Bool = false
    var chooseSharpestReference: Bool = true
    var rejectMotion: Bool = true
    var maximumDimension: Double = 2560
    var noiseReduction: Double = 0
    var sharpening: Double = 0
    var liftShadows: Double = 0
    var localAlignment: Bool = false
    var adaptiveMotionRejection: Bool = false
    var motionSigma: Double = 3
    var chromaDenoise: Double = 0
    var localContrast: Double = 0
    var fineDetail: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var vibrance: Double = 0
    var gamma: Double = 1
    var postExposure: Double = 0
    var highlightCompression: Double = 0
    var sharpenRadius: Double = 1
    var vignette: Double = 0
    var jpegQuality: Double? = nil
    var outputColor: OutputColor = OutputColor.sRGB
    var preserveHDR: Bool = false
    var portraitAmount: Double = 0
    var aspect: PhotoAspect = PhotoAspect.original
    var lutID: String? = nil
    var lutIntensity: Double = 1

    var advancedRendering: Bool {
        color.isActive || chromaDenoise > 0 || localContrast > 0 || fineDetail > 0 || contrast != 1 || saturation != 1 ||
        vibrance != 0 || gamma != 1 || postExposure != 0 || highlightCompression > 0 || vignette > 0 ||
        jpegQuality != nil || portraitAmount > 0 || outputColor != .sRGB || aspect != .original || (lutID != nil && lutIntensity > 0)
    }

    func validated() throws -> ProcessingOptions {
        guard !(nightStatic && nightMetalRAW && (!nightRAW || nightSpectralFusion)) else { throw CameraFailure.message("Metal Bayer necesita RAW y no se combina con la fusión espectral RGB.") }
        guard nightSpectralStrength.isFinite,(0.25...4).contains(nightSpectralStrength),
              !(nightStatic && nightSpectralFusion && !rejectMotion) else { throw CameraFailure.message("La fusión espectral necesita rechazo de movimiento y una intensidad entre 0,25 y 4.") }
        guard nightBudget.isFinite, (1...16).contains(nightBudget), nightShutterLimit.isFinite,
              (1.0/30...1).contains(nightShutterLimit) else { throw CameraFailure.message("Presupuesto nocturno fuera de rango.") }
        _ = try color.validated()
        guard portraitAmount.isFinite,(0...1).contains(portraitAmount) else { throw CameraFailure.message("Desenfoque de retrato fuera de rango.") }
        guard !(hdrBracketing && nightStatic), hdrSpan.isFinite, (1...3).contains(hdrSpan) else { throw CameraFailure.message("Configuración HDR incompatible o fuera de rango.") }
        guard maximumDimension.isFinite, (1024...4096).contains(maximumDimension) else { throw CameraFailure.message("Valor fuera de rango: maximumDimension.") }
        guard noiseReduction.isFinite, (0...0.08).contains(noiseReduction) else { throw CameraFailure.message("Valor fuera de rango: noiseReduction.") }
        guard sharpening.isFinite, (0...0.8).contains(sharpening) else { throw CameraFailure.message("Valor fuera de rango: sharpening.") }
        guard liftShadows.isFinite, (0...1).contains(liftShadows) else { throw CameraFailure.message("Valor fuera de rango: liftShadows.") }
        guard motionSigma.isFinite, (1.5...6).contains(motionSigma) else { throw CameraFailure.message("Valor fuera de rango: motionSigma.") }
        guard chromaDenoise.isFinite, (0...1).contains(chromaDenoise) else { throw CameraFailure.message("Valor fuera de rango: chromaDenoise.") }
        guard localContrast.isFinite, (0...1.5).contains(localContrast) else { throw CameraFailure.message("Valor fuera de rango: localContrast.") }
        guard fineDetail.isFinite, (0...1).contains(fineDetail) else { throw CameraFailure.message("Valor fuera de rango: fineDetail.") }
        guard contrast.isFinite, (0.5...1.5).contains(contrast) else { throw CameraFailure.message("Valor fuera de rango: contrast.") }
        guard saturation.isFinite, (0...2).contains(saturation) else { throw CameraFailure.message("Valor fuera de rango: saturation.") }
        guard vibrance.isFinite, (-1...1).contains(vibrance) else { throw CameraFailure.message("Valor fuera de rango: vibrance.") }
        guard gamma.isFinite, (0.5...2).contains(gamma) else { throw CameraFailure.message("Valor fuera de rango: gamma.") }
        guard postExposure.isFinite, (-2...2).contains(postExposure) else { throw CameraFailure.message("Valor fuera de rango: postExposure.") }
        guard highlightCompression.isFinite, (0...1).contains(highlightCompression) else { throw CameraFailure.message("Valor fuera de rango: highlightCompression.") }
        guard sharpenRadius.isFinite, (0.5...4).contains(sharpenRadius) else { throw CameraFailure.message("Valor fuera de rango: sharpenRadius.") }
        guard vignette.isFinite, (0...1).contains(vignette) else { throw CameraFailure.message("Valor fuera de rango: vignette.") }
        guard lutIntensity.isFinite, (0...1).contains(lutIntensity) else { throw CameraFailure.message("Valor fuera de rango: lutIntensity.") }
        if let jpegQuality, !jpegQuality.isFinite || !(0.5...1).contains(jpegQuality) {
            throw CameraFailure.message("Calidad JPEG fuera de rango.")
        }
        if let lutID, UUID(uuidString: lutID) == nil { throw CameraFailure.message("Identificador LUT no válido.") }
        return self
    }
}

// Missing keys use defaults; old profiles remain readable. Bad values are rejected,
// not silently clamped into a different recipe.
extension ProcessingOptions {
    enum CodingKeys: String, CodingKey {
        case zeroShutterLagFusion, nightMetalRAW, nightMotionMetering, singlePhotoQuality, nightBudget, nightShutterLimit, nightWeightedFusion, nightSpectralFusion, nightSpectralStrength, hdrBracketing, hdrSpan, color, nightStatic, nightRAW, chooseSharpestReference, rejectMotion, maximumDimension, noiseReduction, sharpening, liftShadows, localAlignment, adaptiveMotionRejection, motionSigma, chromaDenoise, localContrast, fineDetail, contrast, saturation, vibrance, gamma, postExposure, highlightCompression, sharpenRadius, vignette, jpegQuality, outputColor, preserveHDR, portraitAmount, aspect, lutID, lutIntensity
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zeroShutterLagFusion = try c.decodeIfPresent(Bool.self,forKey:.zeroShutterLagFusion) ?? zeroShutterLagFusion
        nightMetalRAW = try c.decodeIfPresent(Bool.self,forKey:.nightMetalRAW) ?? nightMetalRAW
        nightMotionMetering = try c.decodeIfPresent(Bool.self,forKey:.nightMotionMetering) ?? nightMotionMetering
        singlePhotoQuality = try c.decodeIfPresent(SinglePhotoQuality.self, forKey: .singlePhotoQuality) ?? singlePhotoQuality
        nightBudget = try c.decodeIfPresent(Double.self, forKey: .nightBudget) ?? nightBudget
        nightShutterLimit = try c.decodeIfPresent(Double.self, forKey: .nightShutterLimit) ?? nightShutterLimit
        nightWeightedFusion = try c.decodeIfPresent(Bool.self, forKey: .nightWeightedFusion) ?? nightWeightedFusion
        nightSpectralFusion = try c.decodeIfPresent(Bool.self,forKey:.nightSpectralFusion) ?? nightSpectralFusion
        nightSpectralStrength = try c.decodeIfPresent(Double.self,forKey:.nightSpectralStrength) ?? nightSpectralStrength
        hdrBracketing = try c.decodeIfPresent(Bool.self, forKey: .hdrBracketing) ?? hdrBracketing
        hdrSpan = try c.decodeIfPresent(Double.self, forKey: .hdrSpan) ?? hdrSpan
        color = try c.decodeIfPresent(ColorRecipe.self, forKey: .color) ?? color
        nightStatic = try c.decodeIfPresent(Bool.self, forKey: .nightStatic) ?? nightStatic
        nightRAW = try c.decodeIfPresent(Bool.self, forKey: .nightRAW) ?? nightRAW
        chooseSharpestReference = try c.decodeIfPresent(Bool.self, forKey: .chooseSharpestReference) ?? chooseSharpestReference
        rejectMotion = try c.decodeIfPresent(Bool.self, forKey: .rejectMotion) ?? rejectMotion
        maximumDimension = try c.decodeIfPresent(Double.self, forKey: .maximumDimension) ?? maximumDimension
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? noiseReduction
        sharpening = try c.decodeIfPresent(Double.self, forKey: .sharpening) ?? sharpening
        liftShadows = try c.decodeIfPresent(Double.self, forKey: .liftShadows) ?? liftShadows
        localAlignment = try c.decodeIfPresent(Bool.self, forKey: .localAlignment) ?? localAlignment
        adaptiveMotionRejection = try c.decodeIfPresent(Bool.self, forKey: .adaptiveMotionRejection) ?? adaptiveMotionRejection
        motionSigma = try c.decodeIfPresent(Double.self, forKey: .motionSigma) ?? motionSigma
        chromaDenoise = try c.decodeIfPresent(Double.self, forKey: .chromaDenoise) ?? chromaDenoise
        localContrast = try c.decodeIfPresent(Double.self, forKey: .localContrast) ?? localContrast
        fineDetail = try c.decodeIfPresent(Double.self, forKey: .fineDetail) ?? fineDetail
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? gamma
        postExposure = try c.decodeIfPresent(Double.self, forKey: .postExposure) ?? postExposure
        highlightCompression = try c.decodeIfPresent(Double.self, forKey: .highlightCompression) ?? highlightCompression
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? sharpenRadius
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality)
        outputColor = try c.decodeIfPresent(OutputColor.self, forKey: .outputColor) ?? outputColor
        preserveHDR = try c.decodeIfPresent(Bool.self, forKey: .preserveHDR) ?? preserveHDR
        portraitAmount = try c.decodeIfPresent(Double.self, forKey: .portraitAmount) ?? portraitAmount
        aspect = try c.decodeIfPresent(PhotoAspect.self, forKey: .aspect) ?? aspect
        lutID = try c.decodeIfPresent(String.self, forKey: .lutID)
        lutIntensity = try c.decodeIfPresent(Double.self, forKey: .lutIntensity) ?? lutIntensity
        _ = try validated()
    }
}
