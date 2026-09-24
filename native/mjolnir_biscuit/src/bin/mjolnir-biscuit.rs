//! JSON-in / JSON-out BEAM face for `mjolnir-axsb.1.3`. No HTTP.

use mjolnir_biscuit::{
    append_holder_check, authorize_holder, blake3_hash, holder_fingerprint, keypair_from_private_hex,
    mint_right, new_keypair, parse, public_from_hex, secret_commit,
};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(tag = "op")]
enum Req {
    #[serde(rename = "keypair")]
    Keypair,
    #[serde(rename = "blake3")]
    Blake3 { data_b64: String },
    #[serde(rename = "holder_fp")]
    HolderFp { public_hex: String },
    #[serde(rename = "commit")]
    Commit { salt_b64: String, secret_b64: String },
    #[serde(rename = "mint")]
    Mint {
        private_hex: String,
        resource: String,
        operation: String,
    },
    #[serde(rename = "append_holder")]
    AppendHolder {
        public_hex: String,
        biscuit_b64: String,
        fp: String,
    },
    #[serde(rename = "authorize")]
    Authorize {
        public_hex: String,
        biscuit_b64: String,
        fp: String,
        resource: String,
        operation: String,
        inject_holder: bool,
    },
    #[serde(rename = "parse")]
    Parse {
        public_hex: String,
        biscuit_b64: String,
    },
}

#[derive(Serialize)]
struct OkKeypair {
    ok: bool,
    private_hex: String,
    public_hex: String,
}

#[derive(Serialize)]
struct OkBytes {
    ok: bool,
    digest_hex: String,
}

#[derive(Serialize)]
struct OkBiscuit {
    ok: bool,
    biscuit_b64: String,
}

#[derive(Serialize)]
struct OkAuth {
    ok: bool,
}

fn b64(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .map_err(|e| e.to_string())
}

fn main() {
    let raw = match std::env::args().nth(1) {
        Some(arg) if arg != "-" => arg.into_bytes(),
        _ => {
            let mut buf = Vec::new();
            std::io::Read::read_to_end(&mut std::io::stdin(), &mut buf).expect("stdin");
            buf
        }
    };
    let req: Req = serde_json::from_slice(&raw).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(2);
    });
    let out = run(req).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1);
    });
    print!("{out}");
}

fn run(req: Req) -> Result<String, String> {
    match req {
        Req::Keypair => {
            let kp = new_keypair();
            Ok(serde_json::to_string(&OkKeypair {
                ok: true,
                private_hex: hex::encode(kp.private().to_bytes()),
                public_hex: hex::encode(kp.public().to_bytes()),
            })
            .unwrap())
        }
        Req::Blake3 { data_b64 } => {
            let data = b64(&data_b64)?;
            Ok(serde_json::to_string(&OkBytes {
                ok: true,
                digest_hex: hex::encode(blake3_hash(&data)),
            })
            .unwrap())
        }
        Req::HolderFp { public_hex } => {
            let bytes = hex::decode(public_hex.trim()).map_err(|e| e.to_string())?;
            let fp = holder_fingerprint(&bytes).map_err(|e| e.to_string())?;
            Ok(serde_json::to_string(&OkBytes {
                ok: true,
                digest_hex: hex::encode(fp),
            })
            .unwrap())
        }
        Req::Commit {
            salt_b64,
            secret_b64,
        } => {
            let salt = b64(&salt_b64)?;
            let secret = b64(&secret_b64)?;
            Ok(serde_json::to_string(&OkBytes {
                ok: true,
                digest_hex: hex::encode(secret_commit(&salt, &secret)),
            })
            .unwrap())
        }
        Req::Mint {
            private_hex,
            resource,
            operation,
        } => {
            let root = keypair_from_private_hex(&private_hex).map_err(|e| e.to_string())?;
            let bytes = mint_right(&root, &resource, &operation).map_err(|e| e.to_string())?;
            Ok(serde_json::to_string(&OkBiscuit {
                ok: true,
                biscuit_b64: {
                    use base64::Engine;
                    base64::engine::general_purpose::STANDARD.encode(bytes)
                },
            })
            .unwrap())
        }
        Req::AppendHolder {
            public_hex,
            biscuit_b64,
            fp,
        } => {
            let pk = public_from_hex(&public_hex).map_err(|e| e.to_string())?;
            let bytes = b64(&biscuit_b64)?;
            let tok = parse(&bytes, pk).map_err(|e| e.to_string())?;
            let next = append_holder_check(&tok, &fp).map_err(|e| e.to_string())?;
            Ok(serde_json::to_string(&OkBiscuit {
                ok: true,
                biscuit_b64: {
                    use base64::Engine;
                    base64::engine::general_purpose::STANDARD.encode(next)
                },
            })
            .unwrap())
        }
        Req::Authorize {
            public_hex,
            biscuit_b64,
            fp,
            resource,
            operation,
            inject_holder,
        } => {
            let pk = public_from_hex(&public_hex).map_err(|e| e.to_string())?;
            let bytes = b64(&biscuit_b64)?;
            authorize_holder(&bytes, pk, &fp, &resource, &operation, inject_holder)
                .map_err(|e| e.to_string())?;
            Ok(serde_json::to_string(&OkAuth { ok: true }).unwrap())
        }
        Req::Parse {
            public_hex,
            biscuit_b64,
        } => {
            let pk = public_from_hex(&public_hex).map_err(|e| e.to_string())?;
            let bytes = b64(&biscuit_b64)?;
            parse(&bytes, pk).map_err(|e| e.to_string())?;
            Ok(serde_json::to_string(&OkAuth { ok: true }).unwrap())
        }
    }
}
