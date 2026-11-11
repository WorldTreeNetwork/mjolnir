// SPDX-License-Identifier: MIT
//! Signed host-catalog AIE jobs. The saved pending proof is reused on every retry.
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use clap::Subcommand;
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};

#[derive(Subcommand)]
pub enum Command {
    /// Point at this VM being's current signed offer; optionally grant a holder
    Share {
        owner: String,
        offer: String,
        #[arg(long)]
        api: Option<String>,
        /// Base64 Ed25519 public key of the consumer VM
        #[arg(long, requires = "keypair_file")]
        grant_to: Option<String>,
        #[arg(long)]
        keypair_file: Option<PathBuf>,
    },
    /// Mint a holder token and POST a bounded catalog job to the guest's aie_url
    Run {
        owner: String,
        offer: String,
        design_id: String,
        #[arg(long)]
        api: Option<String>,
        #[arg(long)]
        aie_url: Option<String>,
        #[arg(long)]
        keypair_file: PathBuf,
        #[arg(long)]
        input: PathBuf,
        /// JSON output from the offer owner's `compute share --grant-to`
        #[arg(long)]
        grant_file: Option<PathBuf>,
        /// Base64 member key selecting the current guild delegation
        #[arg(long)]
        member_public_key: Option<String>,
        /// Save before execute; use --resume after a lost reply or CLI restart
        #[arg(long, default_value = "mj-aie-pending.json")]
        state_file: PathBuf,
        #[arg(long)]
        resume: bool,
    },
}

pub async fn run(command: Command, profile: &crate::config::Profile) -> Result<()> {
    let locator: Value = std::fs::read("/etc/mjolnir/vm.json")
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    match command {
        Command::Share {
            owner,
            offer,
            api,
            grant_to,
            keypair_file,
        } => {
            let api = api_url(api, profile, &locator);
            let current = get(&client, &format!("{api}/api/aie/offers/{owner}/{offer}")).await?;
            if let Some(holder) = grant_to {
                let key = load_key(&keypair_file.context("--keypair-file required")?)?;
                let proof = mint_proof(&client, &api, &key, &current, &holder, "").await?;
                let token = post(&client, &format!("{api}/api/aie/mint"), &proof).await?;
                println!("{}", serde_json::to_string_pretty(&token)?);
            } else {
                println!("{}", serde_json::to_string_pretty(&current)?);
            }
        }
        Command::Run {
            owner,
            offer,
            design_id,
            api,
            aie_url,
            keypair_file,
            input,
            grant_file,
            member_public_key,
            state_file,
            resume,
        } => {
            let api = api_url(api, profile, &locator);
            let aie = aie_url
                .or_else(|| locator["aie_url"].as_str().map(str::to_owned))
                .context("AIE is off: no aie_url in /etc/mjolnir/vm.json (or --aie-url)")?;
            let aie = aie.trim_end_matches('/');
            let mut state: Value;
            if resume {
                state = serde_json::from_slice(&std::fs::read(&state_file)?)?;
                if state["aie_url"] != aie
                    || state["owner"] != owner
                    || state["offer"] != offer
                    || state["body"]["design_id"] != design_id
                {
                    bail!("saved job does not match the requested offer, design or locator");
                }
                if state["terminal"] == true {
                    bail!("attempt ended; run again without --resume for a fresh nonce");
                }
            } else {
                if state_file.exists() {
                    let previous: Value = serde_json::from_slice(&std::fs::read(&state_file)?)?;
                    if previous["terminal"] != true {
                        bail!("pending job exists: use --resume or another --state-file");
                    }
                }
                let key = load_key(&keypair_file)?;
                let bytes = read_input(&input)?;
                let current =
                    get(&client, &format!("{api}/api/aie/offers/{owner}/{offer}")).await?;
                let grant: Value = match grant_file {
                    Some(path) => serde_json::from_slice(&std::fs::read(path)?)?,
                    None => Value::Null,
                };
                let holder = B64.encode(key.verifying_key().to_bytes());
                let mint = mint_proof(
                    &client,
                    &api,
                    &key,
                    &current,
                    &holder,
                    grant["biscuit"].as_str().unwrap_or(""),
                )
                .await?;
                let token = post(&client, &format!("{api}/api/aie/mint"), &mint).await?;
                let challenge = get(&client, &format!("{api}/api/aie/challenge")).await?;
                let mut proof = json!({"method": "POST", "resource": current["resource"],
                    "nonce": challenge["nonce"], "audience": challenge["audience"],
                    "idempotency_key": random_id(), "design_id": design_id,
                    "input_b64": B64.encode(&bytes), "biscuit": token["biscuit"],
                    "public_key": holder, "member_pk": member_public_key});
                sign(&mut proof, &key)?;
                // Persist the exact proof BEFORE enqueue. If enqueue's reply is
                // lost, do not reuse its nonce: a new invocation must enqueue fresh.
                state = json!({"owner": owner, "offer": offer, "aie_url": aie,
                    "terminal": true, "body": {"design_id": design_id, "proof": proof}});
                save(&state_file, &state)?;
                let queued = post(&client, &format!("{aie}/v1/execute"), &state["body"]).await?;
                state["body"]["pending_id"] = queued["pending_id"].clone();
                state["terminal"] = json!(false);
                save(&state_file, &state)?;
                eprintln!(
                    "pending_id={} saved in {}",
                    queued["pending_id"],
                    state_file.display()
                );
            }
            // The timeout is a client observation only. A live attempt and its
            // saved pending_id survive it; neither mint nor enqueue happens here.
            for _ in 0..600 {
                let response = client
                    .post(format!("{aie}/v1/execute"))
                    .json(&state["body"])
                    .send()
                    .await;
                match response {
                    Ok(reply) if reply.status().is_success() => {
                        let value: Value = reply.json().await?;
                        match value["status"].as_str() {
                            Some("completed") => {
                                state["terminal"] = json!(true);
                                save(&state_file, &state)?;
                                println!("{}", value);
                                if value["ok"] == false {
                                    bail!("catalog worker failed");
                                }
                                return Ok(());
                            }
                            Some("abandoned") => {
                                state["terminal"] = json!(true);
                                save(&state_file, &state)?;
                                bail!("attempt abandoned; run again without --resume to obtain a fresh nonce");
                            }
                            _ => {}
                        }
                    }
                    Ok(reply) if reply.status().as_u16() == 409 => {}
                    Ok(reply) => {
                        let status = reply.status();
                        state["terminal"] = json!(true);
                        save(&state_file, &state)?;
                        bail!(
                            "execute {status}: {}; run again without --resume for a fresh nonce",
                            reply.text().await?
                        );
                    }
                    Err(error) => {
                        eprintln!("execute reply lost ({error}); retrying saved pending_id")
                    }
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            bail!(
                "job still pending; resume with --resume --state-file {}",
                state_file.display()
            );
        }
    }
    Ok(())
}

fn api_url(flag: Option<String>, profile: &crate::config::Profile, locator: &Value) -> String {
    let resolved = flag.or_else(|| locator["api_url"].as_str().map(str::to_owned));
    crate::config::resolve_api(&resolved, profile)
        .trim_end_matches('/')
        .to_string()
}
fn read_input(path: &PathBuf) -> Result<Vec<u8>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(1_048_577)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1_048_576 {
        bail!("input exceeds 1048576 bytes");
    }
    Ok(bytes)
}
fn load_key(path: &PathBuf) -> Result<SigningKey> {
    let raw: Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let seed: [u8; 32] = B64
        .decode(
            raw["ed25519_secret"]
                .as_str()
                .context("missing ed25519_secret")?,
        )?
        .try_into()
        .map_err(|_| anyhow::anyhow!("seed must be 32 bytes"))?;
    let key = SigningKey::from_bytes(&seed);
    if B64.encode(key.verifying_key().to_bytes()) != raw["ed25519_public"] {
        bail!("keypair public key does not match seed");
    }
    Ok(key)
}
async fn mint_proof(
    client: &reqwest::Client,
    api: &str,
    key: &SigningKey,
    current: &Value,
    holder: &str,
    grant: &str,
) -> Result<Value> {
    let challenge = get(client, &format!("{api}/api/aie/challenge")).await?;
    let mut proof = json!({"method": "MINT", "resource": current["resource"],
        "nonce": challenge["nonce"], "audience": challenge["audience"],
        "idempotency_key": random_id(), "holder_public_key": holder,
        "public_key": B64.encode(key.verifying_key().to_bytes()), "biscuit": grant});
    sign(&mut proof, key)?;
    Ok(proof)
}
fn random_id() -> String {
    hex::encode(rand::random::<[u8; 16]>())
}
fn sign(proof: &mut Value, key: &SigningKey) -> Result<()> {
    proof["signature"] = json!(B64.encode(key.sign(&signing_message(proof)?).to_bytes()));
    Ok(())
}
fn signing_message(p: &Value) -> Result<Vec<u8>> {
    let input = B64.decode(p["input_b64"].as_str().unwrap_or(""))?;
    let digest = blake3::hash(&input);
    let mut message = if p["method"] == "MINT" {
        b"mjolnir/aie-mint/v1\0".to_vec()
    } else {
        b"mjolnir/aie-execute/v1\0".to_vec()
    };
    for field in [
        p["biscuit"].as_str().unwrap_or("").as_bytes(),
        p["nonce"].as_str().context("nonce required")?.as_bytes(),
        p["audience"]
            .as_str()
            .context("audience required")?
            .as_bytes(),
        p["method"].as_str().context("method required")?.as_bytes(),
        p["resource"]
            .as_str()
            .context("resource required")?
            .as_bytes(),
        digest.as_bytes(),
        p["design_id"].as_str().unwrap_or("").as_bytes(),
        p["idempotency_key"]
            .as_str()
            .context("idempotency_key required")?
            .as_bytes(),
        p["holder_public_key"].as_str().unwrap_or("").as_bytes(),
        p["member_pk"].as_str().unwrap_or("").as_bytes(),
    ] {
        message.extend_from_slice(&(field.len() as u32).to_be_bytes());
        message.extend_from_slice(field);
    }
    Ok(message)
}
fn save(path: &PathBuf, value: &Value) -> Result<()> {
    use std::io::Write;
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let temporary = path.with_extension(format!("aie-{}.tmp", random_id()));
    opts.create_new(true);
    let mut file = opts.open(&temporary)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)?;
    Ok(())
}
async fn get(client: &reqwest::Client, url: &str) -> Result<Value> {
    response(client.get(url).send().await?).await
}
async fn post(client: &reqwest::Client, url: &str, value: &Value) -> Result<Value> {
    response(client.post(url).json(value).send().await?).await
}
async fn response(reply: reqwest::Response) -> Result<Value> {
    let status = reply.status();
    let text = reply.text().await?;
    if !status.is_success() {
        bail!("AIE {status}: {text}");
    }
    Ok(serde_json::from_str(&text)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn execute_frame_matches_beam_vector() {
        // Supplied by execute_test.exs so the two implementations must agree
        // byte for byte, including the raw Blake3 digest and domain terminator.
        if let Ok(path) = std::env::var("AIE_PROOF_VECTOR") {
            let vector: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
            assert_eq!(
                hex::encode(signing_message(&vector["proof"]).unwrap()),
                vector["message_hex"]
            );
        }
        let mut p = json!({"nonce":"n", "audience":"host", "method":"POST",
            "resource":"owner/offer/incarnation", "idempotency_key":"job", "design_id":"vector-add"});
        let original = signing_message(&p).unwrap();
        p["design_id"] = json!("validate");
        assert_ne!(original, signing_message(&p).unwrap());
        p["design_id"] = json!("vector-add");
        p["input_b64"] = json!(B64.encode(b"changed"));
        assert_ne!(original, signing_message(&p).unwrap());
    }

    #[test]
    fn input_limit_and_key_consistency() {
        let dir = std::env::temp_dir().join(format!("aie-client-{}", random_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input");
        std::fs::write(&input, vec![0; 1_048_577]).unwrap();
        assert!(read_input(&input).is_err());
        let key = dir.join("key");
        std::fs::write(
            &key,
            json!({"ed25519_secret":B64.encode([1;32]),
            "ed25519_public":B64.encode([2;32])})
            .to_string(),
        )
        .unwrap();
        assert!(load_key(&key).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
