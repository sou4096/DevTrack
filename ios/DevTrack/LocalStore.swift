import Foundation
import CryptoKit
import SQLite3

struct LocalProject: Identifiable, Equatable {
    let id: String
    let name: String
    let archived: Bool
}

struct LocalCategory: Identifiable, Equatable {
    let id: String
    let name: String
}

struct LocalSession: Identifiable, Equatable {
    let id: String
    let projectID: String
    let projectName: String
    let categoryID: String
    let categoryName: String
    let state: String
    let startedAt: Date
    let endedAt: Date?
    let seconds: Double
}

struct LocalHistoryEntry: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let projectID: String
    let projectName: String
    let categoryID: String
    let categoryName: String
    let startedAt: Date
    let endedAt: Date
    let note: String
    let source: String
    let revision: Int
}

struct HistorySyncRecord: Codable, Equatable {
    let id: String, sessionID: String, projectID: String, projectName: String
    let categoryID: String, categoryName: String
    let start: Double, end: Double
    let note: String, source: String
    let deleted: Bool
    let version: Int
    let operationID: String
}

struct HistorySyncOperation: Equatable {
    let record: HistorySyncRecord
}
struct HistorySyncConflict: Identifiable {
    let id: String
    let local: HistorySyncRecord
    let remote: HistorySyncRecord
}
struct HistorySyncCursor {
    let seconds: Int64
    let nanoseconds: Int32
    let operationID: String
}

enum StoreError: LocalizedError {
    case database(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .database: return "データベースを操作できませんでした。"
        case .invalid(let message): return message
        }
    }
}

/// A separate database per authenticated UID.
final class LocalStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func url(for uid: String, directory: URL) throws -> URL {
        guard !uid.isEmpty else { throw StoreError.invalid("アカウントを確認できません。") }
        let digest = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("devtrack-\(digest).sqlite")
    }

    convenience init(userID: String) throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(path: Self.url(for: userID, directory: directory).path)
    }

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db); self.db = nil }
            throw StoreError.database(message)
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try migrate()
        } catch {
            if let db { sqlite3_close(db); self.db = nil }
            throw error
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    private func error() -> StoreError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed") }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    private func bind(_ value: String, _ index: Int32, _ stmt: OpaquePointer) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else { throw error() }
    }
    private func bind(_ value: Double, _ index: Int32, _ stmt: OpaquePointer) throws {
        guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else { throw error() }
    }
    private func finish(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: ptr)
    }
    private func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try block(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func migrate() throws {
        let s = try statement("PRAGMA user_version"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw error() }
        let version = sqlite3_column_int(s, 0)
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
        guard version <= 5 else { throw StoreError.invalid("新しいバージョンのデータベースです。") }
        if version == 0 {
            try transaction {
                try execute("CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)))")
                try execute("CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
                try execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), category_id TEXT NOT NULL REFERENCES categories(id), state TEXT NOT NULL CHECK(state IN ('running','paused','stopped')), started_at REAL NOT NULL, ended_at REAL)")
                try execute("CREATE UNIQUE INDEX one_active_session ON sessions((1)) WHERE state IN ('running','paused')")
                try execute("CREATE TABLE intervals (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), project_id TEXT NOT NULL REFERENCES projects(id), category_id TEXT NOT NULL REFERENCES categories(id), started_at REAL NOT NULL, ended_at REAL)")
                try execute("CREATE UNIQUE INDEX one_open_interval ON intervals(session_id) WHERE ended_at IS NULL")
                try execute("INSERT INTO categories (id,name) VALUES ('general','一般')")
                try execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try transaction {
                try execute("ALTER TABLE intervals ADD COLUMN deleted_at REAL")
                try execute("ALTER TABLE intervals ADD COLUMN note TEXT NOT NULL DEFAULT ''")
                try execute("ALTER TABLE intervals ADD COLUMN source TEXT NOT NULL DEFAULT 'timer' CHECK(source IN ('timer','manual'))")
                try execute("ALTER TABLE intervals ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
                try execute("CREATE TABLE interval_revisions (id TEXT PRIMARY KEY, interval_id TEXT NOT NULL REFERENCES intervals(id), project_id TEXT NOT NULL, category_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL NOT NULL, note TEXT NOT NULL, source TEXT NOT NULL, revision INTEGER NOT NULL, changed_at REAL NOT NULL, action TEXT NOT NULL)")
                try execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try transaction {
                try execute("ALTER TABLE intervals ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 0")
                try execute("CREATE TABLE history_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE, interval_id TEXT NOT NULL, version INTEGER NOT NULL, payload TEXT NOT NULL)")
                try execute("CREATE TABLE history_conflicts (interval_id TEXT PRIMARY KEY, remote_payload TEXT NOT NULL)")
                let rows = try statement("SELECT i.id FROM intervals i JOIN sessions s ON s.id=i.session_id WHERE s.state='stopped' AND i.ended_at IS NOT NULL ORDER BY i.id")
                defer { sqlite3_finalize(rows) }
                var ids: [String] = []
                while true { let rc = sqlite3_step(rows); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }; ids.append(text(rows,0)) }
                for id in ids { try enqueueHistory(id) }
                try execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try transaction {
                try execute("CREATE TABLE history_resolved_ops (operation_id TEXT PRIMARY KEY, interval_id TEXT NOT NULL, payload TEXT NOT NULL)")
                try execute("CREATE TABLE history_conflict_resolutions (id TEXT PRIMARY KEY, interval_id TEXT NOT NULL, remote_payload TEXT NOT NULL, choice TEXT NOT NULL, resolved_at REAL NOT NULL)")
                try execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try transaction {
                try execute("CREATE TABLE history_sync_cursor (id INTEGER PRIMARY KEY CHECK(id=1), seconds INTEGER NOT NULL, nanoseconds INTEGER NOT NULL, operation_id TEXT NOT NULL)")
                try execute("CREATE TABLE history_sync_state (id INTEGER PRIMARY KEY CHECK(id=1), last_full_sweep REAL NOT NULL)")
                try execute("PRAGMA user_version = 5")
            }
        }
    }

    func projects() throws -> [LocalProject] {
        let s = try statement("SELECT id,name,archived FROM projects ORDER BY name COLLATE NOCASE,id"); defer { sqlite3_finalize(s) }
        var result: [LocalProject] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            result.append(LocalProject(id: text(s,0), name: text(s,1), archived: sqlite3_column_int(s,2) != 0))
        }
        return result
    }
    func categories() throws -> [LocalCategory] {
        let s = try statement("SELECT id,name FROM categories ORDER BY name COLLATE NOCASE,id"); defer { sqlite3_finalize(s) }
        var result: [LocalCategory] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            result.append(LocalCategory(id: text(s,0), name: text(s,1)))
        }
        return result
    }
    private func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, name.utf8.count <= 16000 else { throw StoreError.invalid("名前は1〜100文字で入力してください。") }
        return name
    }
    @discardableResult func addProject(_ name: String) throws -> String {
        let id = UUID().uuidString.lowercased(); let s = try statement("INSERT INTO projects(id,name) VALUES (?,?)"); defer { sqlite3_finalize(s) }
        try bind(id,1,s); try bind(validName(name),2,s); try finish(s); return id
    }
    func renameProject(_ id: String, name: String) throws {
        let s = try statement("UPDATE projects SET name=? WHERE id=?"); defer { sqlite3_finalize(s) }
        try bind(validName(name),1,s); try bind(id,2,s); try finish(s)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalid("プロジェクトが見つかりません。") }
    }
    func archiveProject(_ id: String) throws {
        guard try active()?.projectID != id else { throw StoreError.invalid("計測中のプロジェクトはアーカイブできません。") }
        let s = try statement("UPDATE projects SET archived=1 WHERE id=?"); defer { sqlite3_finalize(s) }
        try bind(id,1,s); try finish(s)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalid("プロジェクトが見つかりません。") }
    }
    @discardableResult func addCategory(_ name: String) throws -> String {
        let id = UUID().uuidString.lowercased(); let s = try statement("INSERT INTO categories(id,name) VALUES (?,?)"); defer { sqlite3_finalize(s) }
        try bind(id,1,s); try bind(validName(name),2,s); try finish(s); return id
    }
    private func ensureProjectAndCategory(_ projectID: String, _ categoryID: String) throws {
        guard try projects().contains(where: { $0.id == projectID && !$0.archived }), try categories().contains(where: { $0.id == categoryID }) else {
            throw StoreError.invalid("プロジェクトまたはカテゴリを選択してください。")
        }
    }
    private func insertInterval(sessionID: String, projectID: String, categoryID: String, at: Date) throws {
        let s = try statement("INSERT INTO intervals(id,session_id,project_id,category_id,started_at) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(s) }
        try bind(UUID().uuidString.lowercased(),1,s); try bind(sessionID,2,s); try bind(projectID,3,s); try bind(categoryID,4,s); try bind(at.timeIntervalSince1970,5,s); try finish(s)
    }
    func start(projectID: String, categoryID: String, at: Date = Date()) throws {
        try transaction {
            guard try active() == nil else { throw StoreError.invalid("すでにタイマーが存在します。") }
            try ensureProjectAndCategory(projectID, categoryID)
            let id = UUID().uuidString.lowercased(); let s = try statement("INSERT INTO sessions(id,project_id,category_id,state,started_at) VALUES(?,?,?,'running',?)"); defer { sqlite3_finalize(s) }
            try bind(id,1,s); try bind(projectID,2,s); try bind(categoryID,3,s); try bind(at.timeIntervalSince1970,4,s); try finish(s)
            try insertInterval(sessionID: id, projectID: projectID, categoryID: categoryID, at: at)
        }
    }
    private func closeInterval(_ session: LocalSession, at: Date) throws {
        let s = try statement("UPDATE intervals SET ended_at=? WHERE session_id=? AND ended_at IS NULL AND started_at<=?"); defer { sqlite3_finalize(s) }
        try bind(at.timeIntervalSince1970,1,s); try bind(session.id,2,s); try bind(at.timeIntervalSince1970,3,s); try finish(s)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalid("時刻またはタイマーの状態を確認してください。") }
    }
    private func setState(_ id: String, _ state: String, end: Date? = nil) throws {
        let s = try statement("UPDATE sessions SET state=?, ended_at=? WHERE id=?"); defer { sqlite3_finalize(s) }
        try bind(state,1,s)
        if let end { try bind(end.timeIntervalSince1970,2,s) } else { sqlite3_bind_null(s,2) }
        try bind(id,3,s); try finish(s)
    }
    func pause(at: Date = Date()) throws {
        try transaction {
            guard let a = try active(), a.state == "running" else { throw StoreError.invalid("計測中のタイマーがありません。") }
            try closeInterval(a, at: at); try setState(a.id,"paused")
        }
    }
    func resume(at: Date = Date()) throws {
        try transaction {
            guard let a = try active(), a.state == "paused" else { throw StoreError.invalid("一時停止中のタイマーがありません。") }
            let s = try statement("SELECT MAX(ended_at) FROM intervals WHERE session_id=?"); defer { sqlite3_finalize(s) }
            try bind(a.id,1,s); guard sqlite3_step(s) == SQLITE_ROW, at.timeIntervalSince1970 >= sqlite3_column_double(s,0) else { throw StoreError.invalid("時刻を確認してください。") }
            try insertInterval(sessionID: a.id, projectID: a.projectID, categoryID: a.categoryID, at: at); try setState(a.id,"running")
        }
    }
    func stop(at: Date = Date()) throws {
        try transaction {
            guard let a = try active() else { throw StoreError.invalid("タイマーがありません。") }
            if a.state == "running" { try closeInterval(a, at: at) }
            else {
                let s = try statement("SELECT MAX(ended_at) FROM intervals WHERE session_id=?"); defer { sqlite3_finalize(s) }
                try bind(a.id,1,s); guard sqlite3_step(s) == SQLITE_ROW, at.timeIntervalSince1970 >= sqlite3_column_double(s,0) else { throw StoreError.invalid("時刻を確認してください。") }
            }
            try setState(a.id,"stopped",end:at)
            let rows = try statement("SELECT id FROM intervals WHERE session_id=? AND ended_at IS NOT NULL ORDER BY started_at,id"); defer { sqlite3_finalize(rows) }
            try bind(a.id,1,rows); var ids: [String] = []
            while true { let rc = sqlite3_step(rows); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }; ids.append(text(rows,0)) }
            for id in ids { try enqueueHistory(id) }
        }
    }
    func change(projectID: String, categoryID: String, at: Date = Date()) throws {
        try transaction {
            guard let a = try active() else { throw StoreError.invalid("タイマーがありません。") }
            try ensureProjectAndCategory(projectID, categoryID)
            guard a.projectID != projectID || a.categoryID != categoryID else { return }
            if a.state == "running" { try closeInterval(a, at: at) }
            let s = try statement("UPDATE sessions SET project_id=?,category_id=? WHERE id=?"); defer { sqlite3_finalize(s) }
            try bind(projectID,1,s); try bind(categoryID,2,s); try bind(a.id,3,s); try finish(s)
            if a.state == "running" { try insertInterval(sessionID:a.id,projectID:projectID,categoryID:categoryID,at:at) }
        }
    }
    func sessions(at now: Date = Date()) throws -> [LocalSession] {
        let s = try statement("""
            SELECT s.id,s.project_id,p.name,s.category_id,c.name,s.state,s.started_at,s.ended_at,
              COALESCE((SELECT SUM(MAX(0,COALESCE(i.ended_at,?)-i.started_at)) FROM intervals i WHERE i.session_id=s.id AND i.deleted_at IS NULL),0)
            FROM sessions s JOIN projects p ON p.id=s.project_id JOIN categories c ON c.id=s.category_id
            WHERE s.state != 'stopped' OR EXISTS (SELECT 1 FROM intervals i WHERE i.session_id=s.id AND i.deleted_at IS NULL)
            ORDER BY s.started_at DESC,s.id
            """); defer { sqlite3_finalize(s) }
        try bind(now.timeIntervalSince1970,1,s); var result: [LocalSession] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            result.append(LocalSession(id:text(s,0),projectID:text(s,1),projectName:text(s,2),categoryID:text(s,3),categoryName:text(s,4),state:text(s,5),startedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,6)),endedAt:sqlite3_column_type(s,7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(s,7)),seconds:sqlite3_column_double(s,8)))
        }
        return result
    }
    func active(at: Date = Date()) throws -> LocalSession? { try sessions(at: at).first { $0.state != "stopped" } }

    func history() throws -> [LocalHistoryEntry] {
        let s = try statement("""
            SELECT i.id,i.session_id,i.project_id,p.name,i.category_id,c.name,i.started_at,i.ended_at,i.note,i.source,i.revision
            FROM intervals i JOIN sessions s ON s.id=i.session_id
              JOIN projects p ON p.id=i.project_id JOIN categories c ON c.id=i.category_id
            WHERE s.state='stopped' AND i.deleted_at IS NULL AND i.ended_at IS NOT NULL
            ORDER BY i.started_at DESC,i.id
            """); defer { sqlite3_finalize(s) }
        var result: [LocalHistoryEntry] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            result.append(LocalHistoryEntry(id: text(s,0), sessionID: text(s,1), projectID: text(s,2), projectName: text(s,3), categoryID: text(s,4), categoryName: text(s,5), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s,6)), endedAt: Date(timeIntervalSince1970: sqlite3_column_double(s,7)), note: text(s,8), source: text(s,9), revision: Int(sqlite3_column_int(s,10))))
        }
        return result
    }
    private func validateHistory(projectID: String, categoryID: String, start: Date, end: Date, note: String, now: Date, allowArchived: Bool) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end, end <= now else {
            throw StoreError.invalid("開始・終了時刻を確認してください。未来の記録は追加できません。")
        }
        guard note.count <= 2000, note.utf8.count <= 32000 else { throw StoreError.invalid("メモは2000文字以内で入力してください。") }
        guard try projects().contains(where: { $0.id == projectID && (allowArchived || !$0.archived) }), try categories().contains(where: { $0.id == categoryID }) else {
            throw StoreError.invalid("プロジェクトまたはカテゴリを確認してください。")
        }
    }
    @discardableResult func addHistory(projectID: String, categoryID: String, start: Date, end: Date, note: String, now: Date = Date()) throws -> String {
        var intervalID = ""
        try transaction {
            try validateHistory(projectID: projectID, categoryID: categoryID, start: start, end: end, note: note, now: now, allowArchived: false)
            let sessionID = UUID().uuidString.lowercased()
            let s = try statement("INSERT INTO sessions(id,project_id,category_id,state,started_at,ended_at) VALUES(?,?,?,'stopped',?,?)"); defer { sqlite3_finalize(s) }
            try bind(sessionID,1,s); try bind(projectID,2,s); try bind(categoryID,3,s); try bind(start.timeIntervalSince1970,4,s); try bind(end.timeIntervalSince1970,5,s); try finish(s)
            intervalID = UUID().uuidString.lowercased()
            let i = try statement("INSERT INTO intervals(id,session_id,project_id,category_id,started_at,ended_at,note,source) VALUES(?,?,?,?,?,?,?,'manual')"); defer { sqlite3_finalize(i) }
            try bind(intervalID,1,i); try bind(sessionID,2,i); try bind(projectID,3,i); try bind(categoryID,4,i); try bind(start.timeIntervalSince1970,5,i); try bind(end.timeIntervalSince1970,6,i); try bind(note,7,i); try finish(i)
            try enqueueHistory(intervalID)
        }
        return intervalID
    }
    private func snapshot(_ entry: LocalHistoryEntry, action: String, now: Date) throws {
        let s = try statement("INSERT INTO interval_revisions(id,interval_id,project_id,category_id,started_at,ended_at,note,source,revision,changed_at,action) VALUES(?,?,?,?,?,?,?,?,?,?,?)"); defer { sqlite3_finalize(s) }
        try bind(UUID().uuidString.lowercased(),1,s); try bind(entry.id,2,s); try bind(entry.projectID,3,s); try bind(entry.categoryID,4,s); try bind(entry.startedAt.timeIntervalSince1970,5,s); try bind(entry.endedAt.timeIntervalSince1970,6,s); try bind(entry.note,7,s); try bind(entry.source,8,s); try bind(Double(entry.revision),9,s); try bind(now.timeIntervalSince1970,10,s); try bind(action,11,s); try finish(s)
    }
    func editHistory(id: String, expectedRevision: Int, projectID: String, categoryID: String, start: Date, end: Date, note: String, now: Date = Date()) throws {
        try transaction {
            guard let entry = try history().first(where: { $0.id == id }), entry.revision == expectedRevision else { throw StoreError.invalid("記録が変更されたため、一覧を更新してからやり直してください。") }
            try validateHistory(projectID: projectID, categoryID: categoryID, start: start, end: end, note: note, now: now, allowArchived: projectID == entry.projectID)
            let overlap = try statement("SELECT COUNT(*) FROM intervals WHERE session_id=? AND id!=? AND deleted_at IS NULL AND started_at < ? AND COALESCE(ended_at,1e99) > ?"); defer { sqlite3_finalize(overlap) }
            try bind(entry.sessionID,1,overlap); try bind(id,2,overlap); try bind(end.timeIntervalSince1970,3,overlap); try bind(start.timeIntervalSince1970,4,overlap)
            guard sqlite3_step(overlap) == SQLITE_ROW, sqlite3_column_int(overlap,0) == 0 else { throw StoreError.invalid("同じ作業の別区間と重複しています。") }
            try snapshot(entry, action: "edit", now: now)
            let s = try statement("UPDATE intervals SET project_id=?,category_id=?,started_at=?,ended_at=?,note=?,revision=revision+1 WHERE id=? AND revision=? AND deleted_at IS NULL"); defer { sqlite3_finalize(s) }
            try bind(projectID,1,s); try bind(categoryID,2,s); try bind(start.timeIntervalSince1970,3,s); try bind(end.timeIntervalSince1970,4,s); try bind(note,5,s); try bind(id,6,s); try bind(Double(expectedRevision),7,s); try finish(s)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalid("記録が変更されました。") }
            try enqueueHistory(id)
        }
    }
    func deleteHistory(id: String, expectedRevision: Int, now: Date = Date()) throws {
        try transaction {
            guard let entry = try history().first(where: { $0.id == id }), entry.revision == expectedRevision else { throw StoreError.invalid("記録が変更されたため、一覧を更新してからやり直してください。") }
            try snapshot(entry, action: "delete", now: now)
            let s = try statement("UPDATE intervals SET deleted_at=?,revision=revision+1 WHERE id=? AND revision=? AND deleted_at IS NULL"); defer { sqlite3_finalize(s) }
            try bind(now.timeIntervalSince1970,1,s); try bind(id,2,s); try bind(Double(expectedRevision),3,s); try finish(s)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalid("記録が変更されました。") }
            try enqueueHistory(id)
        }
    }

    // Called only inside the same SQLite transaction as the history change.
    private func enqueueHistory(_ id: String) throws {
        let bump = try statement("UPDATE intervals SET sync_version=sync_version+1 WHERE id=?"); defer { sqlite3_finalize(bump) }
        try bind(id,1,bump); try finish(bump)
        guard sqlite3_changes(db) == 1 else { throw error() }
        let s = try statement("""
            SELECT i.id,i.session_id,i.project_id,p.name,i.category_id,c.name,i.started_at,i.ended_at,
                   i.note,i.source,i.deleted_at,i.sync_version
            FROM intervals i JOIN projects p ON p.id=i.project_id JOIN categories c ON c.id=i.category_id
            WHERE i.id=? AND i.ended_at IS NOT NULL
            """); defer { sqlite3_finalize(s) }
        try bind(id,1,s); guard sqlite3_step(s) == SQLITE_ROW else { throw error() }
        let record = HistorySyncRecord(id: text(s,0), sessionID: text(s,1), projectID: text(s,2), projectName: text(s,3), categoryID: text(s,4), categoryName: text(s,5), start: sqlite3_column_double(s,6), end: sqlite3_column_double(s,7), note: text(s,8), source: text(s,9), deleted: sqlite3_column_type(s,10) != SQLITE_NULL, version: Int(sqlite3_column_int(s,11)), operationID: UUID().uuidString.lowercased())
        let payload = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let q = try statement("INSERT INTO history_outbox(operation_id,interval_id,version,payload) VALUES(?,?,?,?)"); defer { sqlite3_finalize(q) }
        try bind(record.operationID,1,q); try bind(id,2,q); try bind(Double(record.version),3,q); try bind(payload,4,q); try finish(q)
    }

    func pendingHistoryOperations() throws -> [HistorySyncOperation] {
        let s = try statement("SELECT q.payload FROM history_outbox q LEFT JOIN history_conflicts c ON c.interval_id=q.interval_id WHERE c.interval_id IS NULL ORDER BY q.seq"); defer { sqlite3_finalize(s) }
        var operations: [HistorySyncOperation] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            operations.append(HistorySyncOperation(record: try JSONDecoder().decode(HistorySyncRecord.self, from: Data(text(s,0).utf8))))
        }
        return operations
    }
    func acknowledgeHistoryOperation(_ operationID: String) throws {
        let s = try statement("DELETE FROM history_outbox WHERE operation_id=?"); defer { sqlite3_finalize(s) }
        try bind(operationID,1,s); try finish(s)
    }
    func recordHistoryConflict(_ record: HistorySyncRecord) throws {
        let payload = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let s = try statement("INSERT INTO history_conflicts(interval_id,remote_payload) VALUES(?,?) ON CONFLICT(interval_id) DO UPDATE SET remote_payload=excluded.remote_payload"); defer { sqlite3_finalize(s) }
        try bind(record.id,1,s); try bind(payload,2,s); try finish(s)
    }
    func historySyncCounts() throws -> (pending: Int, conflicts: Int) {
        let s = try statement("SELECT (SELECT COUNT(*) FROM history_outbox), (SELECT COUNT(*) FROM history_conflicts)"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw error() }
        return (Int(sqlite3_column_int(s,0)), Int(sqlite3_column_int(s,1)))
    }
    func historyConflicts() throws -> [HistorySyncConflict] {
        let s = try statement("""
            SELECT c.interval_id,c.remote_payload,
              (SELECT q.payload FROM history_outbox q WHERE q.interval_id=c.interval_id ORDER BY q.seq DESC LIMIT 1)
            FROM history_conflicts c ORDER BY c.interval_id
            """); defer { sqlite3_finalize(s) }
        var result: [HistorySyncConflict] = []
        while true {
            let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }; guard rc == SQLITE_ROW else { throw error() }
            let remote = try JSONDecoder().decode(HistorySyncRecord.self, from: Data(text(s,1).utf8))
            let local = try JSONDecoder().decode(HistorySyncRecord.self, from: Data(text(s,2).utf8))
            result.append(HistorySyncConflict(id: text(s,0), local: local, remote: remote))
        }
        return result
    }
    func resolveHistoryConflict(id: String, keepLocal: Bool) throws {
        try transaction {
            guard let conflict = try historyConflicts().first(where: { $0.id == id }) else { throw StoreError.invalid("競合が見つかりません。") }
            let archive = try statement("INSERT INTO history_resolved_ops(operation_id,interval_id,payload) SELECT operation_id,interval_id,payload FROM history_outbox WHERE interval_id=?"); defer { sqlite3_finalize(archive) }
            try bind(id,1,archive); try finish(archive)
            let resolution = try statement("INSERT INTO history_conflict_resolutions(id,interval_id,remote_payload,choice,resolved_at) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(resolution) }
            let remote = String(decoding: try JSONEncoder().encode(conflict.remote), as: UTF8.self)
            try bind(UUID().uuidString.lowercased(),1,resolution); try bind(id,2,resolution); try bind(remote,3,resolution); try bind(keepLocal ? "local" : "remote",4,resolution); try bind(Date().timeIntervalSince1970,5,resolution); try finish(resolution)
            let removeQueue = try statement("DELETE FROM history_outbox WHERE interval_id=?"); defer { sqlite3_finalize(removeQueue) }
            try bind(id,1,removeQueue); try finish(removeQueue)
            let removeConflict = try statement("DELETE FROM history_conflicts WHERE interval_id=?"); defer { sqlite3_finalize(removeConflict) }
            try bind(id,1,removeConflict); try finish(removeConflict)
            let reset = try statement("UPDATE intervals SET sync_version=? WHERE id=?"); defer { sqlite3_finalize(reset) }
            try bind(Double(keepLocal ? conflict.remote.version : 0),1,reset); try bind(id,2,reset); try finish(reset)
            if keepLocal { try enqueueHistory(id) } else { try applyRemoteHistoryInsideTransaction(conflict.remote) }
        }
    }
    func applyRemoteHistory(_ record: HistorySyncRecord) throws {
        try transaction { try applyRemoteHistoryInsideTransaction(record) }
    }
    func historySyncCursor() throws -> HistorySyncCursor? {
        let s = try statement("SELECT seconds,nanoseconds,operation_id FROM history_sync_cursor WHERE id=1"); defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s); if rc == SQLITE_DONE { return nil }; guard rc == SQLITE_ROW else { throw error() }
        return HistorySyncCursor(seconds: sqlite3_column_int64(s,0), nanoseconds: sqlite3_column_int(s,1), operationID: text(s,2))
    }
    func applyRemoteHistory(_ record: HistorySyncRecord, cursor: HistorySyncCursor) throws {
        try transaction {
            try applyRemoteHistoryInsideTransaction(record)
            let s = try statement("""
                INSERT INTO history_sync_cursor(id,seconds,nanoseconds,operation_id) VALUES(1,?,?,?)
                ON CONFLICT(id) DO UPDATE SET seconds=excluded.seconds,nanoseconds=excluded.nanoseconds,operation_id=excluded.operation_id
                WHERE excluded.seconds>history_sync_cursor.seconds
                   OR (excluded.seconds=history_sync_cursor.seconds AND excluded.nanoseconds>history_sync_cursor.nanoseconds)
                   OR (excluded.seconds=history_sync_cursor.seconds AND excluded.nanoseconds=history_sync_cursor.nanoseconds AND excluded.operation_id>history_sync_cursor.operation_id)
                """); defer { sqlite3_finalize(s) }
            try bind(Double(cursor.seconds),1,s); try bind(Double(cursor.nanoseconds),2,s); try bind(cursor.operationID,3,s); try finish(s)
        }
    }
    func needsHistoryFullSweep(now: Date = Date()) throws -> Bool {
        let s = try statement("SELECT last_full_sweep FROM history_sync_state WHERE id=1"); defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s); if rc == SQLITE_DONE { return true }; guard rc == SQLITE_ROW else { throw error() }
        let elapsed = now.timeIntervalSince1970 - sqlite3_column_double(s,0)
        return elapsed < 0 || elapsed >= 86400
    }
    func markHistoryFullSweep(now: Date = Date()) throws {
        let s = try statement("INSERT INTO history_sync_state(id,last_full_sweep) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET last_full_sweep=excluded.last_full_sweep"); defer { sqlite3_finalize(s) }
        try bind(now.timeIntervalSince1970,1,s); try finish(s)
    }
    private func applyRemoteHistoryInsideTransaction(_ record: HistorySyncRecord) throws {
            let pending = try statement("SELECT COUNT(*) FROM history_outbox WHERE interval_id=?"); defer { sqlite3_finalize(pending) }
            try bind(record.id,1,pending); guard sqlite3_step(pending) == SQLITE_ROW else { throw error() }
            if sqlite3_column_int(pending,0) > 0 { return }
            let existing = try statement("SELECT sync_version FROM intervals WHERE id=?"); defer { sqlite3_finalize(existing) }
            try bind(record.id,1,existing); let rc = sqlite3_step(existing)
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw error() }
            if rc == SQLITE_ROW && Int(sqlite3_column_int(existing,0)) >= record.version { return }
            if let previous = try history().first(where: { $0.id == record.id }) { try snapshot(previous, action: "remote", now: Date()) }
            let project = try statement("INSERT OR IGNORE INTO projects(id,name) VALUES(?,?)"); defer { sqlite3_finalize(project) }
            try bind(record.projectID,1,project); try bind(record.projectName,2,project); try finish(project)
            let category = try statement("INSERT OR IGNORE INTO categories(id,name) VALUES(?,?)"); defer { sqlite3_finalize(category) }
            try bind(record.categoryID,1,category); try bind(record.categoryName,2,category); try finish(category)
            let session = try statement("INSERT OR IGNORE INTO sessions(id,project_id,category_id,state,started_at,ended_at) VALUES(?,?,?,'stopped',?,?)"); defer { sqlite3_finalize(session) }
            try bind(record.sessionID,1,session); try bind(record.projectID,2,session); try bind(record.categoryID,3,session); try bind(record.start,4,session); try bind(record.end,5,session); try finish(session)
            let entry = try statement("""
                INSERT INTO intervals(id,session_id,project_id,category_id,started_at,ended_at,note,source,deleted_at,sync_version)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,category_id=excluded.category_id,
                  started_at=excluded.started_at,ended_at=excluded.ended_at,note=excluded.note,source=excluded.source,
                  deleted_at=excluded.deleted_at,sync_version=excluded.sync_version,revision=intervals.revision+1
                """); defer { sqlite3_finalize(entry) }
            try bind(record.id,1,entry); try bind(record.sessionID,2,entry); try bind(record.projectID,3,entry); try bind(record.categoryID,4,entry); try bind(record.start,5,entry); try bind(record.end,6,entry); try bind(record.note,7,entry); try bind(record.source,8,entry)
            if record.deleted { try bind(Date().timeIntervalSince1970,9,entry) } else { sqlite3_bind_null(entry,9) }
            try bind(Double(record.version),10,entry); try finish(entry)
    }
}
