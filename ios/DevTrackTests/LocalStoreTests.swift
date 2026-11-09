import XCTest
import SQLite3
@testable import DevTrack

final class LocalStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testPauseResumeStopAndRestartPersistence() throws {
        let path = try LocalStore.url(for: "alice", directory: dir).path
        var store: LocalStore? = try LocalStore(path: path)
        let project = try store!.addProject("Alpha")
        try store!.start(projectID: project, categoryID: "general", at: time(100))
        XCTAssertEqual(try store!.active(at: time(160))?.seconds, 60)
        try store!.pause(at: time(160))
        XCTAssertEqual(try store!.active(at: time(240))?.seconds, 60)
        store = nil
        store = try LocalStore(path: path)
        XCTAssertEqual(try store!.active(at: time(240))?.state, "paused")
        try store!.resume(at: time(260))
        XCTAssertEqual(try store!.active(at: time(290))?.seconds, 90)
        store = nil
        store = try LocalStore(path: path)
        XCTAssertEqual(try store!.active(at: time(300))?.seconds, 100)
        try store!.stop(at: time(320))
        XCTAssertNil(try store!.active(at: time(400)))
        XCTAssertEqual(try store!.sessions(at: time(400)).first?.seconds, 120)
    }

    func testChangeSplitsIntervalsAndPreservesTime() throws {
        let path = try LocalStore.url(for: "alice", directory: dir).path
        let store = try LocalStore(path: path)
        let first = try store.addProject("A"); let second = try store.addProject("B")
        let category = try store.addCategory("Review")
        try store.start(projectID: first, categoryID: "general", at: time(100))
        try store.change(projectID: second, categoryID: category, at: time(160))
        try store.stop(at: time(200))
        XCTAssertEqual(try store.sessions(at: time(300)).first?.seconds, 100)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT project_id),COUNT(DISTINCT category_id),COUNT(*) FROM intervals", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 2); XCTAssertEqual(sqlite3_column_int(stmt, 1), 2); XCTAssertEqual(sqlite3_column_int(stmt, 2), 2)
    }

    func testAccountIsolationAndInvalidTransitions() throws {
        let a = try LocalStore(path: LocalStore.url(for: "alice", directory: dir).path)
        let b = try LocalStore(path: LocalStore.url(for: "bob", directory: dir).path)
        let project = try a.addProject("A")
        XCTAssertTrue(try b.projects().isEmpty)
        XCTAssertThrowsError(try b.start(projectID: project, categoryID: "general", at: time(100)))
        try a.start(projectID: project, categoryID: "general", at: time(100))
        XCTAssertThrowsError(try a.start(projectID: project, categoryID: "general", at: time(120)))
        XCTAssertThrowsError(try a.pause(at: time(99)))
        XCTAssertEqual(try a.active(at: time(120))?.state, "running")
        XCTAssertThrowsError(try a.archiveProject(project))
        try a.pause(at: time(120))
        XCTAssertThrowsError(try a.resume(at: time(119)))
        XCTAssertEqual(try a.active(at: time(130))?.seconds, 20)
        try a.stop(at: time(140)); try a.archiveProject(project)
        XCTAssertTrue(try a.projects().first!.archived)
    }

    func testHistoryAddEditDeletePreservesPreviousVersions() throws {
        let path = try LocalStore.url(for: "history", directory: dir).path
        var store: LocalStore? = try LocalStore(path: path)
        let project = try store!.addProject("A")
        let id = try store!.addHistory(projectID: project, categoryID: "general", start: time(100), end: time(200), note: "initial", now: time(300))
        XCTAssertEqual(try store!.history().first?.source, "manual")
        XCTAssertThrowsError(try store!.addHistory(projectID: project, categoryID: "general", start: time(200), end: time(100), note: "", now: time(300)))
        try store!.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: time(120), end: time(240), note: "updated", now: time(300))
        XCTAssertEqual(try store!.history().first?.revision, 2)
        XCTAssertEqual(try store!.sessions(at: time(300)).first?.seconds, 120)
        XCTAssertThrowsError(try store!.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: time(110), end: time(220), note: "stale", now: time(300)))
        store = nil; store = try LocalStore(path: path)
        XCTAssertEqual(try store!.history().first?.note, "updated")
        XCTAssertThrowsError(try store!.deleteHistory(id: id, expectedRevision: 1, now: time(310)))
        try store!.deleteHistory(id: id, expectedRevision: 2, now: time(310))
        XCTAssertTrue(try store!.history().isEmpty)
        XCTAssertTrue(try store!.sessions().isEmpty)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT (SELECT COUNT(*) FROM interval_revisions), (SELECT COUNT(*) FROM intervals WHERE deleted_at IS NOT NULL)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }; XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 2); XCTAssertEqual(sqlite3_column_int(stmt, 1), 1)
    }

    func testHistoryEditKeepsOtherTimerIntervalsAndRejectsOverlap() throws {
        let store = try LocalStore(path: LocalStore.url(for: "history", directory: dir).path)
        let project = try store.addProject("A")
        try store.start(projectID: project, categoryID: "general", at: time(100))
        try store.pause(at: time(150)); try store.resume(at: time(200)); try store.stop(at: time(250))
        let entries = try store.history()
        XCTAssertEqual(entries.count, 2)
        let first = try XCTUnwrap(entries.first { $0.startedAt == time(100) })
        XCTAssertThrowsError(try store.editHistory(id: first.id, expectedRevision: first.revision, projectID: project, categoryID: "general", start: time(120), end: time(210), note: "", now: time(300)))
        XCTAssertEqual(try store.history().first { $0.id == first.id }?.endedAt, time(150))
        try store.editHistory(id: first.id, expectedRevision: first.revision, projectID: project, categoryID: "general", start: time(110), end: time(160), note: "corrected", now: time(300))
        XCTAssertEqual(try store.history().count, 2)
        XCTAssertEqual(try store.sessions(at: time(300)).first?.seconds, 100)
    }

    func testMigratesVersionOneWithoutLosingRunningTimer() throws {
        let path = try LocalStore.url(for: "migration", directory: dir).path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let schema = """
            CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,archived INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE categories(id TEXT PRIMARY KEY,name TEXT NOT NULL);
            CREATE TABLE sessions(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,category_id TEXT NOT NULL,state TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL);
            CREATE TABLE intervals(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,project_id TEXT NOT NULL,category_id TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL);
            INSERT INTO projects VALUES('p','Old',0); INSERT INTO categories VALUES('general','一般');
            INSERT INTO sessions VALUES('s','p','general','running',100,NULL); INSERT INTO intervals VALUES('i','s','p','general',100,NULL);
            PRAGMA user_version=1;
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try LocalStore(path: path)
        XCTAssertEqual(try store.active(at: time(140))?.seconds, 40)
        try store.stop(at: time(150))
        XCTAssertEqual(try store.history().first?.id, "i")
        XCTAssertEqual(try store.history().first?.revision, 1)
    }

    func testHistoryOutboxSurvivesRestartAndKeepsEveryChange() throws {
        let path = try LocalStore.url(for: "sync", directory: dir).path
        var store: LocalStore? = try LocalStore(path: path)
        let project = try store!.addProject("Sync")
        let id = try store!.addHistory(projectID: project, categoryID: "general", start: time(100), end: time(200), note: "first", now: time(300))
        try store!.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: time(110), end: time(200), note: "second", now: time(300))
        try store!.deleteHistory(id: id, expectedRevision: 2, now: time(300))
        store = nil; store = try LocalStore(path: path)
        let queued = try store!.pendingHistoryOperations().map(\.record)
        XCTAssertEqual(queued.map(\.version), [1, 2, 3])
        XCTAssertEqual(queued.map(\.note), ["first", "second", "second"])
        XCTAssertEqual(queued.map(\.deleted), [false, false, true])
        XCTAssertEqual(Set(queued.map(\.operationID)).count, 3)
        try store!.acknowledgeHistoryOperation(queued[0].operationID)
        try store!.acknowledgeHistoryOperation(queued[0].operationID)
        XCTAssertEqual(try store!.pendingHistoryOperations().map(\.record.version), [2, 3])
    }

    func testRemoteChangesAndConflictsPreserveLocalChanges() throws {
        let a = try LocalStore(path: LocalStore.url(for: "device-a", directory: dir).path)
        let b = try LocalStore(path: LocalStore.url(for: "device-b", directory: dir).path)
        let project = try a.addProject("Project")
        let id = try a.addHistory(projectID: project, categoryID: "general", start: time(100), end: time(200), note: "first", now: time(300))
        let original = try XCTUnwrap(a.pendingHistoryOperations().first?.record)
        try b.applyRemoteHistory(original)
        XCTAssertEqual(try b.history().first?.note, "first")
        XCTAssertTrue(try b.pendingHistoryOperations().isEmpty)
        try a.acknowledgeHistoryOperation(original.operationID)
        try a.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: time(100), end: time(200), note: "A", now: time(300))
        try b.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: time(100), end: time(200), note: "B", now: time(300))
        let aChange = try XCTUnwrap(a.pendingHistoryOperations().first?.record)
        try b.recordHistoryConflict(aChange)
        try b.applyRemoteHistory(aChange)
        XCTAssertEqual(try b.history().first?.note, "B")
        XCTAssertEqual(try b.historySyncCounts().conflicts, 1)
        XCTAssertEqual(try b.historySyncCounts().pending, 1)
        XCTAssertTrue(try b.pendingHistoryOperations().isEmpty)
    }

    func testHistoryCursorSurvivesRestartAndNeverMovesBackwards() throws {
        let a = try LocalStore(path: LocalStore.url(for: "cursor-a", directory: dir).path)
        let path = try LocalStore.url(for: "cursor-b", directory: dir).path
        var b: LocalStore? = try LocalStore(path: path)
        let project = try a.addProject("Project")
        _ = try a.addHistory(projectID: project, categoryID: "general", start: time(100), end: time(200), note: "entry", now: time(300))
        let record = try XCTUnwrap(a.pendingHistoryOperations().first?.record)
        try b!.applyRemoteHistory(record, cursor: HistorySyncCursor(seconds: 1000, nanoseconds: 20, operationID: "b"))
        try b!.applyRemoteHistory(record, cursor: HistorySyncCursor(seconds: 1000, nanoseconds: 20, operationID: "a"))
        try b!.applyRemoteHistory(record, cursor: HistorySyncCursor(seconds: 999, nanoseconds: 999, operationID: "z"))
        XCTAssertTrue(try b!.needsHistoryFullSweep(now: time(1000)))
        try b!.markHistoryFullSweep(now: time(1000))
        b = nil; b = try LocalStore(path: path)
        let cursor = try XCTUnwrap(b!.historySyncCursor())
        XCTAssertEqual(cursor.seconds, 1000); XCTAssertEqual(cursor.nanoseconds, 20); XCTAssertEqual(cursor.operationID, "b")
        XCTAssertFalse(try b!.needsHistoryFullSweep(now: time(1100)))
        XCTAssertTrue(try b!.needsHistoryFullSweep(now: time(1000 + 86400)))
        XCTAssertTrue(try b!.needsHistoryFullSweep(now: time(999)))
    }

    func testMigrationQueuesExistingEditedAndDeletedHistoryOnce() throws {
        let path = try LocalStore.url(for: "old-history", directory: dir).path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let schema = """
            CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,archived INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE categories(id TEXT PRIMARY KEY,name TEXT NOT NULL);
            CREATE TABLE sessions(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,category_id TEXT NOT NULL,state TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL);
            CREATE TABLE intervals(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,project_id TEXT NOT NULL,category_id TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL,deleted_at REAL,note TEXT NOT NULL DEFAULT '',source TEXT NOT NULL DEFAULT 'timer',revision INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE interval_revisions(id TEXT PRIMARY KEY,interval_id TEXT NOT NULL,project_id TEXT NOT NULL,category_id TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL NOT NULL,note TEXT NOT NULL,source TEXT NOT NULL,revision INTEGER NOT NULL,changed_at REAL NOT NULL,action TEXT NOT NULL);
            INSERT INTO projects VALUES('p','Old',0); INSERT INTO categories VALUES('general','一般');
            INSERT INTO sessions VALUES('s1','p','general','stopped',100,200),('s2','p','general','stopped',300,400);
            INSERT INTO intervals VALUES('i1','s1','p','general',100,200,NULL,'edited','manual',3),('i2','s2','p','general',300,400,500,'deleted','timer',2);
            PRAGMA user_version=2;
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        var store: LocalStore? = try LocalStore(path: path)
        let queued = try store!.pendingHistoryOperations().map(\.record)
        XCTAssertEqual(queued.map(\.version), [1, 1]); XCTAssertEqual(queued.map(\.note), ["edited", "deleted"])
        XCTAssertEqual(queued.map(\.deleted), [false, true])
        store = nil; store = try LocalStore(path: path)
        XCTAssertEqual(try store!.pendingHistoryOperations().count, 2)
    }
}
