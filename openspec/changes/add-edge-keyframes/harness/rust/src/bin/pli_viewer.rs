//! Negative-control WHEP viewer. It sends PLI on its own video line.
//! It does not call the ingest gate and it is not a requester.
use std::time::{Duration, Instant};

use str0m::change::SdpAnswer;
use str0m::media::{Direction, KeyframeRequestKind, MediaKind};
use str0m::Rtc;
use tokio::net::UdpSocket;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::args().nth(1).ok_or_else(|| anyhow::anyhow!("usage: pli-viewer <whep-url>"))?;
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    let mut rtc = Rtc::builder().set_rtp_mode(true).build(Instant::now());
    let local = socket.local_addr()?;
    rtc.add_local_candidate(str0m::Candidate::host(local, "udp").map_err(|e| anyhow::anyhow!("{e}"))?);
    let mut api = rtc.sdp_api();
    let mid = api.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
    let (offer, pending) = api.apply().ok_or_else(|| anyhow::anyhow!("no sdp"))?;
    let client = reqwest::Client::builder().danger_accept_invalid_certs(true).build()?;
    let res = client
        .post(&url)
        .header("content-type", "application/sdp")
        .header("accept", "application/sdp")
        .body(offer.to_sdp_string())
        .send()
        .await?;
    if !res.status().is_success() {
        anyhow::bail!("whep status {}", res.status());
    }
    let answer = SdpAnswer::from_sdp_string(&res.text().await?).map_err(|e| anyhow::anyhow!("{e}"))?;
    rtc.sdp_api().accept_answer(pending, answer).map_err(|e| anyhow::anyhow!("{e}"))?;
    println!("pli-viewer connected negative-control-only");
    let mut next = Instant::now();
    let end = Instant::now() + Duration::from_secs(5);
    let mut buf = vec![0u8; 2000];
    while Instant::now() < end {
        if Instant::now() >= next {
            if let Some(mut writer) = rtc.writer(mid) {
                writer.request_keyframe(None, KeyframeRequestKind::Pli).map_err(|e| anyhow::anyhow!("{e}"))?;
                println!("viewer-pli sent mid={mid:?}");
            }
            next = Instant::now() + Duration::from_secs(1);
        }
        loop {
            match rtc.poll_output().map_err(|e| anyhow::anyhow!("{e}"))? {
                str0m::Output::Transmit(tx) => {
                    socket.send_to(&tx.contents, tx.destination).await?;
                }
                str0m::Output::Timeout(_) | str0m::Output::Event(_) => break,
            }
        }
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            read = socket.recv_from(&mut buf) => {
                let (n, from) = read?;
                let recv = str0m::net::Receive::new(
                    str0m::net::Protocol::Udp,
                    from,
                    local,
                    &buf[..n],
                ).map_err(|e| anyhow::anyhow!("{e}"))?;
                rtc.handle_input(str0m::Input::Receive(Instant::now(), recv)).map_err(|e| anyhow::anyhow!("{e}"))?;
            }
        }
    }
    Ok(())
}
