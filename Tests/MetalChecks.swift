import Foundation
import CoreImage
import Metal
import Darwin

@main struct MetalChecks {
    static func require(_ ok:Bool,_ message:String) throws { if !ok { throw CameraFailure.message(message) } }
    static func main() {
        do { try run() } catch { fputs("Metal checks failed: \(error)\n",stderr);exit(1) }
    }
    static func run() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
            print("Metal execution unavailable on this macOS runner; host math and native shader compilation remain separate checks.");return
        }
        let header=try String(contentsOfFile:"Sources/FusionMath.h",encoding:.utf8)
        let source=try String(contentsOfFile:"Sources/ComputationalCamera.metal",encoding:.utf8).replacingOccurrences(of:"#include \"FusionMath.h\"",with:header)
        let library=try device.makeLibrary(source:source,options:nil)
        func texture(_ w:Int,_ h:Int,_ format:MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
            guard let result=device.makeTexture(descriptor:d) else { throw CameraFailure.message("No test texture") };return result
        }
        func upload(_ values:[Float],_ target:MTLTexture) {
            let halves=values.map{Float16($0).bitPattern}
            halves.withUnsafeBytes { target.replace(region:MTLRegionMake2D(0,0,target.width,target.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:target.width*8) }
        }
        func read(_ target:MTLTexture)->[Float] {
            var halves=[UInt16](repeating:0,count:target.width*target.height*4)
            halves.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:target.width*8,from:MTLRegionMake2D(0,0,target.width,target.height),mipmapLevel:0) }
            return halves.map { Float(Float16(bitPattern:$0)) }
        }
        func execute(_ name:String,_ textures:[MTLTexture],_ params:MetalFusionParameters,_ target:MTLTexture) throws {
            let state=try device.makeComputePipelineState(function:library.makeFunction(name:name)!)
            let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(state)
            for (i,t) in textures.enumerated() { encoder.setTexture(t,index:i) }
            var p=params;encoder.setBytes(&p,length:MemoryLayout<MetalFusionParameters>.stride,index:0)
            encoder.dispatchThreads(MTLSize(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            try require(command.status == .completed,"GPU did not complete \(name): \(String(describing:command.error))")
        }
        let w=40,h=24,shifts:[SIMD2<Float>]=[SIMD2(0,0),SIMD2(0.5,0),SIMD2(0,0.5),SIMD2(0.5,0.5)]
        func scene(_ x:Float,_ y:Float)->Float { 0.4+0.2*cos(2*Float.pi*(0.65*x+0.08*y)) }
        func samples(_ shift:SIMD2<Float>)->[Float] {
            var values=[Float](repeating:0,count:w*h*4)
            for y in 0..<h { for x in 0..<w {
                let i=(y*w+x)*4;values[i]=scene(Float(x)-shift.x,Float(y)-shift.y)
                values[i+1]=0.15;values[i+2]=0.35;values[i+3]=0.65
            } };return values
        }
        let tensor=try texture(w,h)
        upload([Float](repeating:0,count:w*h*4),tensor)
        let reference=try texture(w,h),sample=try texture(w,h),flow=try texture(3,2,.rgba32Float)
        upload(samples(.zero),reference)
        let means=try [texture(w*2,h*2),texture(w*2,h*2)],weights=try [texture(w*2,h*2),texture(w*2,h*2)]
        let zeros=[Float](repeating:0,count:w*h*16);upload(zeros,means[0]);upload(zeros,weights[0])
        var p=MetalFusionParameters();p.size.w=1;p.sr=SIMD4(0,0,2,2);p.noise=SIMD4(0,0.001,0,0)
        var slot=0,single=[Float]()
        for (index,shift) in shifts.enumerated() {
            upload(samples(shift),sample)
            var vectors=[Float]()
            for _ in 0..<6 { vectors += [shift.x,shift.y,0,1] }
            vectors.withUnsafeBytes { flow.replace(region:MTLRegionMake2D(0,0,3,2),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:3*16) }
            p.search.y=index==0 ? 0:1;let next=1-slot
            try execute("uc_fuse_super_res",[reference,sample,means[slot],weights[slot],flow,means[next],weights[next],reference,sample,tensor],p,means[next])
            slot=next;if index==0 { single=read(means[slot]) }
        }
        let result=read(means[slot]);var before:Float=0,after:Float=0
        for y in 6..<h*2-6 { for x in 6..<w*2-6 {
            let truth=scene(UCSRPosition(Float(x),0.25,0,2),UCSRPosition(Float(y),0.25,0,2)),i=(y*w*2+x)*4
            before+=pow(single[i]-truth,2);after+=pow(result[i]-truth,2)
            try require(abs(result[i+1]-0.15)<0.002 && abs(result[i+3]-0.65)<0.002,"Super Res mixed CFA phases")
        } }
        try require(after<before*0.85,"Production GPU SR failed to recover shifted frequencies beyond the native quad Nyquist limit")
        // Real protection + real fusion shaders: one shifted star, one fixed
        // sensor impulse, using the exact same flow and original/clean planes.
        let n=32,a=try texture(32,32),b=try texture(32,32),cleanA=try texture(32,32),cleanB=try texture(32,32)
        var rawA=[Float](repeating:0.02,count:n*n*4),rawB=rawA
        rawA[(16*n+12)*4]=0.7;rawB[(16*n+13)*4]=0.7
        rawA[(16*n+24)*4]=0.7;rawB[(16*n+24)*4]=0.7
        upload(rawA,a);upload(rawB,b)
        var params=MetalFusionParameters();params.size.w=1;params.flags.y=1;params.roi=SIMD4(0,0,32,32);params.sensorNoise=SIMD4(0,1e-6,0,1e-6);params.noise=SIMD4(0,2e-6,0,0)
        try execute("uc_protect_bayer",[a,cleanA],params,cleanA);try execute("uc_protect_bayer",[b,cleanB],params,cleanB)
        let counts=try texture(n,n,.r16Float),nextCounts=try texture(n,n,.r16Float),output=try texture(n,n),motion=try texture(2,2,.rgba32Float)
        try execute("uc_initial_weights",[counts],params,counts)
        let movement:[Float]=[1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1]
        movement.withUnsafeBytes { motion.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32) }
        try execute("uc_fuse_tiles",[cleanA,cleanB,cleanA,counts,motion,output,nextCounts,a,b],params,output)
        let fused=read(output)
        try require(fused[(16*n+12)*4]>0.6,"Production temporal protection erased the aligned star")
        try require(fused[(16*n+24)*4]<0.05,"Production temporal protection retained a fixed sensor impulse")
        let guide=try texture(32,32,.r16Float),ellipse=try texture(32,32)
        var diagonal=[UInt16](repeating:0,count:32*32)
        for y in 0..<32 { for x in 0..<32 { diagonal[y*32+x]=Float16(x>y ? 0.8:0.05).bitPattern } }
        diagonal.withUnsafeBytes { guide.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:64) }
        try execute("uc_structure_tensor",[guide,ellipse],params,ellipse)
        let field=read(ellipse),center=(16*32+16)*4
        let jxx=field[center],jxy=field[center+1],jyy=field[center+2]
        try require(jxx*jyy-jxy*jxy>0 && jxy < -1 && field[center+3]>0.5,"Structure tensor did not produce a bounded positive ellipse aligned with a diagonal edge")
        let lensInput=try texture(32,32),lensOutput=try texture(32,32)
        var lensPixels=[Float](repeating:1,count:32*32*4)
        for y in 0..<32 { for x in 0..<32 { let i=(y*32+x)*4;lensPixels[i]=Float(x)/32;lensPixels[i+1]=0.5;lensPixels[i+2]=Float(y)/32 } }
        upload(lensPixels,lensInput)
        var optical=MetalFusionParameters();optical.control=SIMD4(16,16,sqrt(512),1);optical.sr=SIMD4(0.1,0.02,-0.08,0.01)
        try execute("uc_lca",[lensInput,lensOutput],optical,lensOutput)
        let corrected=read(lensOutput),i=(20*32+25)*4,r2:Float=(9.5*9.5+4.5*4.5)/512
        let expectedR:Float=(25+9.5*(0.1*r2+0.02*r2*r2))/32
        let expectedB:Float=(20+4.5*(-0.08*r2+0.01*r2*r2))/32
        try require(abs(corrected[i]-expectedR)<0.002 && abs(corrected[i+2]-expectedB)<0.002 && corrected[i+1]==0.5,"Metal radial LCA disagreed with the calibrated RGB warp / moved green")
        // Differential Astro flow: a supported sky displacement must not be
        // replaced by three confident stationary landscape neighbours.
        func scalar(_ values:[Float],_ target:MTLTexture) {
            let halves=values.map{Float16($0).bitPattern}
            halves.withUnsafeBytes { target.replace(region:MTLRegionMake2D(0,0,target.width,target.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:target.width*2) }
        }
        let skyGuide=try texture(48,48,.r16Float),shiftedSky=try texture(48,48,.r16Float)
        var skyValues=[Float](repeating:0,count:48*48),shiftedValues=skyValues
        for y in 0..<48 { for x in 0..<48 {
            let dx=Float(x)-24,dy=Float(y)-24
            skyValues[y*48+x]=0.01+0.6*exp(-(dx*dx+dy*dy)/0.85)
            shiftedValues[y*48+x]=0.01+0.6*exp(-((dx-2.125)*(dx-2.125)+dy*dy)/0.85)
        } }
        scalar(skyValues,skyGuide);scalar(shiftedValues,shiftedSky)
        let skyFlow=try texture(3,3,.rgba32Float),skyRegular=try texture(3,3,.rgba32Float),skyEstimated=try texture(3,3,.rgba32Float)
        var skyVectors=[Float](repeating:0,count:36)
        for j in 0..<9 { skyVectors[j*4+3]=0.9 };skyVectors[16]=2.125;skyVectors[19]=0.1
        skyVectors.withUnsafeBytes { skyFlow.replace(region:MTLRegionMake2D(0,0,3,3),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:48) }
        func readFlow(_ t:MTLTexture)->[Float] {
            var values=[Float](repeating:0,count:t.width*t.height*4)
            values.withUnsafeMutableBytes { t.getBytes($0.baseAddress!,bytesPerRow:t.width*16,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) };return values
        }
        var skyParams=MetalFusionParameters();skyParams.size.w=1;skyParams.flags.x=1;skyParams.search=SIMD4(3,0,0,1)
        skyParams.roi=SIMD4(0,0,48,48);skyParams.sensorNoise=SIMD4(0,1e-6,0,1e-6);skyParams.control.x=0.001
        try execute("uc_regularize_flow",[skyGuide,shiftedSky,skyFlow,skyRegular],skyParams,skyRegular)
        try require(abs(readFlow(skyRegular)[16]-2.125)<0.0001,"Landscape flow erased a photometrically supported star displacement")
        try execute("uc_tile_flow",[skyGuide,shiftedSky,skyFlow,skyEstimated],skyParams,skyEstimated)
        let skyVector=readFlow(skyEstimated)
        print("Astro fine flow",skyVector[16],skyVector[17])
        try require(abs(skyVector[16]-2.125)<=0.126 && abs(skyVector[17])<=0.125,"Astro point flow lost sub-quarter-pixel refinement")
        let nightInput=try texture(32,32),nightPlain=try texture(32,32),nightClean=try texture(32,32),nightBase=try texture(2,2,.r16Float)
        var castPixels=[Float](repeating:1,count:32*32*4)
        for y in 0..<32 { for x in 0..<32 {
            let j=(y*32+x)*4,warm=x>=16
            castPixels[j]=warm ? 0.8:0.02;castPixels[j+1]=warm ? 0.35:0.045;castPixels[j+2]=warm ? 0.07:0.006
        } }
        upload(castPixels,nightInput);scalar([0.037,0.425,0.037,0.425],nightBase)
        var nightParams=MetalFusionParameters();nightParams.control.y=2;nightParams.control.z=4;nightParams.tone=SIMD4(0.003,0.002,0.02,0)
        try execute("uc_night_tone",[nightInput,nightBase,nightBase,nightPlain],nightParams,nightPlain)
        nightParams.tone.w=0.4
        try execute("uc_night_tone",[nightInput,nightBase,nightBase,nightClean],nightParams,nightClean)
        let unclean=read(nightPlain),castClean=read(nightClean),darkIndex=(16*32+5)*4,warmIndex=(16*32+26)*4
        let beforeCast=unclean[darkIndex+1]-unclean[darkIndex+2],afterCast=castClean[darkIndex+1]-castClean[darkIndex+2]
        print("Dark chromaticity residual ratio",afterCast/beforeCast)
        try require(afterCast<beforeCast*0.97,"Dark green/yellow cast was not attenuated")
        for c in 0..<3 { try require(abs(castClean[warmIndex+c]-unclean[warmIndex+c])<0.001,"Night chromaticity changed supported warm lamp colour") }
        print("Production Metal SR frequency recovery / separate phases / star vs sensor impulse passed")
    }
}
