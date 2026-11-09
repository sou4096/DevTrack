import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import DevTrack

final class HistorySyncIntegrationTests: XCTestCase {
    func testTwoDevicesRetryIdempotentlyAndPreserveConflicts() {
        let done = expectation(description: "sync integration")
        Task { @MainActor in
            do { try await exerciseSync() } catch { XCTFail("Sync integration failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
    }

    @MainActor private func exerciseSync() async throws {
        let name = "sync-test-\(UUID().uuidString)"
        let options = FirebaseOptions(googleAppID: "1:123456789012:ios:1234567890abcdef", gcmSenderID: "123456789012")
        options.apiKey = "demo-key"; options.projectID = "demo-devtrack"
        FirebaseApp.configure(name: name, options: options)
        let app = try XCTUnwrap(FirebaseApp.app(name: name))
        let auth = Auth.auth(app: app)
        auth.useEmulator(withHost: "127.0.0.1", port: 9099)
        let db = Firestore.firestore(app: app)
        let settings = db.settings; settings.cacheSettings = MemoryCacheSettings(); settings.host = "127.0.0.1:8080"; settings.isSSLEnabled = false; db.settings = settings
        let email = "sync-\(UUID().uuidString.lowercased())@example.test"
        let password = "test-password-123"
        let uid = try await auth.createUser(withEmail: email, password: password).user.uid
        FirebaseApp.configure(name: "\(name)-device-b", options: options)
        let appB = try XCTUnwrap(FirebaseApp.app(name: "\(name)-device-b"))
        let authB = Auth.auth(app: appB)
        authB.useEmulator(withHost: "127.0.0.1", port: 9099)
        let otherUID = try await authB.signIn(withEmail: email, password: password).user.uid
        XCTAssertEqual(otherUID, uid)
        let dbB = Firestore.firestore(app: appB)
        let settingsB = dbB.settings; settingsB.cacheSettings = MemoryCacheSettings(); settingsB.host = "127.0.0.1:8080"; settingsB.isSSLEnabled = false; dbB.settings = settingsB
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try LocalStore(path: directory.appendingPathComponent("a.sqlite").path)
        let b = try LocalStore(path: directory.appendingPathComponent("b.sqlite").path)
        let syncA = HistorySync(userID: uid, store: a, db: db, auth: auth)
        let syncB = HistorySync(userID: uid, store: b, db: dbB, auth: authB)
        let project = try a.addProject("Project")
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
        let id = try a.addHistory(projectID: project, categoryID: "general", start: start, end: end, note: "original")
        FirebaseApp.configure(name: "\(name)-offline", options: options)
        let offlineApp = try XCTUnwrap(FirebaseApp.app(name: "\(name)-offline"))
        let offlineDB = Firestore.firestore(app: offlineApp)
        let offlineSettings = offlineDB.settings; offlineSettings.cacheSettings = MemoryCacheSettings(); offlineSettings.host = "127.0.0.1:1"; offlineSettings.isSSLEnabled = false; offlineDB.settings = offlineSettings
        let offline = HistorySync(userID: uid, store: a, db: offlineDB, auth: auth)
        do { try await offline.synchronize(); XCTFail("Offline synchronization should fail") } catch { }
        XCTAssertEqual(try a.historySyncCounts().pending, 1)
        let reopened = try LocalStore(path: directory.appendingPathComponent("a.sqlite").path)
        XCTAssertEqual(try reopened.historySyncCounts().pending, 1)
        try await syncA.synchronize()
        XCTAssertEqual(try a.historySyncCounts().pending, 0)

        // Simulate a successful commit whose acknowledgement was lost.
        let secondID = try a.addHistory(projectID: project, categoryID: "general", start: start, end: end, note: "another")
        let second = try XCTUnwrap(a.pendingHistoryOperations().first?.record)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
        let root = db.collection("users").document(uid)
        let batch = db.batch()
        batch.setData(payload, forDocument: root.collection("history").document(secondID))
        var operationPayload = payload
        operationPayload["committedAt"] = FieldValue.serverTimestamp()
        batch.setData(operationPayload, forDocument: root.collection("historyOps").document(second.operationID))
        try await batch.commit()
        try await syncA.synchronize()
        XCTAssertEqual(try a.historySyncCounts().pending, 0)
        try await syncB.synchronize()
        XCTAssertEqual(try b.history().first(where: { $0.id == id })?.note, "original")

        try a.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: start, end: end, note: "device A")
        try b.editHistory(id: id, expectedRevision: 1, projectID: project, categoryID: "general", start: start, end: end, note: "device B")
        try await syncA.synchronize()
        try await syncB.synchronize()
        XCTAssertEqual(try b.history().first(where: { $0.id == id })?.note, "device B")
        XCTAssertEqual(try b.historySyncCounts().conflicts, 1)
        XCTAssertEqual(try b.historySyncCounts().pending, 1)
        XCTAssertTrue(try b.pendingHistoryOperations().isEmpty)
        try b.resolveHistoryConflict(id: id, keepLocal: true)
        XCTAssertEqual(try b.pendingHistoryOperations().first?.record.version, 3)
        try await syncB.synchronize()
        try await syncA.synchronize()
        XCTAssertEqual(try a.history().first(where: { $0.id == id })?.note, "device B")
        try a.editHistory(id: id, expectedRevision: 3, projectID: project, categoryID: "general", start: start, end: end, note: "remote choice")
        try b.editHistory(id: id, expectedRevision: 2, projectID: project, categoryID: "general", start: start, end: end, note: "local archived")
        try await syncA.synchronize()
        try await syncB.synchronize()
        XCTAssertEqual(try b.historySyncCounts().conflicts, 1)
        try b.resolveHistoryConflict(id: id, keepLocal: false)
        XCTAssertEqual(try b.history().first(where: { $0.id == id })?.note, "remote choice")
        XCTAssertEqual(try b.historySyncCounts().pending, 0)
        XCTAssertEqual(try b.historySyncCounts().conflicts, 0)
        try a.deleteHistory(id: secondID, expectedRevision: 1)
        try await syncA.synchronize()
        try await syncB.synchronize()
        XCTAssertFalse(try b.history().contains(where: { $0.id == secondID }))
        XCTAssertEqual(try b.history().first(where: { $0.id == id })?.note, "remote choice")
    }
}
