#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod google;

#[tauri::command]
async fn google_sign_in() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(google::google_token).await.map_err(|_| "Googleログインを開始できません。".to_string())?
}

fn main() {
    tauri::Builder::default().invoke_handler(tauri::generate_handler![google_sign_in])
        .run(tauri::generate_context!()).expect("failed to run DevTrack");
}
