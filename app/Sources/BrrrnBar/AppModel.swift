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
        if pitIsDue, let config, config.hasPits {
            do {
                boards = try await pitClient.boards(config: config)
                lastPitRefresh = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
