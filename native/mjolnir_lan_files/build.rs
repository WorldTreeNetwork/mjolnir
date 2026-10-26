use std::{path::Path, process::Command};
fn main() {
    let root = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    for (name, path, expected) in [
        ("IDENTIKEY_AUTH_REV", "../../../../IdentiKey/identikey-protocol", "8cd455c7308e86c50a0b338b82c7d8e814b4b96e"),
        ("RECRYPT_STORAGE_AUTH_REV", "../../../../IdentiKey/recrypt", "0be9ed9a56bf4d7fd846e0c923980471dec88526"),
    ] {
        let repo = Path::new(&root).join(path).canonicalize().expect("sibling source checkout");
        let git = |args: &[&str]| {
            let out = Command::new("git").arg("-C").arg(&repo).args(args).output().unwrap();
            assert!(out.status.success());
            String::from_utf8(out.stdout).unwrap().trim().to_owned()
        };
        assert_eq!(git(&["rev-parse", "HEAD"]), expected, "dependency revision changed");
        assert!(git(&["status", "--porcelain", "--untracked-files=no"]).is_empty(), "dirty dependency checkout");
        println!("cargo:rustc-env={name}={expected}");
        // Recheck both tracked modifications and revision changes on every invocation.
        println!("cargo:rerun-if-changed={}", repo.display());
        println!("cargo:rerun-if-changed={}", repo.join(".git/HEAD").display());
    }
}
