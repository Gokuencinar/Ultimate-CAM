// Copyright 2018 Google LLC
// Licensed under the Apache License, Version 2.0; see Legal/Google-Burst-Denoising.txt.
// Adapted in 2026 for Ultimate CAM: Swift/Accelerate, streaming RGB pairs,
// clamped boundaries and an empirical RGB noise estimate. This is a research
// baseline, not the proprietary Google Camera implementation or a Bayer model.
// Reference: google/burst-denoising, 7ff07e009568778ff337c259e192d1d81aedbea6,
// py_image.py: rcwindow and hdrplus_merge.

import Accelerate
import CoreImage

final class ResearchWienerTile {
    static let side=32
    let window:[Float]
    private let setup:FFTSetup
    private var referenceReal=[Float](repeating:0,count:1024)
    private var referenceImag=[Float](repeating:0,count:1024)
    private var sampleReal=[Float](repeating:0,count:1024)
    private var sampleImag=[Float](repeating:0,count:1024)
    init() throws {
        guard let setup=vDSP_create_fftsetup(5,FFTRadix(kFFTRadix2)) else { throw CameraFailure.message("No se pudo preparar la fusión espectral.") }
        self.setup=setup
        let axis=(0..<32).map { Float(0.5-0.5*cos(2*Double.pi*(Double($0)+0.5)/32)) }
        window=(0..<1024).map { axis[$0%32]*axis[$0/32] }
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    /// Returns a windowed regularized sample. Averaging this with the reference
    /// and other regularized samples equals the upstream multi-frame formula.
    func regularize(reference:[Float],sample:[Float],sigma:Float,strength:Float=1) throws -> [Float] {
        guard reference.count==1024,sample.count==1024,sigma.isFinite,sigma>0,sigma<=1,
              strength.isFinite,(0.25...4).contains(strength) else { throw CameraFailure.message("Parámetros de fusión espectral fuera de rango.") }
        for i in 0..<1024 {
            guard reference[i].isFinite,sample[i].isFinite else { throw CameraFailure.message("La imagen espectral contiene valores no válidos.") }
            referenceReal[i]=reference[i]*window[i];sampleReal[i]=sample[i]*window[i]
            referenceImag[i]=0;sampleImag[i]=0
        }
        fft(&referenceReal,&referenceImag,FFTDirection(kFFTDirection_Forward))
        fft(&sampleReal,&sampleImag,FFTDirection(kFFTDirection_Forward))
        let noise=Float(pow(10.0,2.5))*strength*sigma*sigma
        for i in 0..<1024 {
            let dr=sampleReal[i]-referenceReal[i],di=sampleImag[i]-referenceImag[i]
            let acceptance=noise/(dr*dr+di*di+noise)
            sampleReal[i]=referenceReal[i]+acceptance*dr
            sampleImag[i]=referenceImag[i]+acceptance*di
        }
        fft(&sampleReal,&sampleImag,FFTDirection(kFFTDirection_Inverse))
        let output=sampleReal.map { $0/1024 }
        guard output.allSatisfy(\.isFinite) else { throw CameraFailure.message("La fusión espectral no devolvió valores finitos.") }
        return output
    }
    private func fft(_ real:inout [Float],_ imaginary:inout [Float],_ direction:FFTDirection) {
        real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
            var complex=DSPSplitComplex(realp:r.baseAddress!,imagp:i.baseAddress!)
            vDSP_fft2d_zip(setup,&complex,1,0,5,5,direction)
        } }
    }
}

/// One reference buffer and one sample at a time. No burst-sized spectral cache.
/// Called exclusively on the photo processing queue, never the UI/session queue.
final class ResearchWienerFilter {
    private let reference:[Float]
    private let extent:CGRect
    private let width:Int
    private let context:CIContext
    private let tile:ResearchWienerTile
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    init(reference:CIImage,context:CIContext) throws {
        let extent=reference.extent
        guard extent.origin.x.isFinite,extent.origin.y.isFinite,extent.width.isFinite,extent.height.isFinite,
              extent.width>0,extent.height>0,extent.width<=2048,extent.height<=2048,extent==extent.integral else {
            throw CameraFailure.message("La fusión espectral necesita una imagen entera de hasta 2048 px por lado.")
        }
        self.context=context;self.extent=extent;width=Int(extent.width);tile=try ResearchWienerTile()
        let workingSpace=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        var pixels=[Float](repeating:0,count:Int(extent.width*extent.height)*4)
        pixels.withUnsafeMutableBytes { context.render(reference,toBitmap:$0.baseAddress!,rowBytes:Int(extent.width)*16,bounds:extent,format:.RGBAf,colorSpace:workingSpace) }
        guard pixels.allSatisfy(\.isFinite) else { throw CameraFailure.message("La referencia espectral no es válida.") }
        self.reference=pixels
    }
    func filter(_ image:CIImage,extent region:CGRect,strength:Double=1,cancellation:ProcessingCancellation?=nil) throws -> CIImage {
        guard region==region.integral,extent.contains(region),region.width>0,region.height>0,
              strength.isFinite,(0.25...4).contains(strength) else { throw CameraFailure.message("Región espectral fuera de límites.") }
        try cancellation?.check()
        let w=Int(region.width),h=Int(region.height),ox=Int(region.minX-extent.minX),oy=Int(region.minY-extent.minY)
        var pixels=[Float](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:region,format:.RGBAf,colorSpace:space) }
        guard pixels.allSatisfy(\.isFinite) else { throw CameraFailure.message("El fotograma espectral no es válido.") }
        let sigmas=Self.noise(reference:reference,referenceWidth:width,sample:pixels,width:w,height:h,originX:ox,originY:oy)
        var output=[Float](repeating:0,count:w*h*4),weights=[Float](repeating:0,count:w*h)
        var r=[Float](repeating:0,count:1024),s=r
        // Half-tile overlap. Unlike the research oracle's periodic wrapping,
        // boundaries clamp locally, so opposite picture edges never mix.
        for y in stride(from:-16,to:h,by:16) {
            try cancellation?.check()
            for x in stride(from:-16,to:w,by:16) {
                for channel in 0..<3 {
                    for j in 0..<32 { for i in 0..<32 {
                        let px=min(w-1,max(0,x+i)),py=min(h-1,max(0,y+j)),index=j*32+i
                        r[index]=reference[((py+oy)*width+px+ox)*4+channel]
                        s[index]=pixels[(py*w+px)*4+channel]
                    } }
                    let filtered=try tile.regularize(reference:r,sample:s,sigma:sigmas[channel],strength:Float(strength))
                    for j in max(0,-y)..<min(32,h-y) { for i in max(0,-x)..<min(32,w-x) {
                        let p=(y+j)*w+x+i,index=j*32+i
                        output[p*4+channel]+=filtered[index]
                        if channel==0 { weights[p]+=tile.window[index] }
                    } }
                }
            }
        }
        for p in 0..<w*h {
            guard weights[p]>0.0001 else { throw CameraFailure.message("La fusión espectral dejó un hueco en la imagen.") }
            for c in 0..<3 { output[p*4+c]/=weights[p] }
            output[p*4+3]=1
        }
        let data=output.withUnsafeBufferPointer { Data(buffer:$0) }
        return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
            .transformed(by:CGAffineTransform(translationX:region.minX,y:region.minY))
    }
    private static func noise(reference:[Float],referenceWidth:Int,sample:[Float],width:Int,height:Int,originX:Int,originY:Int) -> [Float] {
        guard width>1,height>1 else { return [0.005,0.005,0.005] }
        let step=max(1,Int(sqrt(Double(width*height)/16000)))
        var residuals=[[Float](),[Float](),[Float]()]
        for y in stride(from:0,to:height-1,by:step) { for x in stride(from:0,to:width-1,by:step) {
            for c in 0..<3 {
                let ref=(y+originY)*referenceWidth+x+originX,p=y*width+x
                let d=sample[p*4+c]-reference[ref*4+c]
                residuals[c].append(abs(d-(sample[(p+1)*4+c]-reference[(ref+1)*4+c])))
                residuals[c].append(abs(d-(sample[(p+width)*4+c]-reference[(ref+referenceWidth)*4+c])))
            }
        } }
        // A difference of independent frame differences has variance 4*sigma².
        // This RGB estimate assumes most sampled areas are static; it is not a
        // sensor NoiseProfile transformed through the RAW demosaicing pipeline.
        return residuals.map { values in
            let sorted=values.sorted();guard !sorted.isEmpty else { return 0.005 }
            return min(0.25,max(0.0005,sorted[sorted.count/2]/(2*0.67448975)))
        }
    }
}
