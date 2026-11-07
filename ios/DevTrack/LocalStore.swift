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

enum StoreError: LocalizedError {
    case database(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .database: return "データベースを操作できませんでした。"
        case .invalid(let message): return message
        }
    }
}

/// A separate database per authenticated UID; no data or credential is sent to the network.
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
        guard version <= 1 else { throw StoreError.invalid("新しいバージョンのデータベースです。") }
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
        guard !name.isEmpty, name.count <= 100 else { throw StoreError.invalid("名前は1〜100文字で入力してください。") }
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
              COALESCE((SELECT SUM(MAX(0,COALESCE(i.ended_at,?)-i.started_at)) FROM intervals i WHERE i.session_id=s.id),0)
            FROM sessions s JOIN projects p ON p.id=s.project_id JOIN categories c ON c.id=s.category_id
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
}
