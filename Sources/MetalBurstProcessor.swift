import CoreImage
import Metal

private struct MetalFusionParameters {
    var size=SIMD4<UInt32>(0,0,16,0)
    var search=SIMD4<Int32>(0,0,0,0)
    var control=SIMD4<Float>(0.000004,1,4,1)
    var luma=SIMD4<Float>(0.2126,0.7152,0.0722,0)
}

/// Own compute kernels, not the private Apple ISP or Google's proprietary HDR+.
/// The reference stays fixed; each additional frame is materialized and retired
/// before the next one. All methods run on the photo-processing queue.
final class MetalBurstProcessor {
    private let device:MTLDevice,queue:MTLCommandQueue
    private let context:CIContext
    private let kernels:[String:MTLComputePipelineState]
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw CameraFailure.message("Metal no está disponible.") }
        let library=try device.makeDefaultLibrary(bundle:Bundle.main)
        var kernels=[String:MTLComputePipelineState]()
        for name in ["uc_pyramid","uc_tile_flow","uc_fuse_tiles","uc_night_tone"] {
            guard let function=library.makeFunction(name:name) else { throw CameraFailure.message("Falta un shader del procesador Metal.") }
            kernels[name]=try device.makeComputePipelineState(function:function)
        }
        self.device=device;self.queue=queue;self.kernels=kernels
        context=CIContext(mtlDevice:device,options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates:false])
    }
    private func texture(_ width:Int,_ height:Int,format:MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=format == .rgba16Float ? [.shaderRead,.shaderWrite,.renderTarget]:[.shaderRead,.shaderWrite]
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
    private func upload(_ frame:SensorBayerFrame) throws -> MTLTexture {
        let texture=try texture(frame.width,frame.height)
        frame.quads.withUnsafeBytes { bytes in
            texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:frame.width*8)
        };return texture
    }
    private func download(_ texture:MTLTexture) -> Data {
        var data=Data(count:texture.width*texture.height*8)
        data.withUnsafeMutableBytes { bytes in texture.getBytes(bytes.baseAddress!,bytesPerRow:texture.width*8,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) };return data
    }
    private func noisePatch(_ texture:MTLTexture) -> Data {
        let w=min(96,texture.width),h=min(64,texture.height)
        var bytes=Data(count:w*h*8)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D((texture.width-w)/2,(texture.height-h)/2,w,h),mipmapLevel:0) };return bytes
    }
    private func fuse(reference:MTLTexture,mean:MTLTexture,weights:MTLTexture,sample:MTLTexture,
                      parameters:MetalFusionParameters,cancellation:ProcessingCancellation?) throws -> (MTLTexture,MTLTexture) {
        var refs=[reference],samples=[sample];let command=try command()
        for _ in 0..<2 {
            let r=refs.last!,s=samples.last!,w=max(1,r.width/2),h=max(1,r.height/2)
            let nextR=try texture(w,h),nextS=try texture(w,h)
            try encode("uc_pyramid",command,textures:[r,nextR]);try encode("uc_pyramid",command,textures:[s,nextS])
            refs.append(nextR);samples.append(nextS)
        }
        var seed:MTLTexture?
        for level in stride(from:2,through:0,by:-1) {
            try cancellation?.check()
            let r=refs[level],s=samples[level],flow=try texture((r.width+15)/16,(r.height+15)/16,format:.rgba32Float)
            var params=parameters;params.search=SIMD4<Int32>(level==2 ? 6:2,seed==nil ? 0:1,parameters.search.z,level==0 ? 1:0)
            try encode("uc_tile_flow",command,textures:[r,s,seed ?? r,flow],parameters:params);seed=flow
        }
        let nextMean=try texture(reference.width,reference.height),nextWeights=try texture(reference.width,reference.height,format:.r16Float)
        // The last texture defines the dispatch size; both outputs share geometry.
        try encode("uc_fuse_tiles",command,textures:[reference,sample,mean,weights,seed!,nextMean,nextWeights],parameters:parameters)
        try finish(command,cancellation:cancellation);return (nextMean,nextWeights)
    }
    private func initialWeights(width:Int,height:Int) throws -> MTLTexture {
        let weights=try texture(width,height,format:.r16Float)
        let ones=[UInt16](repeating:Float16(1).bitPattern,count:width*height)
        ones.withUnsafeBufferPointer { weights.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*2) };return weights
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
        let anchorIndex=options.hdrBracketing ? frames.indices.min(by:{frames[$0].exposure.product<frames[$1].exposure.product})!:0
        let first=frames[anchorIndex]
        guard frames.allSatisfy({$0.exposure.isValid}),zip(frames,frames.dropFirst()).allSatisfy({$0.timestamp<$1.timestamp}) else { throw CameraFailure.message("La pila RAW no está ordenada temporalmente.") }
        let reference=try upload(first);var mean=reference,weights=try initialWeights(width:first.width,height:first.height)
        var params=MetalFusionParameters();params.size.w=1
        params.luma=SIMD4<Float>(first.calibration.pattern[0]==1 ? 0.5:0,first.calibration.pattern[1]==1 ? 0.5:0,
            first.calibration.pattern[2]==1 ? 0.5:0,first.calibration.pattern[3]==1 ? 0.5:0)
        params.search.z=options.hdrBracketing ? 1:0
        for (index,frame) in frames.enumerated() where index != anchorIndex {
            try cancellation?.check()
            guard frame.width==first.width,frame.height==first.height,frame.calibration==first.calibration,
                  options.hdrBracketing || (abs(frame.exposure.seconds/first.exposure.seconds-1)<0.05 && abs(frame.exposure.iso/first.exposure.iso-1)<0.05) else {
                throw CameraFailure.message("La pila RAW cambió de geometría, calibración, exposición o secuencia temporal.")
            }
            progress?("Metal RAW · alineando y fusionando \(index+1)/\(frames.count)…")
            let scale=first.exposure.product/frame.exposure.product
            guard scale.isFinite,(1.0/256...256).contains(scale) else { throw CameraFailure.message("Separación RAW fuera de rango.") }
            params.control.w=Float(scale)
            params.control.x=Self.noise(reference:first.quads,sample:frame.quads,scale:Float(scale))
            (mean,weights)=try autoreleasepool { try fuse(reference:reference,mean:mean,weights:weights,sample:upload(frame),parameters:params,cancellation:cancellation) }
        }
        let dng=try FusedDNG.encode(quads:download(mean),width:first.width,height:first.height,calibration:first.calibration)
        guard let decoder=CIRAWFilter(imageData:dng,identifierHint:"com.adobe.raw-image") else { throw CameraFailure.message("No se pudo revelar el mosaico fusionado.") }
        decoder.isGamutMappingEnabled=false;decoder.boostAmount=0;decoder.boostShadowAmount=0;decoder.baselineExposure=0;decoder.exposure=0;decoder.shadowBias=0
        if decoder.isLocalToneMapSupported { decoder.localToneMapAmount=0 }
        if decoder.isLuminanceNoiseReductionSupported { decoder.luminanceNoiseReductionAmount=0 }
        guard let developed=decoder.outputImage else { throw CameraFailure.message("El DNG de trabajo no se pudo revelar.") }
        progress?("Metal RAW · tono y color…")
        let mapped=try tone(developed,maximumGain:options.hdrBracketing ? 64:32,cancellation:cancellation)
        let jpeg=try JPEGRenderer.render(mapped.sdr,extent:mapped.sdr.extent,options:options,context:context,hdrSource:options.preserveHDR ? mapped.hdr:nil,metadataReference:referenceJPEG,frames:frames.count)
        return CaptureResult(jpeg:jpeg.data,reference:referenceJPEG,details:"\(options.hdrBracketing ? "HDR RAW Metal":"Noche RAW Metal") · \(frames.count) tomas · Bayer por teselas · \(jpeg.width) × \(jpeg.height) px.",mergedFrames:frames.count,raw:originalDNG,source:"Bayer-Metal")
    }
    func processZSL(_ images:[CGImage],options:ProcessingOptions,captureAngle:Double,unmirror:Bool,
                    cancellation:ProcessingCancellation?) throws -> CaptureResult {
        guard (3...8).contains(images.count),let first=images.last else { throw CameraFailure.message("El búfer ZSL todavía no está preparado.") }
        let reference=try load(CIImage(cgImage:first),width:first.width,height:first.height,cancellation:cancellation)
        var mean=reference,weights=try initialWeights(width:first.width,height:first.height)
        let referenceNoise=noisePatch(reference)
        for image in images.dropLast().reversed() {
            guard image.width==first.width,image.height==first.height else { throw CameraFailure.message("Cambió la geometría del búfer ZSL.") }
            (mean,weights)=try autoreleasepool {
                let sample=try load(CIImage(cgImage:image),width:image.width,height:image.height,cancellation:cancellation)
                var params=MetalFusionParameters();params.control.x=Self.noise(reference:referenceNoise,sample:noisePatch(sample),channels:3)
                return try fuse(reference:reference,mean:mean,weights:weights,sample:sample,parameters:params,cancellation:cancellation)
            }
        }
        guard var result=CIImage(mtlTexture:mean,options:[.colorSpace:space]) else { throw CameraFailure.message("El búfer ZSL no produjo imagen.") }
        var original=CIImage(cgImage:first)
        func geometry(_ image:CIImage) -> CIImage {
            let rotated=image.transformed(by:CGAffineTransform(rotationAngle:CGFloat((90-captureAngle)*Double.pi/180)))
            var image=rotated.transformed(by:CGAffineTransform(translationX:-rotated.extent.minX,y:-rotated.extent.minY))
            if unmirror { image=image.transformed(by:CGAffineTransform(a:-1,b:0,c:0,d:1,tx:image.extent.width,ty:0)) };return image
        }
        result=geometry(result);original=geometry(original)
        let jpeg=try JPEGRenderer.render(result,extent:result.extent,options:options,context:context,frames:images.count)
        let referenceJPEG=try JPEGRenderer.render(original,extent:original.extent,options:ProcessingOptions(),context:context)
        return CaptureResult(jpeg:jpeg.data,reference:referenceJPEG.data,details:"ZSL del visor · \(images.count) fotogramas previos · \(jpeg.width) × \(jpeg.height) px · RGB procesado, sin RAW ni recuperación de luces recortadas.",mergedFrames:images.count,source:"preview-ZSL-Metal")
    }
    private static func noise(reference:Data,sample:Data,scale:Float=1,channels:Int=4) -> Float {
        let count=min(reference.count,sample.count)/2
        guard count>8 else { return 0.000004 }
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
