//! Prints a public verify set for local proofs. Not installed.
fn main() {
    let key = moq_auth::Key::generate(moq_auth::Algorithm::EdDSA, None).expect("key");
    let set = moq_auth::KeySet {
        keys: vec![std::sync::Arc::new(key.public().expect("public"))],
    };
    println!("{}", set.to_str().expect("json"));
}