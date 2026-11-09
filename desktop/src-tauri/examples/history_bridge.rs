// Test-only adapter for exercising the real SQLite implementation from Node.
#[path = "../src/history.rs"]
mod history;
use serde_json::{json, Value};
use std::{
    io::{self, Read},
    path::Path,
};
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let response = match run(&input) {
        Ok(value) => json!({"ok":value}),
        Err(error) => json!({"error":error}),
    };
    println!("{}", response);
}
fn run(input: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let base = v["base"].as_str().ok_or("missing base")?;
    let uid = v["uid"].as_str().ok_or("missing uid")?;
    let action = v["action"].as_str().ok_or("missing action")?;
    let mut c = history::open(Path::new(base), uid)?;
    let value = match action {
        "state" => serde_json::to_value(history::state(&c)?),
        "pending" => serde_json::to_value(history::pending(&c)?),
        "save" => serde_json::to_value(history::save(
            &mut c,
            serde_json::from_value(v["edit"].clone()).map_err(|e| e.to_string())?,
        )?),
        "delete" => {
            history::delete(
                &mut c,
                v["id"].as_str().ok_or("missing id")?,
                v["version"].as_i64().ok_or("missing version")?,
            )?;
            Ok(Value::Null)
        }
        "ack" => {
            history::ack(&c, v["operationId"].as_str().ok_or("missing operation")?)?;
            Ok(Value::Null)
        }
        "conflict" => {
            history::conflict(
                &c,
                serde_json::from_value(v["record"].clone()).map_err(|e| e.to_string())?,
            )?;
            Ok(Value::Null)
        }
        "apply" => {
            history::apply_remote(
                &mut c,
                serde_json::from_value(v["record"].clone()).map_err(|e| e.to_string())?,
                serde_json::from_value(v["cursor"].clone()).map_err(|e| e.to_string())?,
            )?;
            Ok(Value::Null)
        }
        "info" => serde_json::to_value(history::sync_info(&c)?),
        "sweep" => {
            history::mark_sweep(&c)?;
            Ok(Value::Null)
        }
        "resolve" => {
            history::resolve(
                &mut c,
                v["id"].as_str().ok_or("missing id")?,
                v["keepLocal"].as_bool().ok_or("missing choice")?,
            )?;
            Ok(Value::Null)
        }
        _ => return Err("unknown action".into()),
    }
    .map_err(|e| e.to_string())?;
    Ok(value)
}
