import CoreImage

enum PreviewReferenceSelector {
    static func index(in images:[CGImage],context:CIContext)->Int? {
        guard !images.isEmpty else { return nil }
        var selected=images.count-1,best = -Double.infinity
        for index in max(0,images.count-3)..<images.count {
            let image=CIImage(cgImage:images[index])
            let factor=min(1,512/max(image.extent.width,image.extent.height))
            let small=image.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
            let edges=small.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:0.6])
                .applyingFilter("CIEdges",parameters:[kCIInputIntensityKey:1]).cropped(to:small.extent)
                .applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:small.extent)])
            var pixel=[Float](repeating:0,count:4)
            pixel.withUnsafeMutableBytes {
                context.render(edges,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,
                    colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            }
            let score=Double(pixel[0]+pixel[1]+pixel[2])
            if score.isFinite,score>=best { best=score;selected=index }
        }
        return selected
    }
}
