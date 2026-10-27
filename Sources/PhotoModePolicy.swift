import Foundation

enum PhotoProcessingPreset:Equatable { case natural,detail,night }

/// Mode changes affect the capture recipe, not the user's color/LUT or RAW
/// preferences. A non-RAW lens uses JPEG without requesting an invalid format.
enum PhotoModePolicy {
    static func preset(_ preset:PhotoProcessingPreset,from current:ProcessingOptions,supportsRAW:Bool)->ProcessingOptions {
        var next=current
        next.nightStatic=preset == .night;next.hdrBracketing=false;next.portraitAmount=0
        next.noiseReduction=next.nightStatic ? 0.012:0
        next.sharpening=preset == .detail ? 0.25:(next.nightStatic ? 0.1:0)
        next.liftShadows=0
        if next.nightStatic { next.maximumDimension=4096 }
        return rawCompatible(next,supportsRAW:supportsRAW)
    }
    static func hdr(from current:ProcessingOptions,supportsRAW:Bool)->ProcessingOptions {
        var next=current
        next.nightStatic=false;next.hdrBracketing=true;next.portraitAmount=0
        return rawCompatible(next,supportsRAW:supportsRAW)
    }
    private static func rawCompatible(_ value:ProcessingOptions,supportsRAW:Bool)->ProcessingOptions {
        var next=value
        if supportsRAW {
            if next.nightMetalRAW { next.nightRAW=true;next.nightSpectralFusion=false }
        } else { next.nightMetalRAW=false;next.nightRAW=false;next.hdrMetalRAW=false }
        return next
    }
}
