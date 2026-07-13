import Foundation
import Darwin

final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ai.brrrn.directory-watcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        stop()
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: queue
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    deinit {
        stop()
    }
}
