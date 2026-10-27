import Foundation

enum PhotoProcessingPreset:Equatable { case natural,detail,night }

/// Mode changes affect the capture recipe, not the user's color/LUT or RAW
/// preferences. A non-RAW lens uses JPEG without requesting an invalid format.
enum PhotoModePolicy {
    static func formatLabel(_ options:ProcessingOptions,photoRAW:Bool)->String {
        if options.nightStatic { return options.nightMetalRAW ? "RAW*":"JPEG" }
        if options.hdrBracketing { return options.hdrMetalRAW ? "RAW*":"JPEG" }
        return photoRAW ? "RAW+":"JPEG"
    }
    static func toggledRAW(_ current:ProcessingOptions,photoRAW:Bool,supportsRAW:Bool)->(options:ProcessingOptions,photoRAW:Bool) {
        guard supportsRAW else { return (current,photoRAW) }
        var next=current
        if next.nightStatic {
            next.nightMetalRAW.toggle();next.nightRAW=next.nightMetalRAW
            if next.nightMetalRAW { next.nightSpectralFusion=false }
            return (next,false)
        }
        if next.hdrBracketing { next.hdrMetalRAW.toggle();return (next,false) }
        let raw = !photoRAW
        if raw { next.zeroShutterLagFusion=false }
        return (next,raw)
    }
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
