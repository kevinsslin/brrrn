import Foundation
import CoreServices

private final class WatcherCallbackBox: @unchecked Sendable {
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }
}

/// Recursive FSEvents watcher for the Claude Code and Codex log trees.
final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    private let callbackBox: WatcherCallbackBox
    private let queue = DispatchQueue(label: "ai.brrrn.directory-watcher", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        callbackBox = WatcherCallbackBox(onChange: onChange)
    }

    func start() {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WatcherCallbackBox>
                .fromOpaque(info)
                .takeUnretainedValue()
                .onChange()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) {
            stop()
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
