import SwiftUI
import Combine

@MainActor
final class LocalModel: ObservableObject {
    @Published var projects: [LocalProject] = []
    @Published var categories: [LocalCategory] = []
    @Published var sessions: [LocalSession] = []
    @Published var history: [LocalHistoryEntry] = []
    @Published var conflicts: [HistorySyncConflict] = []
    @Published var error: String?
    @Published var syncStatus = "同期を準備中"
    private(set) var refreshedAt = Date()
    private var store: LocalStore?
    private var sync: HistorySync?
    private var syncing = false
    private var syncRequested = false
    private var historyEditorOpen = false

    init(userID: String) {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.environment["DEVTRACK_AUTH_EMULATOR"] == "1" {
                let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("emulator", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                store = try LocalStore(path: LocalStore.url(for: userID, directory: dir).path)
            } else {
                store = try LocalStore(userID: userID)
            }
            #else
            store = try LocalStore(userID: userID)
            #endif
            if let store { sync = HistorySync(userID: userID, store: store) }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard !historyEditorOpen, let store else { return }
        do {
            let now = Date()
            let loadedProjects = try store.projects()
            let loadedCategories = try store.categories()
            let loadedSessions = try store.sessions(at: now)
            let loadedHistory = try store.history()
            let loadedConflicts = try store.historyConflicts()
            refreshedAt = now
            projects = loadedProjects; categories = loadedCategories; sessions = loadedSessions; history = loadedHistory; conflicts = loadedConflicts
        }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func perform(refreshAfter: Bool = true, _ operation: (LocalStore) throws -> Void) -> Bool {
        guard let store else { error = "ローカルデータベースを開けません。"; return false }
        do { try operation(store); error = nil; if refreshAfter { refresh(); requestSync() }; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    var active: LocalSession? { sessions.first { $0.state != "stopped" } }
    func beginHistoryEditing() { historyEditorOpen = true }
    func endHistoryEditing() { historyEditorOpen = false; refresh(); requestSync() }
    func requestSync() { Task { await synchronize() } }
    func synchronize() async {
        guard let sync, let store else { return }
        guard !syncing else { syncRequested = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncRequested = false
            syncStatus = "同期中"
            do {
                try await sync.synchronize()
                let counts = try store.historySyncCounts()
                syncStatus = counts.conflicts > 0 ? "同期の競合が\(counts.conflicts)件あります" : counts.pending > 0 ? "同期待ち \(counts.pending)件" : "同期済み"
                refresh()
            } catch {
                let pending = (try? store.historySyncCounts().pending) ?? 0
                syncStatus = "同期できません · 同期待ち \(pending)件"
            }
        } while syncRequested && !Task.isCancelled
    }
    func elapsed(_ session: LocalSession, at date: Date) -> Double {
        session.seconds + (session.state == "running" ? max(0, date.timeIntervalSince(refreshedAt)) : 0)
    }
}

struct MainTabs: View {
    @ObservedObject var session: Session
    @StateObject private var model: LocalModel
    @Environment(\.scenePhase) private var scenePhase
    init(session: Session, userID: String) {
        self.session = session
        _model = StateObject(wrappedValue: LocalModel(userID: userID))
    }
    var body: some View {
        TabView {
            TimerView(model: model, session: session).tabItem { Label("ホーム", systemImage: "house") }
            ProjectsView(model: model).tabItem { Label("プロジェクト", systemImage: "folder") }
            HistoryView(model: model).tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            NavigationStack { ContentUnavailableViewCompat() }.tabItem { Label("分析", systemImage: "chart.bar") }
        }
        .task {
            while !Task.isCancelled {
                await model.synchronize()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            }
        }
        .onChange(of: scenePhase) { phase in if phase == .active { model.requestSync() } }
        .safeAreaInset(edge: .top) {
            if let active = model.active {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text("\(active.state == "paused" ? "一時停止中" : "計測中") · \(active.projectName) · \(duration(model.elapsed(active, at: timeline.date)))")
                        .font(.caption).frame(maxWidth: .infinity).padding(6).background(.regularMaterial)
                        .accessibilityIdentifier("timerStatus")
                }
            }
        }
    }
}

private func duration(_ seconds: Double) -> String {
    let value = Int(max(0, seconds)); return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
}

struct TimerView: View {
    @ObservedObject var model: LocalModel
    @ObservedObject var session: Session
    @State private var projectID = ""
    @State private var categoryID = "general"
    var body: some View {
        NavigationStack {
            Form {
                Section("タイマー") {
                    if let active = model.active {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(duration(model.elapsed(active, at: timeline.date))).font(.largeTitle.monospacedDigit()).accessibilityIdentifier("elapsedTime")
                        }
                        Text("\(active.projectName) · \(active.categoryName)")
                        if active.state == "running" {
                            Button("一時停止") { model.perform { try $0.pause() } }
                        } else {
                            Button("再開") { model.perform { try $0.resume() } }
                        }
                        Button("終了") { model.perform { try $0.stop() } }
                        if !model.projects.filter({ !$0.archived }).isEmpty {
                            Picker("変更先プロジェクト", selection: $projectID) {
                                Text("選択してください").tag("")
                                ForEach(model.projects.filter { !$0.archived }) { Text($0.name).tag($0.id) }
                            }
                            Picker("変更先カテゴリ", selection: $categoryID) { ForEach(model.categories) { Text($0.name).tag($0.id) } }
                            Button("計測先を変更") { model.perform { try $0.change(projectID: projectID, categoryID: categoryID) } }.disabled(projectID.isEmpty)
                        }
                    } else {
                        Picker("プロジェクト", selection: $projectID) {
                            Text("選択してください").tag("")
                            ForEach(model.projects.filter { !$0.archived }) { Text($0.name).tag($0.id) }
                        }.accessibilityIdentifier("projectPicker")
                        Picker("カテゴリ", selection: $categoryID) { ForEach(model.categories) { Text($0.name).tag($0.id) } }
                        Button("計測開始") { model.perform { try $0.start(projectID: projectID, categoryID: categoryID) } }.disabled(projectID.isEmpty)
                        if model.projects.allSatisfy(\.archived) { Text("プロジェクトタブから作成してください。") }
                    }
                }
                Section("保存状況") {
                    Text("この端末に保存中 · \(model.syncStatus)")
                    Button("今すぐ同期") { model.requestSync() }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("ホーム")
                .toolbar { NavigationLink("アカウント") { ContentView(session: session) } }
        }
    }
}

struct ProjectsView: View {
    private enum Field: Hashable { case project, category }
    @ObservedObject var model: LocalModel
    @State private var name = ""
    @State private var categoryName = ""
    @State private var editing: LocalProject?
    @State private var editName = ""
    @FocusState private var focused: Field?
    var body: some View {
        NavigationStack {
            Form {
                Section("新しいプロジェクト") {
                    TextField("プロジェクト名", text: $name).focused($focused, equals: .project)
                    Button("プロジェクトを追加") { focused = nil; let n = name; model.perform { _ = try $0.addProject(n) }; if model.error == nil { name = "" } }
                }
                Section("プロジェクト") {
                    ForEach(model.projects) { project in
                        HStack {
                            Text(project.name)
                            if project.archived { Text("アーカイブ済み").foregroundStyle(.secondary) }
                            Spacer()
                            if !project.archived {
                                Button("編集") { editing = project; editName = project.name }.buttonStyle(.borderless)
                                Button("アーカイブ") { model.perform { try $0.archiveProject(project.id) } }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("カテゴリ") {
                    ForEach(model.categories) { Text($0.name) }
                    TextField("カテゴリ名", text: $categoryName).focused($focused, equals: .category)
                    Button("カテゴリを追加") { focused = nil; let n = categoryName; model.perform { _ = try $0.addCategory(n) }; if model.error == nil { categoryName = "" } }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("プロジェクト")
                .sheet(item: $editing) { project in
                    NavigationStack {
                        Form { TextField("プロジェクト名", text: $editName) }
                            .navigationTitle("編集")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { editing = nil } }
                                ToolbarItem(placement: .confirmationAction) { Button("保存") { model.perform { try $0.renameProject(project.id, name: editName) }; if model.error == nil { editing = nil } } }
                            }
                            .safeAreaInset(edge: .bottom) { if let error = model.error { Text(error).foregroundStyle(.red) } }
                    }
                }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: LocalModel
    @State private var editor: HistoryEditorTarget?
    @State private var pendingDelete: LocalHistoryEntry?
    var body: some View {
        NavigationStack {
            List {
                if !model.conflicts.isEmpty {
                    Section("同期の競合") {
                        ForEach(model.conflicts) { conflict in
                            NavigationLink("\(conflict.local.projectName)の変更を確認") { HistoryConflictView(model: model, conflict: conflict) }
                        }
                    }
                }
                ForEach(model.history) { entry in
                    Button { openEditor(entry) } label: {
                        VStack(alignment: .leading) {
                            Text(entry.projectName)
                            Text("\(entry.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.categoryName)").font(.caption).foregroundStyle(.secondary)
                            Text(duration(entry.endedAt.timeIntervalSince(entry.startedAt))).monospacedDigit()
                            if !entry.note.isEmpty { Text(entry.note).font(.caption) }
                            Text(entry.source == "manual" ? "手動記録" : "タイマー区間").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("historyEntry-\(entry.id)")
                    .swipeActions {
                        Button("削除", role: .destructive) { pendingDelete = entry }
                        Button("編集") { openEditor(entry) }.tint(.blue)
                    }
                }
                if model.history.isEmpty { Text("作業記録はまだありません。") }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("履歴")
            .toolbar { Button("記録を追加") { openEditor(nil) } }
            .sheet(item: $editor, onDismiss: { model.endHistoryEditing() }) { target in HistoryEditor(model: model, entry: target.entry) }
            .confirmationDialog("この作業区間を削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let entry = pendingDelete { model.perform { try $0.deleteHistory(id: entry.id, expectedRevision: entry.revision) } }
                    pendingDelete = nil
                }
            }
        }
    }
    private func openEditor(_ entry: LocalHistoryEntry?) {
        model.beginHistoryEditing()
        editor = HistoryEditorTarget(entry: entry)
    }
}

private struct HistoryConflictView: View {
    @ObservedObject var model: LocalModel
    let conflict: HistorySyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Bool?

    var body: some View {
        Form {
            Section("この端末の変更") { summary(conflict.local) }
            Section("別の端末の変更") { summary(conflict.remote) }
            Section {
                Text("両方の変更を端末に保存したまま、同期する内容を選択します。選ばなかった内容はこの端末に保管されます。")
                Button("この端末の変更を同期") { choice = true }
                Button("別の端末の変更を採用") { choice = false }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("同期の競合")
        .confirmationDialog("選択した内容を履歴に反映しますか？", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible) {
            Button("反映する") {
                if let choice, model.perform({ try $0.resolveHistoryConflict(id: conflict.id, keepLocal: choice) }) { dismiss() }
                choice = nil
            }
        }
    }
    @ViewBuilder private func summary(_ record: HistorySyncRecord) -> some View {
        Text(record.deleted ? "削除された記録" : record.projectName)
        Text("\(Date(timeIntervalSince1970: record.start).formatted(date: .abbreviated, time: .shortened)) – \(Date(timeIntervalSince1970: record.end).formatted(date: .abbreviated, time: .shortened))")
        Text(record.categoryName)
        if !record.note.isEmpty { Text(record.note) }
    }
}

private struct HistoryEditorTarget: Identifiable {
    let entry: LocalHistoryEntry?
    var id: String { entry?.id ?? "new" }
}

private struct HistoryEditor: View {
    @ObservedObject var model: LocalModel
    let entry: LocalHistoryEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: String
    @State private var categoryID: String
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var note: String
    @FocusState private var noteFocused: Bool

    init(model: LocalModel, entry: LocalHistoryEntry?) {
        self.model = model; self.entry = entry
        _projectID = State(initialValue: entry?.projectID ?? model.projects.first(where: { !$0.archived })?.id ?? "")
        _categoryID = State(initialValue: entry?.categoryID ?? "general")
        _startedAt = State(initialValue: entry?.startedAt ?? Date().addingTimeInterval(-3600))
        _endedAt = State(initialValue: entry?.endedAt ?? Date())
        _note = State(initialValue: entry?.note ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if projectID.isEmpty { Text("先にプロジェクトを作成してください。") }
                Picker("プロジェクト", selection: $projectID) {
                    if projectID.isEmpty { Text("選択してください").tag("") }
                    ForEach(model.projects.filter { !$0.archived || $0.id == entry?.projectID }) { project in
                        Text(project.archived ? "\(project.name)（アーカイブ済み）" : project.name).tag(project.id)
                    }
                }
                Picker("カテゴリ", selection: $categoryID) { ForEach(model.categories) { Text($0.name).tag($0.id) } }
                DatePicker("開始", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                DatePicker("終了", selection: $endedAt, displayedComponents: [.date, .hourAndMinute])
                TextField("作業メモ", text: $note, axis: .vertical).lineLimit(2...5).focused($noteFocused).accessibilityIdentifier("historyNote")
                if let entry, entry.source == "timer" { Text("この作業区間のみを編集します。他の区間は変更しません。 ").font(.caption).foregroundStyle(.secondary) }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(entry == nil ? "記録を追加" : "記録を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { model.error = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        noteFocused = false
                        let succeeded = model.perform(refreshAfter: false) { store in
                            if let entry {
                                try store.editHistory(id: entry.id, expectedRevision: entry.revision, projectID: projectID, categoryID: categoryID, start: startedAt, end: endedAt, note: note)
                            } else {
                                _ = try store.addHistory(projectID: projectID, categoryID: categoryID, start: startedAt, end: endedAt, note: note)
                            }
                        }
                        if succeeded { dismiss() }
                    }.disabled(projectID.isEmpty)
                }
            }
        }
    }
}

private struct ContentUnavailableViewCompat: View {
    var body: some View { Text("分析は準備中です。").foregroundStyle(.secondary).navigationTitle("分析") }
}
