import Foundation
import Darwin

/// Read-only file-backed burst payload. Only the currently processed frame must
/// be resident; a 16-frame 12 MP stack must not own 384 MB of dirty heap pages.
final class BayerScratchStorage {
    private static let session=UUID().uuidString
    private let url:URL,address:UnsafeMutableRawPointer,length:Int
    private init(url:URL,address:UnsafeMutableRawPointer,length:Int) { self.url=url;self.address=address;self.length=length }
    deinit { munmap(address,length);try? FileManager.default.removeItem(at:url) }
    private static func directory() throws -> URL {
        let cache=try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let root=cache.appendingPathComponent("UltimateCAM-Bayer",isDirectory:true)
        let current=root.appendingPathComponent(session,isDirectory:true)
        let manager=FileManager.default
        if !manager.fileExists(atPath:current.path) {
            try manager.createDirectory(at:current,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // Only expired UUID directories in this app-owned cache. Never
            // inspect or remove a user-selected path or another active session.
            for child in (try? manager.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey])) ?? [] {
                guard child != current,UUID(uuidString:child.lastPathComponent) != nil,
                      let values=try? child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey]),
                      values.isDirectory==true,values.isSymbolicLink==false,let date=values.contentModificationDate,
                      Date().timeIntervalSince(date)>86400 else { continue }
                try? manager.removeItem(at:child)
            }
        }
        return current
    }
    static func ensureCapacity(required:Int64) throws {
        let directory=try directory(),values=try directory.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        guard required>0,let available=values.volumeAvailableCapacityForImportantUsage,available>=required else { throw CameraFailure.message("No hay espacio temporal suficiente para la ráfaga RAW de resolución nativa.") }
    }
    static func store(_ bytes:Data) throws -> (data:Data,storage:BayerScratchStorage) {
        guard !bytes.isEmpty else { throw CameraFailure.message("Plano Bayer vacío.") }
        let url=try directory().appendingPathComponent(UUID().uuidString+".bayer")
        let descriptor=open(url.path,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0o600)
        guard descriptor>=0 else { throw CameraFailure.message("No se pudo crear el RAW temporal.") }
        defer { close(descriptor) }
        do {
            try bytes.withUnsafeBytes { payload in
                guard let base=payload.baseAddress else { throw CameraFailure.message("Plano Bayer vacío.") }
                var offset=0
                while offset<payload.count {
                    let written=Darwin.write(descriptor,base.advanced(by:offset),payload.count-offset)
                    if written<0 && errno==EINTR { continue }
                    guard written>0 else { throw CameraFailure.message("No se pudo escribir el RAW temporal.") }
                    offset+=written
                }
            }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
            #endif
            guard let address=mmap(nil,bytes.count,PROT_READ,MAP_PRIVATE,descriptor,0),address != MAP_FAILED else { throw CameraFailure.message("No se pudo mapear el RAW temporal.") }
            let storage=BayerScratchStorage(url:url,address:address,length:bytes.count)
            let data=Data(bytesNoCopy:address,count:bytes.count,deallocator:.custom { _,_ in withExtendedLifetime(storage) {} })
            return (data,storage)
        } catch { try? FileManager.default.removeItem(at:url);throw error }
    }
    func discardResidentPages() { _=madvise(address,length,MADV_DONTNEED) }
}
