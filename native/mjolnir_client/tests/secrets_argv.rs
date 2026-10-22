//! `mj secrets` must not echo a spec value on a usage error.

use std::process::Command;

#[test]
fn usage_error_omits_spec_value() {
    let sentinel = "sentinel-value-9f3a";
    let output = Command::new(env!("CARGO_BIN_EXE_mjolnir"))
        .args(["secrets", "set", "app", &format!("={sentinel}")])
        .output()
        .expect("spawn mjolnir");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "expected a usage error, stderr: {stderr}"
    );
    assert!(
        !stderr.contains(sentinel),
        "spec value leaked on stderr:\n{stderr}"
    );
    assert!(
        stderr.contains("[redacted]") || stderr.contains("missing key"),
        "expected a redacted usage error, stderr:\n{stderr}"
    );
}
