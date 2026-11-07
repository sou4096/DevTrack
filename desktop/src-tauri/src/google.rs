use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use std::{io::{Read, Write}, net::TcpListener, time::{Duration, Instant}};
use url::Url;

fn random_value() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn callback(request: &str, state: &str) -> Result<Option<String>, &'static str> {
    let line = request.lines().next().ok_or("Invalid callback")?;
    let mut parts = line.split_whitespace();
    if parts.next() != Some("GET") { return Err("Invalid callback method"); }
    let target = parts.next().ok_or("Invalid callback")?;
    let url = Url::parse(&format!("http://127.0.0.1{target}")).map_err(|_| "Invalid callback")?;
    if url.path() != "/oauth/callback" { return Err("Invalid callback path"); }
    let params: Vec<_> = url.query_pairs().collect();
    let states: Vec<_> = params.iter().filter(|(k, _)| k == "state").collect();
    if states.len() != 1 || states[0].1 != state { return Err("Invalid OAuth state"); }
    if params.iter().any(|(k, _)| k == "error") { return Ok(None); }
    let codes: Vec<_> = params.iter().filter(|(k, _)| k == "code").collect();
    if codes.len() != 1 || codes[0].1.is_empty() { return Err("Invalid authorization code"); }
    Ok(Some(codes[0].1.to_string()))
}

pub fn google_token() -> Result<String, String> {
    let client_id = std::env::var("DEVTRACK_GOOGLE_CLIENT_ID").map_err(|_| "Googleデスクトップ認証が設定されていません。".to_string())?;
    if client_id.trim().is_empty() { return Err("Googleデスクトップ認証が設定されていません。".into()); }
    let secret = std::env::var("DEVTRACK_GOOGLE_CLIENT_SECRET").unwrap_or_default();
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| "認証用ポートを開けません。")?;
    listener.set_nonblocking(true).map_err(|_| "認証用ポートを設定できません。")?;
    let redirect = format!("http://127.0.0.1:{}/oauth/callback", listener.local_addr().map_err(|_| "認証用ポートを確認できません。")?.port());
    let verifier = random_value();
    let state = random_value();
    let mut auth_url = Url::parse("https://accounts.google.com/o/oauth2/v2/auth").unwrap();
    auth_url.query_pairs_mut().append_pair("client_id", &client_id).append_pair("redirect_uri", &redirect)
        .append_pair("response_type", "code").append_pair("scope", "openid email profile")
        .append_pair("code_challenge", &challenge(&verifier)).append_pair("code_challenge_method", "S256")
        .append_pair("state", &state);
    open::that(auth_url.as_str()).map_err(|_| "ブラウザを開けません。")?;
    let deadline = Instant::now() + Duration::from_secs(180);
    let code = loop {
        if Instant::now() >= deadline { return Err("Googleログインがタイムアウトしました。".into()); }
        match listener.accept() {
            Ok((mut stream, _)) => {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut buf = [0u8; 8192];
                let count = stream.read(&mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..count]);
                let parsed = callback(&request, &state);
                let response = if parsed.is_ok() { "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nReturn to DevTrack." } else { "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nInvalid request." };
                let _ = stream.write_all(response.as_bytes());
                match parsed { Ok(Some(code)) => break code, Ok(None) => return Err("Googleログインがキャンセルされました。".into()), Err(_) => continue }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => return Err("認証応答を受信できません。".into()),
        }
    };
    let mut form = vec![("client_id", client_id.as_str()), ("code", code.as_str()), ("code_verifier", verifier.as_str()), ("redirect_uri", redirect.as_str()), ("grant_type", "authorization_code")];
    if !secret.is_empty() { form.push(("client_secret", &secret)); }
    let client = reqwest::blocking::Client::builder().timeout(Duration::from_secs(20)).build().map_err(|_| "通信を開始できません。")?;
    let response = client.post("https://oauth2.googleapis.com/token").form(&form).send().map_err(|_| "Googleとの通信に失敗しました。")?;
    if !response.status().is_success() { return Err("Googleの認証コードを交換できませんでした。".into()); }
    #[derive(serde::Deserialize)] struct Token { id_token: String }
    let token: Token = response.json().map_err(|_| "Googleの認証応答が不正です。")?;
    Ok(token.id_token)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn pkce_matches_rfc_example() {
        assert_eq!(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }
    #[test] fn callback_requires_exact_path_unique_state_and_code() {
        assert_eq!(callback("GET /oauth/callback?code=abc&state=xyz HTTP/1.1\r\n", "xyz"), Ok(Some("abc".into())));
        assert!(callback("GET /oauth/callback?code=abc&state=bad HTTP/1.1", "xyz").is_err());
        assert!(callback("GET /other?code=abc&state=xyz HTTP/1.1", "xyz").is_err());
        assert!(callback("GET /oauth/callback?code=abc&state=xyz&state=xyz HTTP/1.1", "xyz").is_err());
        assert_eq!(callback("GET /oauth/callback?error=access_denied&state=xyz HTTP/1.1", "xyz"), Ok(None));
    }
}
