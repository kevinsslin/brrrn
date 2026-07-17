import Foundation
import SwiftUI
import BrrrnCore

enum PitJoinError: LocalizedError {
    case hubMismatch(configured: String, invited: String)

    var errorDescription: String? {
        switch self {
        case .hubMismatch(let configured, let invited):
            "This invite is for \(invited), but this client is set up for \(configured). One client tracks one hub."
        }
    }
}

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
    @Published var todayReport: BurnReport?
    @Published var monthReport: BurnReport?
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
    @Published private(set) var lastPitRefresh: Date?
    private var pitSync = PitSyncState()
    private var started = false

    var menuBarTitle: String? {
        report.map { Format.money($0.windows.today.costUSD) }
    }

    enum ModelPeriod: String, CaseIterable {
        case today
        case week
        case month

        var label: String {
            switch self {
            case .today: "Today"
            case .week: "Week"
            case .month: "Month"
            }
        }
    }

    func models(for period: ModelPeriod) -> [BurnReport.ModelUsage] {
        if let bundled = report?.modelsByPeriod {
            let rows = switch period {
            case .today: bundled.today
            case .week: bundled.week
            case .month: bundled.month
            }
            return Array(ModelSort.byCostDescending(ModelMerge.foldFastMode(rows)).prefix(24))
        }
        let source = switch period {
        case .today: todayReport
        case .week: weekReport
        case .month: monthReport
        }
        return Array(
            ModelSort.byCostDescending(ModelMerge.foldFastMode(source?.byModel ?? [])).prefix(24)
        )
    }

    /// Fixture injection for the screenshot generator; nil in normal runs.
    var configOverride: BrrrnConfig?

    var config: BrrrnConfig? {
        configOverride ?? BrrrnConfig.loadDefault()
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

    /// A forced refresh (`forcePit: true`) is what happens when the user is
    /// actually looking (opening the Pits tab, creating/joining/renaming, or
    /// hitting refresh): it pushes a submit and pulls every board, ignoring the
    /// submit interval and the failure backoff. A background tick leaves the
    /// hub alone unless there is something new to push.
    func refresh(forcePit: Bool = false) async {
        guard !isRefreshing else { return }
        guard let binary = BinaryLocator().locate() else {
            errorMessage = EngineError.binaryNotFound.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let reports = try await LocalEngine.refreshReports(binary: binary)
            report = reports.all
            weekReport = reports.week
            todayReport = reports.today
            monthReport = reports.month
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        await syncPits(binary: binary, forcePit: forcePit)
    }

    /// Talks to the hub as little as possible. A background sync only pushes a
    /// submit when today's or yesterday's numbers actually changed, and never
    /// more than once every `submitMinInterval`; it does not pull boards,
    /// because the menu bar shows only local numbers and nobody is looking at
    /// the leaderboard. Boards are fetched only on a forced sync. Failures open
    /// a widening backoff window so a broken or rate-limited hub is not retried
    /// every minute.
    private func syncPits(binary: String, forcePit: Bool) async {
        let now = Date()
        if !forcePit && PitSync.inBackoff(pitSync, now: now) { return }

        let signature = report?.daily.map { SubmitSignature.of(daily: $0, now: now) }
        let doSubmit = forcePit || PitSync.submitDue(pitSync, signature: signature, now: now)
        let doBoards = forcePit
        guard doSubmit || doBoards else { return }

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
                var submittedSignature: String?
                if doSubmit {
                    // Keep app-side config mutations queued while the Rust
                    // process reads and updates the same file.
                    try await configStore.serialize {
                        try await LocalEngine.submit(binary: binary)
                    }
                    submittedSignature = signature
                }
                if doBoards {
                    // Reload after the submit so the board fetch sees fresh
                    // state (backfill markers, adopted hub URL).
                    boards = try await pitClient.boards(config: try await freshConfig())
                    lastPitRefresh = Date()
                }
                PitSync.recordSuccess(&pitSync, submittedSignature: submittedSignature, now: Date())
            } catch {
                errorMessage = error.localizedDescription
                PitSync.recordFailure(&pitSync, now: Date())
            }
        }
    }

    private func freshConfig() async throws -> BrrrnConfig {
        switch await configStore.load() {
        case .valid(let config):
            return config
        case .missing:
            boards = []
            throw BrrrnConfigStoreError.fileSystem("brrrn config disappeared during submission")
        case .malformed(let message):
            boards = []
            throw BrrrnConfigStoreError.malformed(message)
        }
    }

    /// Create a pit, join it as `handle`, backfill, and refresh. Returns the
    /// new code so the UI can hand it to friends.
    func createPit(name: String?, handle: String? = nil, displayName: String? = nil) async throws -> String {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        let code = try await LocalEngine.createPit(binary: binary, name: name)
        try await configStore.serialize {
            try await LocalEngine.joinPit(
                binary: binary, code: code, handle: handle, displayName: displayName
            )
        }
        await refresh(forcePit: true)
        return code
    }

    /// Join an existing pit as `handle`, backfill, and refresh. When the
    /// invite carries a hub URL, adopt it if none is configured yet; a
    /// conflicting hub is an error rather than a silent switch, because one
    /// client tracks one hub.
    func joinPit(code: String, handle: String? = nil, displayName: String? = nil, inviteHubURL: String? = nil) async throws {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        let current = config?.hubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        try await configStore.serialize {
            if let inviteHubURL {
                let invited = inviteHubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if current.isEmpty {
                    try await LocalEngine.setHub(binary: binary, url: invited)
                } else if current != invited {
                    throw PitJoinError.hubMismatch(configured: current, invited: invited)
                }
            }
            try await LocalEngine.joinPit(
                binary: binary, code: code, handle: handle, displayName: displayName
            )
        }
        await refresh(forcePit: true)
    }

    /// Called when the Pits tab comes into view: pull a fresh board unless
    /// one was fetched in the last minute, so the page never shows numbers
    /// that are minutes old right when someone looks at them.
    func refreshPitsIfStale() async {
        let age = lastPitRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 60 else { return }
        await refresh(forcePit: true)
    }

    /// Update the display name everywhere. The hub call is the only thing
    /// awaited (~a second per pit); boards are patched locally for instant
    /// feedback and the full refresh runs in the background.
    func renameDisplay(to name: String) async throws {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        try await configStore.serialize {
            try await LocalEngine.renameDisplay(binary: binary, to: name)
        }
        if let handle = config?.handle {
            for boardIndex in boards.indices {
                for memberIndex in boards[boardIndex].members.indices
                where boards[boardIndex].members[memberIndex].handle == handle {
                    boards[boardIndex].members[memberIndex].displayName = name
                }
            }
        }
        Task { await refresh(forcePit: true) }
    }

    /// Rename a pit for everyone; local boards patch instantly and the
    /// full refresh confirms in the background.
    func renamePit(code: String, to name: String) async throws {
        guard let binary = BinaryLocator().locate() else {
            throw EngineError.binaryNotFound
        }
        try await LocalEngine.setPitTitle(binary: binary, code: code, name: name)
        for index in boards.indices where boards[index].code == code {
            boards[index].name = name
        }
        Task { await refresh(forcePit: true) }
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
