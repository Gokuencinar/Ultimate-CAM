import Foundation
#if os(iOS)
import os
#endif

/// Cross-queue cancellation checked between frames/stages, not GPU interruption.
final class ProcessingCancellation {
    private let lock = NSLock()
    private var reason: String?
    func cancel(_ reason: String = "Procesado cancelado; se conserva la referencia.") {
        lock.lock(); defer { lock.unlock() }
        if self.reason == nil { self.reason = reason }
    }
    func check() throws {
        lock.lock(); let value = reason; lock.unlock()
        if let value { throw CameraFailure.message(value) }
        #if os(iOS)
        if CaptureMemoryPolicy.isCritical(availableBytes:UInt64(os_proc_available_memory())) {
            throw CameraFailure.message("Memoria disponible crítica; se conserva la referencia.")
        }
        #endif
    }
}
