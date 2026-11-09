import Foundation
import FirebaseAuth
import FirebaseFirestore

private final class SyncCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

/// SQLite owns the durable outbox. Firestore transactions only ever send one
/// immutable operation and its corresponding record together.
@MainActor
final class HistorySync {
    private let userID: String
    private let store: LocalStore
    private let db: Firestore
    private let auth: Auth

    init(userID: String, store: LocalStore, db: Firestore = Firestore.firestore(), auth: Auth = Auth.auth()) {
        self.userID = userID; self.store = store; self.db = db; self.auth = auth
    }

    private func checkAccount() throws {
        guard !Task.isCancelled, auth.currentUser?.uid == userID else {
            throw SyncError.accountChanged
        }
    }

    func synchronize() async throws {
        try checkAccount()
        let user = db.collection("users").document(userID)
        var blocked = Set<String>()
        for operation in try store.pendingHistoryOperations() {
            try checkAccount()
            let record = operation.record
            if blocked.contains(record.id) { continue }
            let payload = try Self.dictionary(record)
            let historyRef = user.collection("history").document(record.id)
            let opRef = user.collection("historyOps").document(record.operationID)
            let outcome = try await runTransaction { transaction, errorPointer -> Any? in
                do {
                    let marker = try transaction.getDocument(opRef)
                    if marker.exists {
                        guard var data = marker.data() else { throw SyncError.invalidData }
                        data.removeValue(forKey: "committedAt")
                        guard try Self.record(data) == record else {
                            throw SyncError.invalidData
                        }
                        return ["result": "ack"]
                    }
                    let current = try transaction.getDocument(historyRef)
                    if let data = current.data() {
                        guard let version = (data["version"] as? NSNumber)?.intValue else { throw SyncError.invalidData }
                        if version != record.version - 1 { return ["result": "conflict", "remote": data] }
                    } else if record.version != 1 { throw SyncError.missingBase }
                    transaction.setData(payload, forDocument: historyRef)
                    var immutable = payload
                    immutable["committedAt"] = FieldValue.serverTimestamp()
                    transaction.setData(immutable, forDocument: opRef)
                    return ["result": "ack"]
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }
            try checkAccount()
            guard let result = outcome as? [String: Any], let status = result["result"] as? String else { throw SyncError.invalidData }
            if status == "ack" {
                try store.acknowledgeHistoryOperation(record.operationID)
            } else if status == "conflict", let remote = result["remote"] as? [String: Any] {
                let remoteRecord = try Self.record(remote)
                guard remoteRecord.id == record.id else { throw SyncError.invalidData }
                try store.recordHistoryConflict(remoteRecord)
                blocked.insert(record.id)
            } else { throw SyncError.invalidData }
        }
        try checkAccount()
        let fullSweep = try store.needsHistoryFullSweep()
        let cursor = try store.historySyncCursor()
        var query: Query = user.collection("historyOps").order(by: "committedAt").order(by: FieldPath.documentID())
        if !fullSweep, let cursor {
            // Overlap recent writes so equal server timestamps cannot hide a late-arriving operation.
            query = query.whereField("committedAt", isGreaterThanOrEqualTo: Timestamp(seconds: cursor.seconds - 300, nanoseconds: 0))
        }
        var pageQuery = query.limit(to: 100)
        while true {
            let snapshot = try await readServer(pageQuery)
            try checkAccount()
            for doc in snapshot.documents {
                var data = doc.data()
                guard let committed = data.removeValue(forKey: "committedAt") as? Timestamp else { throw SyncError.invalidData }
                let record = try Self.record(data)
                guard record.operationID == doc.documentID else { throw SyncError.invalidData }
                try store.applyRemoteHistory(record, cursor: HistorySyncCursor(seconds: committed.seconds, nanoseconds: committed.nanoseconds, operationID: doc.documentID))
            }
            guard snapshot.documents.count == 100, let last = snapshot.documents.last else { break }
            pageQuery = query.start(afterDocument: last).limit(to: 100)
        }
        if fullSweep { try store.markHistoryFullSweep() }
    }

    private func runTransaction(_ block: @escaping (Transaction, NSErrorPointer) -> Any?) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            let completion = SyncCompletion<Any?>(continuation)
            db.runTransaction(block) { value, error in
                if let error { completion.finish(.failure(error)) } else { completion.finish(.success(value)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { completion.finish(.failure(SyncError.timeout)) }
        }
    }
    private func readServer(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let completion = SyncCompletion<QuerySnapshot>(continuation)
            query.getDocuments(source: .server) { value, error in
                if let error { completion.finish(.failure(error)) }
                else if let value { completion.finish(.success(value)) }
                else { completion.finish(.failure(SyncError.invalidData)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { completion.finish(.failure(SyncError.timeout)) }
        }
    }

    private static func dictionary(_ record: HistorySyncRecord) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else { throw SyncError.invalidData }
        return value
    }
    private static func record(_ data: [String: Any]) throws -> HistorySyncRecord {
        let result = try JSONDecoder().decode(HistorySyncRecord.self, from: JSONSerialization.data(withJSONObject: data))
        guard result.version > 0, result.start.isFinite, result.end.isFinite, result.start <= result.end,
              !result.id.isEmpty, !result.sessionID.isEmpty, !result.projectID.isEmpty, !result.categoryID.isEmpty,
              !result.operationID.isEmpty, ["timer", "manual"].contains(result.source) else { throw SyncError.invalidData }
        return result
    }
}

enum SyncError: LocalizedError {
    case accountChanged, invalidData, missingBase, timeout
    var errorDescription: String? {
        switch self {
        case .accountChanged: return "アカウントが変更されたため同期を停止しました。"
        case .invalidData: return "同期データを確認できませんでした。"
        case .missingBase: return "同期先に以前の記録が見つかりません。"
        case .timeout: return "通信がタイムアウトしました。"
        }
    }
}
