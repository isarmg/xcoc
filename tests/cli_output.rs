//! Public CLI output uses only synthetic configuration and static camera catalogs.
use std::{fs, path::Path, process::Command};

fn command(config: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_xcoc"));
    command.arg("--config").arg(config);
    command
}

#[test]
fn finite_catalog_uses_the_same_result_in_each_output_format_without_creating_state() {
    let temp = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let path = temp.path().join("missing-config.json");
    let mut expected = None;
    for format in ["json", "ndjson"] {
        let output = command(&path)
            .args(["camera", "presets", "--format", format])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&output.stdout).lines().count(), 1);
        let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["command"], "camera presets");
        let result = value["result"].as_array().unwrap();
        assert_eq!(result.len(), xcoc::camera_presets::catalog().len());
        if let Some(expected) = &expected {
            assert_eq!(expected, &value["result"]);
        }
        expected = Some(value["result"].clone());
        assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
    }
    let output = command(&path)
        .args(["camera", "presets", "--format", "human"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(!output.stdout.is_empty());
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
}

#[test]
fn invalid_cli_input_has_machine_failure_and_never_echoes_rejected_values() {
    let temp = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let path = temp.path().join("missing-config.json");
    let rejected = "synthetic-private-value-never-echoed";
    for format in ["json", "ndjson"] {
        for alias in ["--state", "--output", "--json"] {
            let output = command(&path)
                .args(["camera", "presets", "--format", format, alias, rejected])
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(2));
            assert_eq!(String::from_utf8_lossy(&output.stdout).lines().count(), 1);
            let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(value["ok"], false);
            assert_eq!(value["error"]["code"], "unknown_option");
            assert!(!String::from_utf8_lossy(&output.stdout).contains(rejected));
            assert!(!String::from_utf8_lossy(&output.stderr).contains(rejected));
            assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
        }
    }
}

#[cfg(unix)]
#[test]
fn unpair_emits_the_committed_result_and_preserves_other_instances() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let path = temp.path().join("config.json");
    let removed = uuid::Uuid::new_v4();
    let retained = uuid::Uuid::new_v4();
    let secret = "a".repeat(43);
    let state = serde_json::json!({
        "format":1,"installation_id":uuid::Uuid::new_v4(),
        "instances":[
            {"server":"https://server.invalid","instance_id":removed,"access_token":secret,"name":"removed","camera":null},
            {"server":"https://server.invalid","instance_id":retained,"access_token":secret,"name":"retained","camera":null}
        ]
    });
    fs::write(&path, serde_json::to_vec(&state).unwrap()).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let output = command(&path)
        .args(["unpair", &removed.to_string(), "--format", "ndjson"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout).lines().count(), 1);
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["result"]["committed"], true);
    assert_eq!(value["result"]["recordings_preserved"], true);
    assert_eq!(value["result"]["remote_authorization_revoked"], false);
    let saved: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["instances"].as_array().unwrap().len(), 1);
    assert_eq!(saved["instances"][0]["instance_id"], retained.to_string());
    assert!(!String::from_utf8_lossy(&output.stdout).contains(&secret));
}
