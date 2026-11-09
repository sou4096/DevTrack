use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Record {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub project_name: String,
    #[serde(rename = "categoryID")]
    pub category_id: String,
    pub category_name: String,
    pub start: f64,
    pub end: f64,
    pub note: String,
    pub source: String,
    pub deleted: bool,
    pub version: i64,
    #[serde(rename = "operationID")]
    pub operation_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Edit {
    pub id: Option<String>,
    pub expected_version: Option<i64>,
    pub project_name: String,
    pub category_name: String,
    pub start: f64,
    pub end: f64,
    pub note: String,
}
#[derive(Serialize)]
pub struct Conflict {
    pub local: Record,
    pub remote: Record,
}
#[derive(Serialize)]
pub struct State {
    pub records: Vec<Record>,
    pub conflicts: Vec<Conflict>,
    pub pending: i64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Cursor {
    pub seconds: i64,
    pub nanoseconds: i32,
    #[serde(rename = "operationID")]
    pub operation_id: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncInfo {
    pub cursor: Option<Cursor>,
    pub full_sweep: bool,
}

fn uid(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
fn id() -> String {
    Uuid::new_v4().to_string()
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn validate(r: &Record) -> Result<(), String> {
    if ![
        &r.id,
        &r.session_id,
        &r.project_id,
        &r.category_id,
        &r.operation_id,
    ]
    .iter()
    .all(|s| valid_id(s))
        || r.project_name.trim().is_empty()
        || r.category_name.trim().is_empty()
        || r.project_name.len() > 16000
        || r.category_name.len() > 16000
        || r.note.len() > 32000
        || !r.start.is_finite()
        || !r.end.is_finite()
        || r.start < -62135596800.0
        || r.end >= 253402300800.0
        || r.start > r.end
        || r.version < 1
        || !["timer", "manual"].contains(&r.source.as_str())
    {
        return Err("記録の内容を確認してください。".into());
    }
    Ok(())
}
fn encode(r: &Record) -> Result<String, String> {
    serde_json::to_string(r).map_err(|_| "記録を保存できません。".into())
}
fn decode(s: String) -> Result<Record, String> {
    let r: Record =
        serde_json::from_str(&s).map_err(|_| "同期データを読み取れません。".to_string())?;
    validate(&r)?;
    Ok(r)
}
fn err(e: impl std::fmt::Display) -> String {
    let _ = e;
    "端末の履歴データを操作できませんでした。".into()
}

pub fn open(base: &Path, user: &str) -> Result<Connection, String> {
    if user.is_empty() || user.len() > 128 {
        return Err("アカウントを確認できません。".into());
    }
    std::fs::create_dir_all(base).map_err(err)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(base, std::fs::Permissions::from_mode(0o700)).map_err(err)?;
    }
    let path: PathBuf = base.join(format!("history-{}.sqlite", uid(user)));
    let c = Connection::open(&path).map_err(err)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).map_err(err)?;
    }
    c.busy_timeout(Duration::from_secs(5)).map_err(err)?;
    c.execute_batch("PRAGMA foreign_keys=ON;").map_err(err)?;
    let version: i64 = c
        .pragma_query_value(None, "user_version", |r| r.get(0))
        .map_err(err)?;
    if version > 1 {
        return Err("新しいバージョンの履歴データベースです。".into());
    }
    if version == 0 {
        c.execute_batch("BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, version INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, record_id TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conflicts(record_id TEXT PRIMARY KEY, remote_payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS revisions(id INTEGER PRIMARY KEY AUTOINCREMENT, record_id TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS resolved_operations(operation_id TEXT PRIMARY KEY, record_id TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS resolutions(id TEXT PRIMARY KEY, record_id TEXT NOT NULL, remote_payload TEXT NOT NULL, choice TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_cursor(id INTEGER PRIMARY KEY CHECK(id=1), seconds INTEGER NOT NULL, nanoseconds INTEGER NOT NULL, operation_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_state(id INTEGER PRIMARY KEY CHECK(id=1), last_sweep REAL NOT NULL);
        PRAGMA user_version=1; COMMIT;").map_err(err)?;
    }
    Ok(c)
}
fn current(tx: &Transaction<'_>, key: &str) -> Result<Option<Record>, String> {
    let payload: Option<String> = tx
        .query_row("SELECT payload FROM records WHERE id=?", [key], |r| {
            r.get(0)
        })
        .optional()
        .map_err(err)?;
    payload.map(decode).transpose()
}
fn archive(tx: &Transaction<'_>, r: &Record) -> Result<(), String> {
    tx.execute(
        "INSERT INTO revisions(record_id,payload) VALUES(?,?)",
        params![r.id, encode(r)?],
    )
    .map_err(err)?;
    Ok(())
}
fn put(tx: &Transaction<'_>, r: &Record) -> Result<(), String> {
    validate(r)?;
    tx.execute("INSERT INTO records(id,version,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,payload=excluded.payload", params![r.id,r.version,encode(r)?]).map_err(err)?;
    Ok(())
}
fn enqueue(tx: &Transaction<'_>, r: &Record) -> Result<(), String> {
    tx.execute(
        "INSERT INTO outbox(operation_id,record_id,payload) VALUES(?,?,?)",
        params![r.operation_id, r.id, encode(r)?],
    )
    .map_err(err)?;
    Ok(())
}
fn named_id(tx: &Transaction<'_>, name: &str, project: bool) -> Result<String, String> {
    if !project && name == "一般" {
        return Ok("general".into());
    }
    let mut query = tx.prepare("SELECT payload FROM records").map_err(err)?;
    let items = query
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(err)?;
    let mut ids = std::collections::BTreeSet::new();
    for item in items {
        let record = decode(item.map_err(err)?)?;
        if project && record.project_name == name {
            ids.insert(record.project_id);
        } else if !project && record.category_name == name {
            ids.insert(record.category_id);
        }
    }
    if ids.len() > 1 {
        return Err("同じ名前の項目が複数あるため、この名前では自動選択できません。".into());
    }
    Ok(ids.into_iter().next().unwrap_or_else(id))
}
pub fn save(c: &mut Connection, e: Edit) -> Result<Record, String> {
    let project = e.project_name.trim().to_owned();
    let category = e.category_name.trim().to_owned();
    if project.chars().count() > 100
        || category.chars().count() > 100
        || e.note.chars().count() > 2000
        || e.start >= e.end
        || e.end > now()
    {
        return Err("名前、メモ、開始・終了時刻を確認してください。".into());
    }
    let tx = c.transaction().map_err(err)?;
    let r = if let Some(key) = e.id {
        let old = current(&tx, &key)?.ok_or("記録が見つかりません。")?;
        if old.deleted || e.expected_version != Some(old.version) {
            return Err("記録が変更されました。一覧を更新してください。".into());
        }
        let mut query = tx
            .prepare("SELECT payload FROM records WHERE id != ?")
            .map_err(err)?;
        let items = query
            .query_map([&key], |row| row.get::<_, String>(0))
            .map_err(err)?;
        for item in items {
            let other = decode(item.map_err(err)?)?;
            if other.session_id == old.session_id
                && !other.deleted
                && other.start < e.end
                && other.end > e.start
            {
                return Err("同じ作業の別区間と重複しています。".into());
            }
        }
        drop(query);
        archive(&tx, &old)?;
        Record {
            id: old.id,
            session_id: old.session_id,
            project_id: if old.project_name == project {
                old.project_id
            } else {
                named_id(&tx, &project, true)?
            },
            project_name: project,
            category_id: if old.category_name == category {
                old.category_id
            } else {
                named_id(&tx, &category, false)?
            },
            category_name: category,
            start: e.start,
            end: e.end,
            note: e.note,
            source: old.source,
            deleted: false,
            version: old.version + 1,
            operation_id: id(),
        }
    } else {
        Record {
            id: id(),
            session_id: id(),
            project_id: named_id(&tx, &project, true)?,
            project_name: project,
            category_id: named_id(&tx, &category, false)?,
            category_name: category,
            start: e.start,
            end: e.end,
            note: e.note,
            source: "manual".into(),
            deleted: false,
            version: 1,
            operation_id: id(),
        }
    };
    put(&tx, &r)?;
    enqueue(&tx, &r)?;
    tx.commit().map_err(err)?;
    Ok(r)
}
pub fn delete(c: &mut Connection, key: &str, expected: i64) -> Result<(), String> {
    let tx = c.transaction().map_err(err)?;
    let old = current(&tx, key)?.ok_or("記録が見つかりません。")?;
    if old.deleted || old.version != expected {
        return Err("記録が変更されました。一覧を更新してください。".into());
    }
    archive(&tx, &old)?;
    let mut r = old;
    r.deleted = true;
    r.version += 1;
    r.operation_id = id();
    put(&tx, &r)?;
    enqueue(&tx, &r)?;
    tx.commit().map_err(err)?;
    Ok(())
}
pub fn state(c: &Connection) -> Result<State, String> {
    let mut s = c.prepare("SELECT payload FROM records").map_err(err)?;
    let records = s
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(err)?
        .map(|r| decode(r.map_err(err)?))
        .collect::<Result<Vec<_>, String>>()?;
    let mut records: Vec<_> = records.into_iter().filter(|r| !r.deleted).collect();
    records.sort_by(|a, b| b.start.total_cmp(&a.start).then(a.id.cmp(&b.id)));
    let mut s = c.prepare("SELECT c.remote_payload,(SELECT q.payload FROM outbox q WHERE q.record_id=c.record_id ORDER BY q.seq DESC LIMIT 1) FROM conflicts c ORDER BY c.record_id").map_err(err)?;
    let conflicts = s
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(err)?
        .map(|r| {
            let (remote, local) = r.map_err(err)?;
            Ok(Conflict {
                local: decode(local)?,
                remote: decode(remote)?,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let pending = c
        .query_row("SELECT COUNT(*) FROM outbox", [], |r| r.get(0))
        .map_err(err)?;
    Ok(State {
        records,
        conflicts,
        pending,
    })
}
pub fn pending(c: &Connection) -> Result<Vec<Record>, String> {
    let mut s = c.prepare("SELECT o.payload FROM outbox o LEFT JOIN conflicts c ON o.record_id=c.record_id WHERE c.record_id IS NULL ORDER BY o.seq").map_err(err)?;
    let result = s
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(err)?
        .map(|r| decode(r.map_err(err)?))
        .collect();
    result
}
pub fn ack(c: &Connection, op: &str) -> Result<(), String> {
    c.execute("DELETE FROM outbox WHERE operation_id=?", [op])
        .map_err(err)?;
    Ok(())
}
pub fn conflict(c: &Connection, r: Record) -> Result<(), String> {
    validate(&r)?;
    c.execute("INSERT INTO conflicts(record_id,remote_payload) VALUES(?,?) ON CONFLICT(record_id) DO UPDATE SET remote_payload=excluded.remote_payload",params![r.id,encode(&r)?]).map_err(err)?;
    Ok(())
}
fn apply(tx: &Transaction<'_>, r: &Record) -> Result<(), String> {
    validate(r)?;
    let queued: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM outbox WHERE record_id=?",
            [&r.id],
            |row| row.get(0),
        )
        .map_err(err)?;
    if queued > 0 {
        return Ok(());
    }
    if let Some(old) = current(tx, &r.id)? {
        if old.version >= r.version {
            return Ok(());
        }
        if old.session_id != r.session_id {
            return Err("同期データを確認できません。".into());
        }
        archive(tx, &old)?;
    }
    put(tx, r)
}
pub fn apply_remote(c: &mut Connection, r: Record, cursor: Cursor) -> Result<(), String> {
    if !valid_id(&cursor.operation_id)
        || cursor.operation_id != r.operation_id
        || !(0..1_000_000_000).contains(&cursor.nanoseconds)
    {
        return Err("同期位置を確認できません。".into());
    }
    let tx = c.transaction().map_err(err)?;
    apply(&tx, &r)?;
    tx.execute("INSERT INTO sync_cursor(id,seconds,nanoseconds,operation_id) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET seconds=excluded.seconds,nanoseconds=excluded.nanoseconds,operation_id=excluded.operation_id WHERE excluded.seconds>sync_cursor.seconds OR (excluded.seconds=sync_cursor.seconds AND excluded.nanoseconds>sync_cursor.nanoseconds) OR (excluded.seconds=sync_cursor.seconds AND excluded.nanoseconds=sync_cursor.nanoseconds AND excluded.operation_id>sync_cursor.operation_id)",params![cursor.seconds,cursor.nanoseconds,cursor.operation_id]).map_err(err)?;
    tx.commit().map_err(err)?;
    Ok(())
}
pub fn sync_info(c: &Connection) -> Result<SyncInfo, String> {
    let cursor = c
        .query_row(
            "SELECT seconds,nanoseconds,operation_id FROM sync_cursor WHERE id=1",
            [],
            |r| {
                Ok(Cursor {
                    seconds: r.get(0)?,
                    nanoseconds: r.get(1)?,
                    operation_id: r.get(2)?,
                })
            },
        )
        .optional()
        .map_err(err)?;
    let last: Option<f64> = c
        .query_row("SELECT last_sweep FROM sync_state WHERE id=1", [], |r| {
            r.get(0)
        })
        .optional()
        .map_err(err)?;
    Ok(SyncInfo {
        cursor,
        full_sweep: last
            .map(|t| now() < t || now() - t >= 86400.0)
            .unwrap_or(true),
    })
}
pub fn mark_sweep(c: &Connection) -> Result<(), String> {
    c.execute("INSERT INTO sync_state(id,last_sweep) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET last_sweep=excluded.last_sweep",[now()]).map_err(err)?;
    Ok(())
}
pub fn resolve(c: &mut Connection, key: &str, keep_local: bool) -> Result<(), String> {
    let tx = c.transaction().map_err(err)?;
    let remote: String = tx
        .query_row(
            "SELECT remote_payload FROM conflicts WHERE record_id=?",
            [key],
            |r| r.get(0),
        )
        .optional()
        .map_err(err)?
        .ok_or("競合が見つかりません。")?;
    let remote_record = decode(remote.clone())?;
    let mut local = current(&tx, key)?.ok_or("記録が見つかりません。")?;
    tx.execute("INSERT INTO resolved_operations(operation_id,record_id,payload) SELECT operation_id,record_id,payload FROM outbox WHERE record_id=?",[key]).map_err(err)?;
    tx.execute(
        "INSERT INTO resolutions(id,record_id,remote_payload,choice) VALUES(?,?,?,?)",
        params![
            id(),
            key,
            remote,
            if keep_local { "local" } else { "remote" }
        ],
    )
    .map_err(err)?;
    tx.execute("DELETE FROM outbox WHERE record_id=?", [key])
        .map_err(err)?;
    tx.execute("DELETE FROM conflicts WHERE record_id=?", [key])
        .map_err(err)?;
    if keep_local {
        local.version = remote_record.version + 1;
        local.operation_id = id();
        put(&tx, &local)?;
        enqueue(&tx, &local)?;
    } else {
        archive(&tx, &local)?;
        put(&tx, &remote_record)?;
    }
    tx.commit().map_err(err)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Dir(PathBuf);
    impl Dir {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!("devtrack-test-{}", id()));
            std::fs::create_dir_all(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn edit(name: &str, note: &str) -> Edit {
        Edit {
            id: None,
            expected_version: None,
            project_name: name.into(),
            category_name: "一般".into(),
            start: 100.0,
            end: 200.0,
            note: note.into(),
        }
    }
    #[test]
    fn outbox_is_durable_isolated_and_preserves_each_change() {
        let dir = Dir::new();
        let mut a = open(&dir.0, "alice").unwrap();
        let b = open(&dir.0, "bob").unwrap();
        let first = save(&mut a, edit("Project", "first")).unwrap();
        let second = save(&mut a, edit("Project", "another")).unwrap();
        assert_eq!(first.project_id, second.project_id);
        save(
            &mut a,
            Edit {
                id: Some(first.id.clone()),
                expected_version: Some(1),
                note: "changed".into(),
                ..edit("Project", "")
            },
        )
        .unwrap();
        assert!(save(
            &mut a,
            Edit {
                id: Some(first.id.clone()),
                expected_version: Some(1),
                ..edit("Project", "")
            }
        )
        .is_err());
        delete(&mut a, &first.id, 2).unwrap();
        drop(a);
        let a = open(&dir.0, "alice").unwrap();
        let queued = pending(&a).unwrap();
        assert_eq!(queued.len(), 4);
        assert_eq!(
            queued
                .iter()
                .filter(|r| r.id == first.id)
                .map(|r| r.version)
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
        assert!(queued.last().unwrap().deleted);
        assert!(state(&b).unwrap().records.is_empty());
        ack(&a, &first.operation_id).unwrap();
        ack(&a, &first.operation_id).unwrap();
        assert_eq!(state(&a).unwrap().pending, 3);
    }
    #[test]
    fn remote_and_both_conflict_choices_preserve_changes() {
        let dir = Dir::new();
        let mut a = open(&dir.0, "a").unwrap();
        let mut b = open(&dir.0, "b").unwrap();
        let initial = save(&mut a, edit("P", "original")).unwrap();
        let cursor = Cursor {
            seconds: 1000,
            nanoseconds: 10,
            operation_id: initial.operation_id.clone(),
        };
        apply_remote(&mut b, initial.clone(), cursor.clone()).unwrap();
        assert!(pending(&b).unwrap().is_empty());
        ack(&a, &initial.operation_id).unwrap();
        let change_a = save(
            &mut a,
            Edit {
                id: Some(initial.id.clone()),
                expected_version: Some(1),
                ..edit("P", "A")
            },
        )
        .unwrap();
        let change_b = save(
            &mut b,
            Edit {
                id: Some(initial.id.clone()),
                expected_version: Some(1),
                ..edit("P", "B")
            },
        )
        .unwrap();
        conflict(&b, change_a.clone()).unwrap();
        assert!(pending(&b).unwrap().is_empty());
        let mut next = cursor.clone();
        next.operation_id = change_a.operation_id.clone();
        next.seconds += 1;
        apply_remote(&mut b, change_a.clone(), next).unwrap();
        assert_eq!(state(&b).unwrap().records[0].note, "B");
        resolve(&mut b, &initial.id, true).unwrap();
        let chosen = pending(&b).unwrap();
        assert_eq!(chosen[0].version, 3);
        assert_eq!(chosen[0].note, "B");
        let saved: i64 = b
            .query_row("SELECT COUNT(*) FROM resolved_operations", [], |r| r.get(0))
            .unwrap();
        assert_eq!(saved, 1);
        ack(&b, &chosen[0].operation_id).unwrap();
        let mut remote = chosen[0].clone();
        remote.version = 4;
        remote.operation_id = id();
        remote.note = "remote".into();
        save(
            &mut b,
            Edit {
                id: Some(initial.id.clone()),
                expected_version: Some(3),
                ..edit("P", "local again")
            },
        )
        .unwrap();
        conflict(&b, remote.clone()).unwrap();
        resolve(&mut b, &initial.id, false).unwrap();
        assert_eq!(state(&b).unwrap().records[0].note, "remote");
        assert_eq!(state(&b).unwrap().pending, 0);
        let saved: i64 = b
            .query_row("SELECT COUNT(*) FROM resolved_operations", [], |r| r.get(0))
            .unwrap();
        assert_eq!(saved, 2);
        assert_ne!(change_a.operation_id, change_b.operation_id);
    }
    #[test]
    fn rejects_overlap_and_cursor_does_not_regress() {
        let dir = Dir::new();
        let mut a = open(&dir.0, "a").unwrap();
        let mut b = open(&dir.0, "b").unwrap();
        let first = save(&mut a, edit("P", "x")).unwrap();
        let mut second = first.clone();
        second.id = id();
        second.operation_id = id();
        second.start = 300.0;
        second.end = 400.0;
        let c = Cursor {
            seconds: 5,
            nanoseconds: 10,
            operation_id: first.operation_id.clone(),
        };
        apply_remote(&mut b, first.clone(), c.clone()).unwrap();
        let mut later = c.clone();
        later.seconds = 6;
        later.operation_id = second.operation_id.clone();
        apply_remote(&mut b, second.clone(), later).unwrap();
        assert!(save(
            &mut b,
            Edit {
                id: Some(first.id.clone()),
                expected_version: Some(1),
                start: 100.0,
                end: 350.0,
                ..edit("P", "")
            }
        )
        .is_err());
        apply_remote(&mut b, first, c).unwrap();
        assert_eq!(sync_info(&b).unwrap().cursor.unwrap().seconds, 6);
    }
    #[test]
    fn rejects_unknown_database_version_without_changing_it() {
        let dir = Dir::new();
        let c = open(&dir.0, "alice").unwrap();
        c.pragma_update(None, "user_version", 2).unwrap();
        drop(c);
        assert!(open(&dir.0, "alice").is_err());
        let path = dir.0.join(format!("history-{}.sqlite", uid("alice")));
        let c = Connection::open(path).unwrap();
        let v: i64 = c
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(v, 2);
    }
}
