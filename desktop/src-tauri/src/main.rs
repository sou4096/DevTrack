#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod google;
mod history;
use tauri::Manager;

fn store(
    app: &tauri::AppHandle,
    uid: &str,
    emulator: bool,
) -> Result<rusqlite::Connection, String> {
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|_| "保存先を開けません。".to_string())?
        .join("history")
        .join(if emulator { "emulator" } else { "production" });
    history::open(&directory, uid)
}
#[tauri::command]
fn history_state(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
) -> Result<history::State, String> {
    history::state(&store(&app, &uid, emulator)?)
}
#[tauri::command]
fn history_save(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    edit: history::Edit,
) -> Result<history::Record, String> {
    history::save(&mut store(&app, &uid, emulator)?, edit)
}
#[tauri::command]
fn history_delete(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    id: String,
    version: i64,
) -> Result<(), String> {
    history::delete(&mut store(&app, &uid, emulator)?, &id, version)
}
#[tauri::command]
fn history_pending(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
) -> Result<Vec<history::Record>, String> {
    history::pending(&store(&app, &uid, emulator)?)
}
#[tauri::command]
fn history_ack(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    operation_id: String,
) -> Result<(), String> {
    history::ack(&store(&app, &uid, emulator)?, &operation_id)
}
#[tauri::command]
fn history_conflict(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    record: history::Record,
) -> Result<(), String> {
    history::conflict(&store(&app, &uid, emulator)?, record)
}
#[tauri::command]
fn history_apply_remote(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    record: history::Record,
    cursor: history::Cursor,
) -> Result<(), String> {
    history::apply_remote(&mut store(&app, &uid, emulator)?, record, cursor)
}
#[tauri::command]
fn history_sync_info(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
) -> Result<history::SyncInfo, String> {
    history::sync_info(&store(&app, &uid, emulator)?)
}
#[tauri::command]
fn history_mark_sweep(app: tauri::AppHandle, uid: String, emulator: bool) -> Result<(), String> {
    history::mark_sweep(&store(&app, &uid, emulator)?)
}
#[tauri::command]
fn history_resolve(
    app: tauri::AppHandle,
    uid: String,
    emulator: bool,
    id: String,
    keep_local: bool,
) -> Result<(), String> {
    history::resolve(&mut store(&app, &uid, emulator)?, &id, keep_local)
}

#[tauri::command]
async fn google_sign_in() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(google::google_token)
        .await
        .map_err(|_| "Googleログインを開始できません。".to_string())?
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            google_sign_in,
            history_state,
            history_save,
            history_delete,
            history_pending,
            history_ack,
            history_conflict,
            history_apply_remote,
            history_sync_info,
            history_mark_sweep,
            history_resolve
        ])
        .run(tauri::generate_context!())
        .expect("failed to run DevTrack");
}
