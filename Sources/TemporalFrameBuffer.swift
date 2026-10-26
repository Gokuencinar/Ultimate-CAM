import Foundation

/// Owns bounded payloads; never retains capture pool sample buffers. Times are
/// host monotonic arrival times. A snapshot excludes every post-shutter frame.
final class TemporalFrameBuffer<Value> {
    struct Entry { let time:Double;let value:Value;let bytes:Int }
    private let lock=NSLock()
    private var slots:[Entry?]
    private var next=0,count=0,total=0
    let maximumBytes:Int
    init(capacity:Int=8,maximumBytes:Int=48*1024*1024) {
        precondition((2...32).contains(capacity) && maximumBytes>0)
        slots=Array(repeating:nil,count:capacity);self.maximumBytes=maximumBytes
    }
    func reset() { lock.lock();defer { lock.unlock() };clear() }
    private func clear() { slots=Array(repeating:nil,count:slots.count);next=0;count=0;total=0 }
    func append(_ value:Value,time:Double,bytes:Int) {
        guard time.isFinite,bytes>0,bytes<=maximumBytes else { return }
        lock.lock();defer { lock.unlock() }
        if let last=slots[(next+slots.count-1)%slots.count],time<=last.time { clear() }
        while count>0 && (total+bytes>maximumBytes || count==slots.count) {
            let oldest=(next-count+slots.count)%slots.count
            total-=slots[oldest]?.bytes ?? 0;slots[oldest]=nil;count-=1
        }
        slots[next]=Entry(time:time,value:value,bytes:bytes)
        next=(next+1)%slots.count;count+=1;total+=bytes
    }
    func snapshot(at time:Double,age:Double=0.6) -> [Entry] {
        guard time.isFinite,age.isFinite,age>0 else { return [] }
        lock.lock();defer { lock.unlock() }
        return (0..<count).compactMap { slots[(next-count+$0+slots.count)%slots.count] }
            .filter { $0.time<=time && time-$0.time<=age }
    }
}

/// Preview-domain motion, independent of gain through mean removal. Textureless
/// or ambiguous matches produce no shutter recommendation, not false stability.
struct PreviewMotionEstimate {
    let timestamp:Double
    let pixelsPerSecond:Double // In the 64-wide metering grid, not sensor pixels.
    let confidence:Double
    var shutterLimit:Double? {
        guard confidence>=0.25 else { return nil }
        return min(1,max(1.0/250,0.35/max(0.35,pixelsPerSecond)))
    }
}
final class PreviewMotionMeter {
    private var previous:[Float]?,previousTime=0.0
    private let lock=NSLock()
    private var result:PreviewMotionEstimate?
    func reset() { lock.lock();defer { lock.unlock() };previous=nil;previousTime=0;result=nil }
    func estimate(at time:Double) -> PreviewMotionEstimate? {
        lock.lock();defer { lock.unlock() }
        guard let result,time>=result.timestamp,time-result.timestamp<0.4 else { return nil };return result
    }
    func append(_ pixels:[Float],time:Double) {
        guard pixels.count==64*48,time.isFinite,pixels.allSatisfy(\.isFinite) else { return }
        lock.lock();defer { lock.unlock() }
        defer { previous=pixels;previousTime=time }
        guard let previous,time>previousTime,time-previousTime<0.3 else { result=nil;return }
        let mean=pixels.reduce(0,+)/Float(pixels.count)
        let oldMean=previous.reduce(0,+)/Float(previous.count)
        let variance=pixels.reduce(Float(0)) { $0+($1-mean)*($1-mean) }/Float(pixels.count)
        guard variance>0.00015 else { result=nil;return }
        var best=Float.infinity,second=Float.infinity,dx=0,dy=0
        for y in -4...4 { for x in -4...4 {
            var cost:Float=0
            for row in stride(from:6,to:42,by:2) { for col in stride(from:6,to:58,by:2) {
                cost+=abs((pixels[(row+y)*64+col+x]-mean)-(previous[row*64+col]-oldMean))
            } }
            if cost<best { second=best;best=cost;dx=x;dy=y } else if cost<second { second=cost }
        } }
        let separation=Double(max(0,second-best)/max(second,0.0001))
        // SAD also detects subject motion that cannot be explained by a pan.
        let residual=Double(best/468),speed=hypot(Double(dx),Double(dy))/(time-previousTime)
        result=PreviewMotionEstimate(timestamp:time,pixelsPerSecond:max(speed,residual*180),confidence:min(1,separation*4))
    }
}
