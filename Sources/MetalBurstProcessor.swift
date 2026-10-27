import CoreImage
import Metal

private struct MetalFusionParameters {
    var size=SIMD4<UInt32>(0,0,16,0)
    var search=SIMD4<Int32>(0,0,0,0)
    var control=SIMD4<Float>(1e-7,1,4,1)
    var luma=SIMD4<Float>(0.2126,0.7152,0.0722,0)
    var noise=SIMD4<Float>(0,0,0,0)
}

/// Own compute kernels, not the private Apple ISP or Google's proprietary HDR+.
/// The reference stays fixed; each additional frame is materialized and retired
/// before the next one. All methods run on the photo-processing queue.
final class MetalBurstProcessor {
    /// One workspace per burst. The reference pyramid is immutable; sample,
    /// flow and ping-pong accumulators are reused after command completion.
    private final class FusionWorkspace {
        let reference:MTLTexture,sample:MTLTexture
        let referencePyramid:[MTLTexture],samplePyramid:[MTLTexture],flow:[MTLTexture]
        let means:[MTLTexture],weights:[MTLTexture]
        var slot=0
        var mean:MTLTexture { means[slot] }
        init(reference:MTLTexture,sample:MTLTexture,referencePyramid:[MTLTexture],samplePyramid:[MTLTexture],flow:[MTLTexture],means:[MTLTexture],weights:[MTLTexture]) {
            self.reference=reference;self.sample=sample;self.referencePyramid=referencePyramid
            self.samplePyramid=samplePyramid;self.flow=flow;self.means=means;self.weights=weights
        }
    }
    private let device:MTLDevice,queue:MTLCommandQueue
    private let context:CIContext
    private let kernels:[String:MTLComputePipelineState]
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw CameraFailure.message("Metal no está disponible.") }
        let library=try device.makeDefaultLibrary(bundle:Bundle.main)
        var kernels=[String:MTLComputePipelineState]()
        for name in ["uc_initial_weights","uc_luma","uc_pyramid","uc_tile_flow","uc_fuse_tiles","uc_night_tone"] {
            guard let function=library.makeFunction(name:name) else { throw CameraFailure.message("Falta un shader del procesador Metal.") }
            kernels[name]=try device.makeComputePipelineState(function:function)
        }
        self.device=device;self.queue=queue;self.kernels=kernels
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
        let target=textures.last!,width=state.threadExecutionWidth,height=max(1,min(8,state.maxTotalThreadsPerThreadgroup/width))
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
    private func workspace(reference:MTLTexture,raw:Bool,parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws -> FusionWorkspace {
        let w=reference.width,h=reference.height
        var refs=[MTLTexture](),samples=[MTLTexture](),flows=[MTLTexture]()
        var width=w,height=h
        for _ in 0..<3 {
            refs.append(try texture(width,height,format:.r16Float))
            samples.append(try texture(width,height,format:.r16Float))
            flows.append(try texture((width+15)/16,(height+15)/16,format:.rgba32Float))
            width=max(1,width/2);height=max(1,height/2)
        }
        let means=try [texture(w,h),texture(w,h)]
        let weights=try [texture(w,h,format:.r16Float),texture(w,h,format:.r16Float)]
        let sample=try texture(w,h,storage:raw ? .shared:.private)
        let result=FusionWorkspace(reference:reference,sample:sample,referencePyramid:refs,samplePyramid:samples,flow:flows,means:means,weights:weights)
        let command=try command()
        guard let blit=command.makeBlitCommandEncoder() else { throw CameraFailure.message("No se pudo preparar la acumulación.") }
        blit.copy(from:reference,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),
            to:means[0],destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        blit.endEncoding()
        try encode("uc_initial_weights",command,textures:[weights[0]])
        try encode("uc_luma",command,textures:[reference,refs[0]],parameters:parameters)
        for level in 1..<3 { try encode("uc_pyramid",command,textures:[refs[level-1],refs[level]]) }
        try finish(command,cancellation:cancellation);return result
    }
    private func fuse(_ work:FusionWorkspace,parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws {
        let command=try command()
        try encode("uc_luma",command,textures:[work.sample,work.samplePyramid[0]],parameters:parameters)
        for level in 1..<3 { try encode("uc_pyramid",command,textures:[work.samplePyramid[level-1],work.samplePyramid[level]]) }
        for level in stride(from:2,through:0,by:-1) {
            try cancellation?.check()
            let r=work.referencePyramid[level],s=work.samplePyramid[level]
            let seed=level==2 ? r:work.flow[level+1]
            var params=parameters;params.search=SIMD4<Int32>(level==2 ? 6:2,level==2 ? 0:1,parameters.search.z,level==0 ? 1:0)
            try encode("uc_tile_flow",command,textures:[r,s,seed,work.flow[level]],parameters:params)
        }
        let next=1-work.slot
        try encode("uc_fuse_tiles",command,textures:[work.reference,work.sample,work.mean,work.weights[work.slot],work.flow[0],work.means[next],work.weights[next]],parameters:parameters)
        try finish(command,cancellation:cancellation);work.slot=next
    }
    private func tone(_ image:CIImage,maximumGain:Double,cancellation:ProcessingCancellation?) throws -> (sdr:CIImage,hdr:CIImage) {
        let extent=image.extent.integral,w=Int(extent.width),h=Int(extent.height)
        let normalized=image.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
        let input=try load(normalized,width:w,height:h,cancellation:cancellation),output=try texture(w,h)
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
        values.sort();let middle=values[values.count/2],high=values[min(values.count-1,Int(Double(values.count)*0.98))]
        var params=MetalFusionParameters();params.control.y=Float(min(maximumGain,max(1,0.18/middle)));params.control.z=Float(max(1,high*Double(params.control.y)))
        let command=try command();try encode("uc_night_tone",command,textures:[input,output],parameters:params);try finish(command,cancellation:cancellation)
        guard let result=CIImage(mtlTexture:output,options:[.colorSpace:space]) else { throw CameraFailure.message("La GPU no devolvió la imagen tonal.") }
        let expanded=normalized.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:log2(Double(params.control.y))])
        return (result,expanded)
    }

    func processRAW(_ frames:[SensorBayerFrame],referenceJPEG:Data,originalDNG:Data,options:ProcessingOptions,
                    cancellation:ProcessingCancellation?,progress:((String)->Void)?) throws -> CaptureResult {
        guard !frames.isEmpty,(2...16).contains(frames.count) else { throw CameraFailure.message("Metal RAW necesita entre 2 y 16 fotogramas.") }
        guard frames.allSatisfy({$0.exposure.isValid}),zip(frames,frames.dropFirst()).allSatisfy({$0.timestamp<$1.timestamp}) else { throw CameraFailure.message("La pila RAW no está ordenada temporalmente.") }
        guard let anchorIndex=SensorBayerFrame.referenceIndex(in:frames,hdr:options.hdrBracketing) else { throw CameraFailure.message("No hay una serie RAW con exposición coherente.") }
        let first=frames[anchorIndex]
        defer { frames.forEach { $0.discardResidentPages() } }
        let fused:(dng:Data,count:Int)=try autoreleasepool {
        let reference=try upload(first)
        var params=MetalFusionParameters();params.size.w=1
        params.luma=SIMD4<Float>(first.calibration.pattern[0]==1 ? 0.5:0,first.calibration.pattern[1]==1 ? 0.5:0,
            first.calibration.pattern[2]==1 ? 0.5:0,first.calibration.pattern[3]==1 ? 0.5:0)
        params.search.z=options.hdrBracketing ? 1:0
        let work=try workspace(reference:reference,raw:true,parameters:params,cancellation:cancellation)
        var accepted=1
        for (index,frame) in frames.enumerated() where index != anchorIndex {
            if !options.hdrBracketing && !frame.matchesExposure(of:first) { continue }
            try autoreleasepool {
            defer { frame.discardResidentPages() }
            try cancellation?.check()
            guard frame.width==first.width,frame.height==first.height,frame.calibration==first.calibration else {
                throw CameraFailure.message("La pila RAW cambió de geometría, calibración, exposición o secuencia temporal.")
            }
            progress?("Metal RAW · alineando y fusionando \(index+1)/\(frames.count)…")
            let scale=first.exposure.product/frame.exposure.product
            guard scale.isFinite,(1.0/256...256).contains(scale) else { throw CameraFailure.message("Separación RAW fuera de rango.") }
            params.control.w=Float(scale)
            let model=SensorNoiseModel.pair(reference:first.exposure,referenceProfile:first.noiseProfile,
                sample:frame.exposure,sampleProfile:frame.noiseProfile,scale:Float(scale))
            let expected=max(1e-8,model.x*0.18+model.y)
            let measured=Self.noise(reference:first.quads,sample:frame.quads,scale:Float(scale))
            params.control.x=max(expected,min(measured,expected*4))
            params.noise=SIMD4<Float>(model.x,model.y,0,0)
            _=try upload(frame,into:work.sample)
            try fuse(work,parameters:params,cancellation:cancellation)
            accepted+=1
            }
        }
        return (try FusedDNG.encode(quads:download(work.mean,cancellation:cancellation),width:first.width,height:first.height,calibration:first.calibration,noiseProfile:first.noiseProfile),accepted)
        }
        // Fusion textures are released before full-resolution demosaicing/tone.
        guard let decoder=CIRAWFilter(imageData:fused.dng,identifierHint:"com.adobe.raw-image") else { throw CameraFailure.message("No se pudo revelar el mosaico fusionado.") }
        decoder.isGamutMappingEnabled=false;decoder.boostAmount=0;decoder.boostShadowAmount=0;decoder.exposure=0;decoder.shadowBias=0
        if decoder.isLocalToneMapSupported { decoder.localToneMapAmount=0 }
        if decoder.isLuminanceNoiseReductionSupported { decoder.luminanceNoiseReductionAmount=0 }
        guard let developed=decoder.outputImage else { throw CameraFailure.message("El DNG de trabajo no se pudo revelar.") }
        progress?("Metal RAW · tono y color…")
        let mapped=try tone(developed,maximumGain:options.hdrBracketing ? 64:32,cancellation:cancellation)
        let jpeg=try JPEGRenderer.render(mapped.sdr,extent:mapped.sdr.extent,options:options,context:context,hdrSource:options.preserveHDR ? mapped.hdr:nil,metadataReference:referenceJPEG,frames:fused.count)
        return CaptureResult(jpeg:jpeg.data,reference:referenceJPEG,details:"\(options.hdrBracketing ? "HDR RAW Metal":"Noche RAW Metal") · \(fused.count) tomas · Bayer por teselas · \(jpeg.width) × \(jpeg.height) px.",mergedFrames:fused.count,raw:originalDNG,source:"Bayer-Metal")
    }
    func processZSL(_ images:[CGImage],options:ProcessingOptions,captureAngle:Double,previewMirrored:Bool,mirrorOutput:Bool,
                    cancellation:ProcessingCancellation?) throws -> CaptureResult {
        guard (3...8).contains(images.count),let first=images.last else { throw CameraFailure.message("El búfer ZSL todavía no está preparado.") }
        let reference=try load(CIImage(cgImage:first),width:first.width,height:first.height,cancellation:cancellation)
        let work=try workspace(reference:reference,raw:false,parameters:MetalFusionParameters(),cancellation:cancellation)
        let referenceNoise=try noisePatch(reference)
        for image in images.dropLast().reversed() {
            guard image.width==first.width,image.height==first.height else { throw CameraFailure.message("Cambió la geometría del búfer ZSL.") }
            try autoreleasepool {
                let command=try command()
                context.render(CIImage(cgImage:image),to:work.sample,commandBuffer:command,bounds:CGRect(x:0,y:0,width:image.width,height:image.height),colorSpace:space)
                try finish(command,cancellation:cancellation)
                var params=MetalFusionParameters();params.control.x=Self.noise(reference:referenceNoise,sample:try noisePatch(work.sample),channels:3)
                try fuse(work,parameters:params,cancellation:cancellation)
            }
        }
        guard var result=CIImage(mtlTexture:work.mean,options:[.colorSpace:space]) else { throw CameraFailure.message("El búfer ZSL no produjo imagen.") }
        var original=CIImage(cgImage:first)
        func geometry(_ image:CIImage) -> CIImage {
            // Undo the portrait preview mirror before rotating; then apply the
            // requested output mirror in the final image's coordinate system.
            var image=previewMirrored ? image.oriented(.upMirrored):image
            switch Int(captureAngle) {
            case 0:image=image.oriented(.left)
            case 180:image=image.oriented(.right)
            case 270:image=image.oriented(.down)
            default:break
            }
            if mirrorOutput { image=image.oriented(.upMirrored) };return image
        }
        result=geometry(result);original=geometry(original)
        let jpeg=try JPEGRenderer.render(result,extent:result.extent,options:options,context:context,frames:images.count)
        let referenceJPEG=try JPEGRenderer.render(original,extent:original.extent,options:ProcessingOptions(),context:context)
        return CaptureResult(jpeg:jpeg.data,reference:referenceJPEG.data,details:"ZSL del visor · \(images.count) fotogramas previos · \(jpeg.width) × \(jpeg.height) px · RGB procesado, sin RAW ni recuperación de luces recortadas.",mergedFrames:images.count,source:"preview-ZSL-Metal")
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
