import Foundation
import SwiftUI
import BrrrnCore

@MainActor
final class AppModel: ObservableObject {
    struct Selection: Identifiable {
        let id = UUID()
        let pitCode: String
        let member: PitBoard.Member
        let detail: MemberDetail
    }

    @Published var report: BurnReport?
    @Published var weekReport: BurnReport?
    @Published var boards: [PitBoard] = []
    @Published var selection: Selection?
    @Published var isRefreshing = false
    @Published var isLoadingMember = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private let pitClient = PitClient()
    private let configStore = BrrrnConfigStore()
    private var watcher: DirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    private var lastPitRefresh: Date?
    private var started = false

    var menuBarTitle: String? {
        report.map { Format.money($0.windows.today.costUSD) }
    }

    var weekModels: [BurnReport.ModelUsage] {
        Array(ModelSort.byCostDescending(weekReport?.byModel ?? []).prefix(8))
    }

    var config: BrrrnConfig? {
        BrrrnConfig.loadDefault()
    }

    func start() {
        guard !started else { return }
        started = true
        let home = NSHomeDirectory()
        watcher = DirectoryWatcher(
            paths: [home + "/.claude/projects", home + "/.codex/sessions"],
            onChange: { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        )
        watcher?.start()
        refreshLoop = Task { [weak self] in
            await self?.refresh(forcePit: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh(forcePit: Bool = false) async {
        guard !isRefreshing else { return }
        guard let binary = BinaryLocator().locate() else {
            errorMessage = EngineError.binaryNotFound.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let all = LocalEngine.allTimeReport(binary: binary)
            async let week = LocalEngine.weekReport(binary: binary)
            let (newReport, newWeek) = try await (all, week)
            report = newReport
            weekReport = newWeek
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        let pitIsDue = forcePit || lastPitRefresh.map { Date().timeIntervalSince($0) >= 300 } ?? true
        if pitIsDue {
            await refreshBoards(binary: binary)
        }
    }

    private func refreshBoards(binary: String) async {
        switch await configStore.load() {
        case .missing:
            boards = []
        case .malformed(let message):
            boards = []
            errorMessage = BrrrnConfigStoreError.malformed(message).localizedDescription
        case .valid(let config) where !config.hasPits:
            boards = []
        case .valid:
            do {
                // Keep app-side config mutations queued while the Rust process
                // reads and updates the same file, then fetch with fresh state.
                try await configStore.serialize {
                    try await LocalEngine.submit(binary: binary)
                }
                let refreshedConfig: BrrrnConfig
                switch await configStore.load() {
                case .valid(let config):
                    refreshedConfig = config
                case .missing:
                    boards = []
                    throw BrrrnConfigStoreError.fileSystem(
                        "brrrn config disappeared during submission"
                    )
                case .malformed(let message):
                    boards = []
                    throw BrrrnConfigStoreError.malformed(message)
                }
                boards = try await pitClient.boards(config: refreshedConfig)
                lastPitRefresh = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Create a pit, join it as `handle`, backfill, and refresh. Returns the
    /// new code so the UI can hand it to friends.
    func createPit(name: String?, handle: String) async throws -> String {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        let code = try await LocalEngine.createPit(binary: binary, name: name)
        try await configStore.serialize {
            try await LocalEngine.joinPit(binary: binary, code: code, handle: handle)
        }
        await refresh(forcePit: true)
        return code
    }

    /// Join an existing pit as `handle`, backfill, and refresh.
    func joinPit(code: String, handle: String) async throws {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        try await configStore.serialize {
            try await LocalEngine.joinPit(binary: binary, code: code, handle: handle)
        }
        await refresh(forcePit: true)
    }

    func openMember(pitCode: String, member: PitBoard.Member) async {
        guard let config else { return }
        isLoadingMember = true
        defer { isLoadingMember = false }
        do {
            let detail = try await pitClient.member(hubURL: config.hubURL, code: pitCode, handle: member.handle)
            selection = Selection(pitCode: pitCode, member: member, detail: detail)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeMember() {
        selection = nil
    }
}
