import CoreImage
import Metal

struct MetalFusionParameters {
    var size=SIMD4<UInt32>(0,0,16,0)
    var search=SIMD4<Int32>(0,0,0,0)
    var control=SIMD4<Float>(1e-7,1,4,1)
    var luma=SIMD4<Float>(0.2126,0.7152,0.0722,0)
    var noise=SIMD4<Float>(0,0,0,0)
    var tone=SIMD4<Float>(0,0,0,0)
    var sensorNoise=SIMD4<Float>(0,0,0,0)
    var flags=SIMD4<UInt32>(repeating:0)
    var sr=SIMD4<Float>(0,0,1,1)
    var roi=SIMD4<UInt32>(0,0,0,0)
    var patch=SIMD4<Float>(3,0,0,0)
    var finishing=SIMD4<Float>(0,0,0,1)
    var neutral=SIMD4<Float>(repeating:1)
    mutating func configure(_ o:ProcessingOptions) {
        patch=SIMD4(Float(o.motionSigma),Float(o.fineDetail),Float(o.localContrast),Float(o.liftShadows))
        finishing=SIMD4(Float(o.highlightCompression),Float(o.chromaDenoise),0,o.rejectMotion ? 1:0)
    }
}

/// Own compute kernels, not the private Apple ISP or Google's proprietary HDR+.
/// The reference stays fixed; each additional frame is materialized and retired
/// before the next one. All methods run on the photo-processing queue.
final class MetalBurstProcessor {
    /// One workspace per burst. The reference pyramid is immutable; sample,
    /// flow and ping-pong accumulators are reused after command completion.
    private final class FusionWorkspace {
        let original:MTLTexture,reference:MTLTexture,sample:MTLTexture,sampleUpload:MTLTexture
        let referencePyramid:[MTLTexture],samplePyramid:[MTLTexture],flow:[MTLTexture],regularizedFlow:[MTLTexture]
        let means:[MTLTexture],weights:[MTLTexture]
        var srMeans=[MTLTexture](),srWeights=[MTLTexture]()
        var structureTensor:MTLTexture?
        var srSlot=0
        var slot=0
        var mean:MTLTexture { means[slot] }
        init(original:MTLTexture,reference:MTLTexture,sample:MTLTexture,sampleUpload:MTLTexture,referencePyramid:[MTLTexture],samplePyramid:[MTLTexture],flow:[MTLTexture],regularizedFlow:[MTLTexture],means:[MTLTexture],weights:[MTLTexture]) {
            self.original=original;self.reference=reference;self.sample=sample;self.sampleUpload=sampleUpload;self.referencePyramid=referencePyramid
            self.samplePyramid=samplePyramid;self.flow=flow;self.regularizedFlow=regularizedFlow;self.means=means;self.weights=weights
        }
    }
    private let device:MTLDevice,queue:MTLCommandQueue
    private let context:CIContext
    private let kernels:[String:MTLComputePipelineState]
    private let directionalSuperResolution:Bool
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    init(device suppliedDevice:MTLDevice?=nil,library suppliedLibrary:MTLLibrary?=nil,directionalSuperResolution:Bool=true) throws {
        guard let device=suppliedDevice ?? MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw CameraFailure.message("Metal no está disponible.") }
        let library=try suppliedLibrary ?? device.makeDefaultLibrary(bundle:Bundle.main)
        guard library.device.registryID==device.registryID else { throw CameraFailure.message("La biblioteca Metal pertenece a otra GPU.") }
        var kernels=[String:MTLComputePipelineState]()
        for name in ["uc_reconstruct_highlights","uc_lca","uc_structure_tensor","uc_fuse_super_res","uc_clear","uc_initial_weights","uc_protect_bayer","uc_luma","uc_pyramid","uc_tile_flow","uc_regularize_flow","uc_fuse_tiles","uc_tone_luma","uc_night_tone"] {
            guard let function=library.makeFunction(name:name) else { throw CameraFailure.message("Falta un shader del procesador Metal.") }
            kernels[name]=try device.makeComputePipelineState(function:function)
        }
        self.device=device;self.queue=queue;self.kernels=kernels;self.directionalSuperResolution=directionalSuperResolution
        context=CIContext(mtlDevice:device,options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates:false])
    }
    private func texture(_ width:Int,_ height:Int,format:MTLPixelFormat = .rgba16Float,storage:MTLStorageMode = .private) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
        descriptor.storageMode = storage;descriptor.usage=format == .rgba16Float ? [.shaderRead,.shaderWrite,.renderTarget]:[.shaderRead,.shaderWrite]
        guard let texture=device.makeTexture(descriptor:descriptor) else { throw CameraFailure.message("No hay memoria para el procesado Metal.") };return texture
    }
    private func command() throws -> MTLCommandBuffer {
        guard let buffer=queue.makeCommandBuffer() else { throw CameraFailure.message("No se pudo preparar el trabajo de GPU.") };return buffer
    }
    private func encode(_ name:String,_ command:MTLCommandBuffer,textures:[MTLTexture],parameters:MetalFusionParameters=MetalFusionParameters()) throws {
        guard let state=kernels[name],let encoder=command.makeComputeCommandEncoder() else { throw CameraFailure.message("No se pudo preparar el shader.") }
        encoder.setComputePipelineState(state)
        for (index,texture) in textures.enumerated() { encoder.setTexture(texture,index:index) }
        var parameters=parameters
        encoder.setBytes(&parameters,length:MemoryLayout<MetalFusionParameters>.stride,index:0)
        let target=textures[(name=="uc_fuse_tiles" || name=="uc_fuse_super_res") ? 6:textures.count-1],width=state.threadExecutionWidth,height=max(1,min(8,state.maxTotalThreadsPerThreadgroup/width))
        encoder.dispatchThreads(MTLSize(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:MTLSize(width:width,height:height,depth:1))
        encoder.endEncoding()
    }
    private func finish(_ command:MTLCommandBuffer,cancellation:ProcessingCancellation?) throws {
        try cancellation?.check();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? CameraFailure.message("La GPU no completó la fusión.") }
        try cancellation?.check()
    }
    private func load(_ image:CIImage,width:Int,height:Int,cancellation:ProcessingCancellation?) throws -> MTLTexture {
        let texture=try texture(width,height),command=try command()
        context.render(image,to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:space)
        try finish(command,cancellation:cancellation);return texture
    }
    private func upload(_ frame:SensorBayerFrame,into existing:MTLTexture?=nil) throws -> MTLTexture {
        let texture:MTLTexture=try existing ?? self.texture(frame.width,frame.height,storage:.shared)
        guard texture.width==frame.width,texture.height==frame.height,texture.storageMode == .shared else { throw CameraFailure.message("El plano RAW cambió de tamaño.") }
        frame.quads.withUnsafeBytes { bytes in
            texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:frame.width*8)
        };return texture
    }
    private func readback(_ texture:MTLTexture,region:MTLRegion,cancellation:ProcessingCancellation?=nil) throws -> Data {
        let rowBytes=region.size.width*8,padded=(rowBytes+255)/256*256
        let count=padded*region.size.height
        guard let buffer=device.makeBuffer(length:count,options:.storageModeShared) else { throw CameraFailure.message("No hay memoria para descargar el resultado Metal.") }
        let command=try command()
        guard let blit=command.makeBlitCommandEncoder() else { throw CameraFailure.message("No se pudo preparar la descarga de GPU.") }
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:region.origin,sourceSize:region.size,
            to:buffer,destinationOffset:0,destinationBytesPerRow:padded,destinationBytesPerImage:count)
        blit.endEncoding();try finish(command,cancellation:cancellation)
        if padded==rowBytes {
            // The Data owns a reference to the shared staging buffer, not its
            // allocation. Never free Metal-owned memory or make a second copy.
            return Data(bytesNoCopy:buffer.contents(),count:count,deallocator:.custom { _,_ in withExtendedLifetime(buffer) {} })
        }
        let length=rowBytes*region.size.height,compact=UnsafeMutableRawPointer.allocate(byteCount:length,alignment:16)
        for row in 0..<region.size.height { compact.advanced(by:row*rowBytes).copyMemory(from:buffer.contents().advanced(by:row*padded),byteCount:rowBytes) }
        return Data(bytesNoCopy:compact,count:length,deallocator:.custom { pointer,_ in pointer.deallocate() })
    }
    private func download(_ texture:MTLTexture,cancellation:ProcessingCancellation?) throws -> Data {
        try readback(texture,region:MTLRegionMake2D(0,0,texture.width,texture.height),cancellation:cancellation)
    }
    private func noisePatch(_ texture:MTLTexture) throws -> Data {
        let w=min(96,texture.width),h=min(64,texture.height)
        return try readback(texture,region:MTLRegionMake2D((texture.width-w)/2,(texture.height-h)/2,w,h))
    }
    private func protectedReference(_ frame:SensorBayerFrame,preservePoints:Bool,parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws -> (clean:MTLTexture,original:MTLTexture?) {
        try autoreleasepool {
            try cancellation?.check()
            let original=try upload(frame),clean=try texture(frame.width,frame.height),command=try command()
            try encode("uc_protect_bayer",command,textures:[original,clean],parameters:parameters)
            try finish(command,cancellation:cancellation)
            frame.discardResidentPages()
            // Astro / super-resolution retain temporal point evidence. HDR and
            // ordinary night no longer retain the unprotected full sensor plane.
            return (clean,preservePoints ? original:nil)
        }
    }
    private func workspace(reference:MTLTexture,original:MTLTexture?=nil,raw:Bool,parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws -> FusionWorkspace {
        let w=reference.width,h=reference.height
        var refs=[MTLTexture](),samples=[MTLTexture](),flows=[MTLTexture](),regularized=[MTLTexture]()
        var width=w,height=h
        for _ in 0..<3 {
            refs.append(try texture(width,height,format:.r16Float))
            samples.append(try texture(width,height,format:.r16Float))
            flows.append(try texture((width+15)/16,(height+15)/16,format:.rgba32Float))
            regularized.append(try texture((width+15)/16,(height+15)/16,format:.rgba32Float))
            width=max(1,width/2);height=max(1,height/2)
        }
        let means=try [texture(w,h),texture(w,h)]
        let weights=try [texture(w,h,format:.r16Float),texture(w,h,format:.r16Float)]
        let sample=try texture(w,h),sampleUpload=try raw ? texture(w,h,storage:.shared):sample
        let protectedReference=reference
        let result=FusionWorkspace(original:original ?? reference,reference:protectedReference,sample:sample,sampleUpload:sampleUpload,referencePyramid:refs,samplePyramid:samples,flow:flows,regularizedFlow:regularized,means:means,weights:weights)
        let command=try command()
        // Clean both the alignment anchor and the initial accumulated mean.
        // Otherwise the reference impulse would survive even after residuals
        // accepted clean samples. Original saved DNG bytes are untouched.
        guard let blit=command.makeBlitCommandEncoder() else { throw CameraFailure.message("No se pudo preparar la acumulación.") }
        blit.copy(from:protectedReference,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),
            to:means[0],destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        blit.endEncoding()
        try encode("uc_initial_weights",command,textures:[weights[0]])
        try encode("uc_luma",command,textures:[parameters.flags.x==1 ? (original ?? reference):protectedReference,refs[0]],parameters:parameters)
        for level in 1..<3 { try encode("uc_pyramid",command,textures:[refs[level-1],refs[level]]) }
        try finish(command,cancellation:cancellation);return result
    }
    private func fuse(_ work:FusionWorkspace,parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws {
        let command=try command()
        if parameters.size.w==1 {
            var protection=parameters
            protection.sensorNoise=SIMD4<Float>(parameters.sensorNoise.z,parameters.sensorNoise.w,0,0)
            try encode("uc_protect_bayer",command,textures:[work.sampleUpload,work.sample],parameters:protection)
        }
        try encode("uc_luma",command,textures:[parameters.flags.x==1 ? work.sampleUpload:work.sample,work.samplePyramid[0]],parameters:parameters)
        for level in 1..<3 { try encode("uc_pyramid",command,textures:[work.samplePyramid[level-1],work.samplePyramid[level]]) }
        for level in stride(from:2,through:0,by:-1) {
            try cancellation?.check()
            let r=work.referencePyramid[level],s=work.samplePyramid[level]
            let seed=level==2 ? r:work.regularizedFlow[level+1]
            var params=parameters;params.search=SIMD4<Int32>(level==2 ? 6:2,level==2 ? 0:1,parameters.search.z,level==0 ? 1:0)
            if parameters.size.w==1 {
                let divisor=UInt32(1<<level)
                params.roi=SIMD4(parameters.roi.x/divisor,parameters.roi.y/divisor,(parameters.roi.z+divisor-1)/divisor,(parameters.roi.w+divisor-1)/divisor)
            }
            try encode("uc_tile_flow",command,textures:[r,s,seed,work.flow[level]],parameters:params)
            try encode("uc_regularize_flow",command,textures:[r,s,work.flow[level],work.regularizedFlow[level]],parameters:params)
        }
        let next=1-work.slot
        try encode("uc_fuse_tiles",command,textures:[work.reference,work.sample,work.mean,work.weights[work.slot],work.regularizedFlow[0],work.means[next],work.weights[next],work.original,work.sampleUpload],parameters:parameters)
        try finish(command,cancellation:cancellation);work.slot=next
    }
    private func superResolve(_ work:FusionWorkspace,parameters:MetalFusionParameters,anchor:Bool,cancellation:ProcessingCancellation?) throws {
        let next=1-work.srSlot,command=try command()
        guard let tensor=work.structureTensor else { throw CameraFailure.message("Falta el tensor de reconstrucción.") }
        var params=parameters;params.search.y=anchor ? 0:1
        try encode("uc_fuse_super_res",command,textures:[work.reference,anchor ? work.reference:work.sample,
            work.srMeans[work.srSlot],work.srWeights[work.srSlot],work.regularizedFlow[0],work.srMeans[next],work.srWeights[next],work.original,anchor ? work.original:work.sampleUpload,tensor],parameters:params)
        try finish(command,cancellation:cancellation);work.srSlot=next
    }
    private func correctOptics(_ image:CIImage,lens:LensIdentity,center:SIMD2<Double>?,cancellation:ProcessingCancellation?) throws -> CIImage {
        let plan=LensChromaticPlan.estimate(image,lens:lens,context:context,center:center)
        guard plan.active else { return image }
        let e=image.extent,w=Int(e.width),h=Int(e.height)
        let normalized=image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY))
        let input=try load(normalized,width:w,height:h,cancellation:cancellation),output=try texture(w,h)
        var parameters=MetalFusionParameters();parameters.sr=plan.coefficients;parameters.control=plan.geometry(normalized.extent)
        let command=try command();try encode("uc_lca",command,textures:[input,output],parameters:parameters)
        try finish(command,cancellation:cancellation)
        guard let result=CIImage(mtlTexture:output,options:[.colorSpace:space]) else { throw CameraFailure.message("No se pudo corregir la óptica.") }
        return result.transformed(by:CGAffineTransform(translationX:e.minX,y:e.minY))
    }
    private func tone(_ image:CIImage,maximumGain:Double,night:Bool,options:ProcessingOptions,cancellation:ProcessingCancellation?) throws -> (sdr:CIImage,hdr:CIImage) {
        let extent=image.extent.integral,w=Int(extent.width),h=Int(extent.height)
        let normalized=image.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
        let input=try load(normalized,width:w,height:h,cancellation:cancellation),output=try texture(w,h)
        let base=try texture(max(1,(w+15)/16),max(1,(h+15)/16),format:.r16Float)
        let middleBase=try texture(max(1,base.width/2),max(1,base.height/2),format:.r16Float)
        let wideBase=try texture(max(1,middleBase.width/2),max(1,middleBase.height/2),format:.r16Float)
        let reduced=normalized.transformed(by:CGAffineTransform(scaleX:48/CGFloat(w),y:48/CGFloat(w)))
        let rw=max(1,Int(reduced.extent.width)),rh=max(1,Int(reduced.extent.height))
        var pixels=[Float](repeating:0,count:rw*rh*4)
        pixels.withUnsafeMutableBytes { context.render(reduced,toBitmap:$0.baseAddress!,rowBytes:rw*16,bounds:CGRect(x:0,y:0,width:rw,height:rh),format:.RGBAf,colorSpace:space) }
        var values=[Double]()
        for index in 0..<rw*rh {
            let r=pixels[index*4],g=pixels[index*4+1],b=pixels[index*4+2]
            let luminance:Float=r*0.2126+g*0.7152+b*0.0722
            let value=max(0.00001,Double(luminance))
            guard value.isFinite else { throw CameraFailure.message("Medición tonal no válida.") }
            values.append(value)
        }
        let plan=try NightTonePlan.make(luminances:values,maximumGain:maximumGain,highlightCompression:options.highlightCompression)
        var params=MetalFusionParameters();params.configure(options);params.control.y=Float(plan.gain);params.control.z=Float(plan.whitePoint)
        let shadowChroma=LensCalibration.profile(options.lens).shadowChroma
        let chroma=Float(options.chromaDenoise)
        params.tone=SIMD4<Float>(night ? 0.003*(1-Float(options.liftShadows)*0.75):0,
            night ? shadowChroma*(1+chroma*0.75):chroma*0.004,
            night ? 0.02+chroma*0.06:chroma*0.06,
            night ? NightChromaticityPlan.strength(pixels):0)
        let command=try command()
        try encode("uc_tone_luma",command,textures:[input,base])
        try encode("uc_pyramid",command,textures:[base,middleBase])
        try encode("uc_pyramid",command,textures:[middleBase,wideBase])
        try encode("uc_night_tone",command,textures:[input,base,wideBase,output],parameters:params)
        let hdrOutput=try options.preserveHDR ? texture(w,h):output
        if options.preserveHDR {
            params.finishing.z=1
            try encode("uc_night_tone",command,textures:[input,base,wideBase,hdrOutput],parameters:params)
        }
        try finish(command,cancellation:cancellation)
        guard let result=CIImage(mtlTexture:output,options:[.colorSpace:space]) else { throw CameraFailure.message("La GPU no devolvió la imagen tonal.") }
        guard let expanded=CIImage(mtlTexture:hdrOutput,options:[.colorSpace:space]) else { throw CameraFailure.message("No se pudo conservar el rango HDR.") }
        return (result,expanded)
    }

    func processRAW(_ frames:[SensorBayerFrame],referenceJPEG:Data,originalDNG:Data,options:ProcessingOptions,
                    cancellation:ProcessingCancellation?,progress:((String)->Void)?) throws -> CaptureResult {
        _=try options.validated()
        guard !frames.isEmpty,(2...16).contains(frames.count) else { throw CameraFailure.message("Metal RAW necesita entre 2 y 16 fotogramas.") }
        guard frames.allSatisfy({$0.exposure.isValid}),zip(frames,frames.dropFirst()).allSatisfy({$0.timestamp<$1.timestamp}) else { throw CameraFailure.message("La pila RAW no está ordenada temporalmente.") }
        guard let anchorIndex=SensorBayerFrame.referenceIndex(in:frames,hdr:options.hdrBracketing) else { throw CameraFailure.message("No hay una serie RAW con exposición coherente.") }
        let first=frames[anchorIndex]
        var recipe=options;recipe.lens=first.lens
        let effective=LensCalibration.profile(first.lens).recipe(recipe)
        let usable=frames.filter { options.hdrBracketing || $0.matchesExposure(of:first) }.count
        // Unsupported optical opcodes retain the ordinary sensor-coordinate path.
        let reconstruction=try? SuperResolutionPlan.make(first,count:usable)
        defer { frames.forEach { $0.discardResidentPages() } }
        let fused:(dng:Data,count:Int,center:SIMD2<Double>?)=try autoreleasepool {
        var params=MetalFusionParameters();params.configure(effective);params.size.w=1;params.flags.w=1;params.flags.x=options.astroCapture ? 1:0
        params.neutral=BayerSaturationPolicy.neutralPhases(first.calibration)
        params.roi=try BayerFusionRegion.make(width:first.width,height:first.height,geometry:first.calibration.geometry,zoom:first.zoom).vector
        params.tone.w=LensCalibration.profile(first.lens).motionTolerance
        params.luma=SIMD4<Float>(first.calibration.pattern[0]==1 ? 0.5:0,first.calibration.pattern[1]==1 ? 0.5:0,
            first.calibration.pattern[2]==1 ? 0.5:0,first.calibration.pattern[3]==1 ? 0.5:0)
        params.search.z=options.hdrBracketing ? 1:0
        let referenceNoise=SensorNoiseModel.coefficients(iso:first.exposure.iso,profile:first.noiseProfile,lens:first.lens)
        params.sensorNoise=SIMD4<Float>(referenceNoise.x,referenceNoise.y,referenceNoise.x,referenceNoise.y)
        let work=try autoreleasepool {
            let prepared=try protectedReference(first,preservePoints:options.astroCapture || reconstruction != nil,parameters:params,cancellation:cancellation)
            return try workspace(reference:prepared.clean,original:prepared.original,raw:true,parameters:params,cancellation:cancellation)
        }
        if let sr=reconstruction {
            params.flags.z=directionalSuperResolution ? 1:0
            work.structureTensor=try texture(first.width,first.height)
            params.sr=SIMD4(Float(sr.originX),Float(sr.originY),Float(sr.scaleX),Float(sr.scaleY))
            work.srMeans=try [texture(sr.width,sr.height),texture(sr.width,sr.height)]
            work.srWeights=try [texture(sr.width,sr.height),texture(sr.width,sr.height)]
            let clear=try command()
            try encode("uc_structure_tensor",clear,textures:[work.referencePyramid[0],work.structureTensor!],parameters:params)
            for target in [work.srMeans[0],work.srWeights[0]] { try encode("uc_clear",clear,textures:[target]) }
            try finish(clear,cancellation:cancellation)
            params.noise=SIMD4(referenceNoise.x*2,referenceNoise.y*2,0,0)
            try superResolve(work,parameters:params,anchor:true,cancellation:cancellation)
        }
        var accepted=1
        for (index,frame) in frames.enumerated() where index != anchorIndex {
            if !options.hdrBracketing && !frame.matchesExposure(of:first) { continue }
            try autoreleasepool {
            defer { frame.discardResidentPages() }
            try cancellation?.check()
            guard frame.lens==first.lens,frame.width==first.width,frame.height==first.height,frame.calibration==first.calibration,abs(frame.zoom-first.zoom)<0.001 else {
                throw CameraFailure.message("La pila RAW cambió de geometría, calibración, exposición o secuencia temporal.")
            }
            progress?("Metal RAW · alineando y fusionando \(index+1)/\(frames.count)…")
            let scale=first.exposure.product/frame.exposure.product
            guard scale.isFinite,(1.0/256...256).contains(scale) else { throw CameraFailure.message("Separación RAW fuera de rango.") }
            params.control.w=Float(scale);params.flags.y=accepted==1 ? 1:0
            let model=SensorNoiseModel.pair(reference:first.exposure,referenceProfile:first.noiseProfile,
                sample:frame.exposure,sampleProfile:frame.noiseProfile,scale:Float(scale),referenceLens:first.lens,sampleLens:frame.lens)
            // Unregistered edge residuals are scene motion, not read/shot noise.
            // RAW variance is evaluated per pixel by the calibrated GPU model.
            params.control.x=max(1e-8,model.x*0.18+model.y)
            params.noise=SIMD4<Float>(model.x,model.y,0,0)
            let sampleNoise=SensorNoiseModel.coefficients(iso:frame.exposure.iso,profile:frame.noiseProfile,lens:frame.lens)
            params.sensorNoise.z=sampleNoise.x;params.sensorNoise.w=sampleNoise.y
            _=try upload(frame,into:work.sampleUpload)
            try fuse(work,parameters:params,cancellation:cancellation)
            if reconstruction != nil { try superResolve(work,parameters:params,anchor:false,cancellation:cancellation) }
            accepted+=1
            }
        }
        let mosaic=reconstruction == nil ? work.mean:work.srMeans[work.srSlot]
        let calibration=reconstruction?.calibration(first.calibration) ?? first.calibration
        return (try FusedDNG.encode(quads:download(mosaic,cancellation:cancellation),width:mosaic.width,height:mosaic.height,calibration:calibration,noiseProfile:first.noiseProfile,zoom:reconstruction == nil ? first.zoom:1,capture:DNGCaptureInfo.read(reference:referenceJPEG,exposure:first.exposure)),accepted,calibration.developedOpticalCenter(width:mosaic.width*2,height:mosaic.height*2,zoom:reconstruction == nil ? first.zoom:1))
        }
        // Fusion textures are released before full-resolution demosaicing/tone.
        guard let decoder=CIRAWFilter(imageData:fused.dng,identifierHint:"com.adobe.raw-image") else { throw CameraFailure.message("No se pudo revelar el mosaico fusionado.") }
        decoder.isGamutMappingEnabled=false;decoder.boostAmount=0;decoder.boostShadowAmount=0;decoder.exposure=0;decoder.shadowBias=0
        if decoder.isLocalToneMapSupported { decoder.localToneMapAmount=0 }
        if decoder.isLuminanceNoiseReductionSupported { decoder.luminanceNoiseReductionAmount=0 }
        if decoder.isColorNoiseReductionSupported { decoder.colorNoiseReductionAmount=0.5 }
        guard let developed=decoder.outputImage else { throw CameraFailure.message("El DNG de trabajo no se pudo revelar.") }
        progress?("Metal RAW · tono y color…")
        let optical=options.lensCorrections ? try correctOptics(developed,lens:first.lens,center:fused.center,cancellation:cancellation):developed
        let mapped=try tone(optical,maximumGain:options.hdrBracketing ? 64:32,night:!options.hdrBracketing,options:effective,cancellation:cancellation)
        if options.nightStatic && !options.hdrBracketing && first.zoom<1.05,
           RAWRenderValidation.rejects(mapped.sdr,reference:referenceJPEG,context:context) {
            return CaptureResult(jpeg:referenceJPEG,reference:referenceJPEG,
                details:"Se conserva la foto de cámara: el revelado RAW no mantuvo el color.",
                mergedFrames:1,raw:originalDNG,source:"camera-reference-color-recovery")
        }
        let prepared=try JPEGRenderer.prepare(mapped.sdr,extent:mapped.sdr.extent,options:options,context:context,
            hdrSource:options.preserveHDR ? mapped.hdr:nil,hdrHeadroom:4,opticsApplied:options.lensCorrections,metalToneApplied:true)
        let jpeg=try JPEGRenderer.encode(prepared,options:options,context:context,metadataReference:referenceJPEG,frames:fused.count)
        let companion:Data?
        if options.saveFusedDNG {
            // A computational RAW needs its own same-geometry JPEG companion;
            // preserve the camera JPEG separately for comparison with the edit.
            companion=try JPEGRenderer.render(mapped.sdr,extent:mapped.sdr.extent,options:ProcessingOptions(),context:context).data
        } else { companion=nil }
        return CaptureResult(jpeg:jpeg.data,reference:referenceJPEG,details:"\(options.hdrBracketing ? "HDR RAW Metal":"Noche RAW Metal") · \(fused.count) tomas · \(reconstruction == nil ? "Bayer por teselas":"Super Res Bayer") · \(jpeg.width) × \(jpeg.height) px.",mergedFrames:fused.count,
            raw:options.selectedRAW(original:originalDNG,fused:fused.dng),source:"Bayer-Metal",rawIsFused:options.saveFusedDNG,rawCompanion:companion)
    }
    func processZSL(_ images:[CGImage],nativeJPEG:Data,options:ProcessingOptions,captureAngle:Double,previewMirrored:Bool,mirrorOutput:Bool,
                    cancellation:ProcessingCancellation?) throws -> CaptureResult {
        guard (3...8).contains(images.count),let native=CIImage(data:nativeJPEG,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("Falta el ancla nativa del ZSL híbrido.") }
        let e=native.extent,scale=min(1,1280/max(e.width,e.height))
        let w=max(1,Int(e.width*scale)),h=max(1,Int(e.height*scale))
        let reduced=native.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY)).transformed(by:CGAffineTransform(scaleX:CGFloat(w)/e.width,y:CGFloat(h)/e.height))
        let reference=try load(reduced,width:w,height:h,cancellation:cancellation)
        let work=try workspace(reference:reference,raw:false,parameters:MetalFusionParameters(),cancellation:cancellation)
        let patch=try noisePatch(reference)
        for image in images {
            try autoreleasepool {
                let oriented=HybridZSL.supportGeometry(CIImage(cgImage:image),angle:captureAngle,previewMirrored:previewMirrored,mirrorOutput:mirrorOutput)
                let normalized=oriented.transformed(by:CGAffineTransform(translationX:-oriented.extent.minX,y:-oriented.extent.minY))
                let aligned=normalized.transformed(by:CGAffineTransform(scaleX:CGFloat(w)/oriented.extent.width,y:CGFloat(h)/oriented.extent.height))
                let command=try command();context.render(aligned,to:work.sample,commandBuffer:command,bounds:CGRect(x:0,y:0,width:w,height:h),colorSpace:space)
                try finish(command,cancellation:cancellation)
                var params=MetalFusionParameters();params.configure(options);params.control.x=Self.noise(reference:patch,sample:try noisePatch(work.sample),channels:3)
                try fuse(work,parameters:params,cancellation:cancellation)
            }
        }
        guard let support=CIImage(mtlTexture:work.mean,options:[.colorSpace:space]) else { throw CameraFailure.message("La GPU no devolvió el soporte ZSL.") }
        let hybrid=HybridZSL.inject(native:native,support:support)
        let prepared=try JPEGRenderer.prepare(hybrid,extent:e,options:options,context:context,hdrSource:options.preserveHDR ? AdaptiveHDR.expanded(nativeJPEG):nil)
        let jpeg=try JPEGRenderer.encode(prepared,options:options,context:context,metadataReference:nativeJPEG,frames:images.count+1)
        return CaptureResult(jpeg:jpeg.data,reference:nativeJPEG,details:"HDR+ ZSL híbrido · ancla nativa \(jpeg.width) × \(jpeg.height) px · \(images.count) apoyos previos.",mergedFrames:images.count+1,source:"native-anchor-ZSL-Metal")
    }
    private static func noise(reference:Data,sample:Data,scale:Float=1,channels:Int=4) -> Float {
        let count=min(reference.count,sample.count)/2
        guard count>8 else { return 1e-7 }
        var residuals=[Float]();let step=max(4,(count/4000)/4*4)
        reference.withUnsafeBytes { a in sample.withUnsafeBytes { b in
            func value(_ bytes:UnsafeRawBufferPointer,_ i:Int)->Float { Float(Float16(bitPattern:UInt16(littleEndian:bytes.loadUnaligned(fromByteOffset:i*2,as:UInt16.self)))) }
            for i in stride(from:0,to:count-8,by:step) {
                for c in 0..<channels { residuals.append(abs((value(b,i+c)*scale-value(a,i+c))-(value(b,i+4+c)*scale-value(a,i+4+c)))) }
            }
        } }
        residuals.sort();let sigma=residuals[residuals.count/2]/1.3489795
        return min(0.01,max(1e-7,sigma*sigma))
    }
}

/// Compare the scene before user colour/LUT adjustments. This rejects severe
/// global decode failures, not ordinary tone differences or coloured subjects.
/// The sensor original and camera JPEG remain available for a future re-edit.
enum RAWRenderValidation {
    static func rejects(_ image:CIImage,reference:Data,context:CIContext)->Bool {
        guard let camera=CIImage(data:reference,options:[.applyOrientationProperty:true]) else { return false }
        func pixels(_ source:CIImage)->[Float] {
            let e=source.extent
            let small=source.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY))
                .transformed(by:CGAffineTransform(scaleX:48/e.width,y:48/e.height))
            var p=[Float](repeating:0,count:48*48*4)
            p.withUnsafeMutableBytes { context.render(small,toBitmap:$0.baseAddress!,rowBytes:48*16,bounds:CGRect(x:0,y:0,width:48,height:48),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) }
            return p
        }
        return rejects(rendered:pixels(image),reference:pixels(camera))
    }
    static func rejects(rendered:[Float],reference:[Float])->Bool {
        guard rendered.count==reference.count,rendered.count>=64,rendered.count%4==0 else { return false }
        var neutral=0,magenta=0,dark=0,washed=0,invalid=0
        for i in stride(from:0,to:rendered.count,by:4) {
            let a=SIMD3(reference[i],reference[i+1],reference[i+2]),b=SIMD3(rendered[i],rendered[i+1],rendered[i+2])
            guard b.x.isFinite,b.y.isFinite,b.z.isFinite else { invalid+=1;continue }
            let al=(a.x+a.y+a.z)/3,bl=(b.x+b.y+b.z)/3
            if al>=0 && al<0.65 && max(a.x,a.y,a.z)-min(a.x,a.y,a.z)<max(0.02,al*0.25) {
                neutral+=1
                let minimumChroma:Float=al<=0.015 ? 0.15:0.03
                if min(b.x,b.z)>max(minimumChroma,b.y*1.55) { magenta+=1 }
            }
            if al<0.2 { dark+=1;if bl>0.8 { washed+=1 } }
        }
        return invalid>rendered.count/64 || (neutral>=32 && magenta*3>neutral) || (dark>=32 && washed*4>dark*3)
    }
}
