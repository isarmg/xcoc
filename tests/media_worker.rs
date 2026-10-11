//! Actual-process checks for the private media-worker boundary. Only synthetic
//! endpoints are used; no camera, user credential, or external service is used.
use std::io::Write;
use std::process::{Command, Stdio};

fn worker() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_xcoc"));
    command
        .arg("media-worker")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

#[test]
fn linked_worker_preflight_succeeds() {
    let output = worker().arg("--check").output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stdout.is_empty());
    assert!(output.stderr.is_empty());
}

#[test]
fn malformed_or_oversized_input_never_echoes_values() {
    let secret = "synthetic-password-and-media-jwt";
    for input in [
        format!("{{\"unexpected\":\"{secret}\"}}"),
        format!("{{\"operation\":\"{secret}\"}}"),
        secret.repeat(3000),
    ] {
        let mut child = worker().spawn().unwrap();
        // The bounded reader may close the pipe before oversized input ends.
        let _ = child.stdin.take().unwrap().write_all(input.as_bytes());
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert_eq!(output.stderr, b"media worker failed\n");
        assert!(!String::from_utf8_lossy(&output.stderr).contains(secret));
    }
}

#[cfg(target_os = "linux")]
#[test]
fn live_worker_argv_and_environment_never_contain_pipe_secrets() {
    let executable = std::fs::canonicalize(env!("CARGO_BIN_EXE_xcoc")).unwrap();
    for operation in ["probe", "publish", "record"] {
        let secret = format!("synthetic-{operation}-secret");
        let mut child = worker().spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        // Hold the final brace/EOF until after inspection, keeping the actual
        // worker alive without connecting to any endpoint.
        write!(stdin, "{{\"operation\":\"{operation}\",\"source\":\"rtsp://user:{secret}@camera.invalid/main\",\"rtsp\":true,\"destination\":\"rtsps://media.invalid/live?jwt={secret}\"").unwrap();
        stdin.flush().unwrap();
        let argv = (|| -> Result<Vec<u8>, String> {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
            loop {
                if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
                    return Err(format!("worker exited before inspection: {status}"));
                }
                // spawn can return while /proc still exposes the parent's image.
                // Wait for exec, not for the assertions below to become true.
                let observed_executable = std::fs::read_link(format!("/proc/{}/exe", child.id()))
                    .map_err(|error| error.to_string())?;
                if observed_executable == executable {
                    let argv = std::fs::read(format!("/proc/{}/cmdline", child.id()))
                        .map_err(|error| error.to_string())?;
                    if !argv.is_empty() {
                        return Ok(argv);
                    }
                }
                if std::time::Instant::now() >= deadline {
                    let argv = std::fs::read(format!("/proc/{}/cmdline", child.id()));
                    return Err(format!(
                        "worker startup timed out: executable={observed_executable:?}, argv={argv:?}"
                    ));
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        })();
        let environment = std::fs::read(format!("/proc/{}/environ", child.id()));
        let status_before_kill = child.try_wait().unwrap();
        if status_before_kill.is_none() {
            child.kill().unwrap();
        }
        drop(stdin);
        let output = child.wait_with_output().unwrap();
        let argv = argv
            .unwrap_or_else(|error| panic!("{operation}: {error}; final status={}", output.status));
        assert!(
            status_before_kill.is_none(),
            "{operation}: worker exited before inspection finished: {status_before_kill:?}"
        );
        let environment = environment.unwrap();
        assert!(!String::from_utf8_lossy(&argv).contains(&secret));
        assert!(!String::from_utf8_lossy(&environment).contains(&secret));
        assert_eq!(
            argv.split(|byte| *byte == 0)
                .filter(|arg| !arg.is_empty())
                .count(),
            2
        );
        assert!(argv.ends_with(b"media-worker\0"));
        assert!(!output.status.success());
    }
}
