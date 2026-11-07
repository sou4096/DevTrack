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
}
