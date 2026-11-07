import SwiftUI
import Combine

@MainActor
final class LocalModel: ObservableObject {
    @Published var projects: [LocalProject] = []
    @Published var categories: [LocalCategory] = []
    @Published var sessions: [LocalSession] = []
    @Published var error: String?
    private(set) var refreshedAt = Date()
    private var store: LocalStore?

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
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard let store else { return }
        do {
            let now = Date()
            let loadedProjects = try store.projects()
            let loadedCategories = try store.categories()
            let loadedSessions = try store.sessions(at: now)
            refreshedAt = now
            projects = loadedProjects; categories = loadedCategories; sessions = loadedSessions
        }
        catch { self.error = error.localizedDescription }
    }
    func perform(_ operation: (LocalStore) throws -> Void) {
        guard let store else { error = "ローカルデータベースを開けません。"; return }
        do { try operation(store); error = nil; refresh() }
        catch { self.error = error.localizedDescription }
    }
    var active: LocalSession? { sessions.first { $0.state != "stopped" } }
    func elapsed(_ session: LocalSession, at date: Date) -> Double {
        session.seconds + (session.state == "running" ? max(0, date.timeIntervalSince(refreshedAt)) : 0)
    }
}

struct MainTabs: View {
    @ObservedObject var session: Session
    @StateObject private var model: LocalModel
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
                Section("保存状況") { Text("この端末に保存中 · 同期は準備中") }
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
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sessions.filter { $0.state == "stopped" }) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.projectName)
                        Text("\(entry.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.categoryName)").font(.caption).foregroundStyle(.secondary)
                        Text(duration(entry.seconds)).monospacedDigit()
                        Text("表示名は終了時の計測先です").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if model.sessions.allSatisfy({ $0.state != "stopped" }) { Text("終了した作業はまだありません。") }
            }.navigationTitle("履歴")
        }
    }
}

private struct ContentUnavailableViewCompat: View {
    var body: some View { Text("分析は準備中です。").foregroundStyle(.secondary).navigationTitle("分析") }
}
