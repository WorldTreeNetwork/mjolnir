//! Path or stdin → 32 raw Blake3 bytes on stdout. Used by `Mjolnir.Sites.Crypto`.

fn main() {
    let buf = match std::env::args().nth(1) {
        Some(path) => std::fs::read(&path).unwrap_or_else(|e| panic!("read {path}: {e}")),
        None => {
            let mut buf = Vec::new();
            std::io::Read::read_to_end(&mut std::io::stdin(), &mut buf).expect("stdin");
            buf
        }
    };
    let hash = blake3::hash(&buf);
    std::io::Write::write_all(&mut std::io::stdout(), hash.as_bytes()).expect("stdout");
}
