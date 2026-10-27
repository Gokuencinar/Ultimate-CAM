import Foundation

struct OpticalCaptureProgress {
    private(set) var total=0,completed=0
    private var seen=Set<Int64>()
    var started:Bool { total>0 }
    var capturing:Bool { started && completed<total }
    var fraction:Double { total>0 ? Double(completed)/Double(total):0 }
    mutating func begin(total:Int) { self.total=max(1,total);completed=0;seen=[] }
    mutating func exposed(id:Int64) {
        guard capturing,seen.insert(id).inserted else { return }
        completed=min(total,completed+1)
    }
    mutating func complete() { if started { completed=total } }
    mutating func reset() { self=OpticalCaptureProgress() }
}
