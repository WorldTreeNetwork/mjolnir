#!/usr/bin/env python3
"""Reproduce b33ddf24 gate findings without a Cargo build or repository edits.

Uses the actual gate source; adapts only the clock type/addition for finite times.
Assertions describe observed bugs, so this script must be revised after fixes.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
source = (root / "native/vendor/moq-webrtc/src/keyframe.rs").read_text()
source = source.split("#[cfg(test)]")[0]
source = source.replace("use kio::clock::Instant;", """use std::time::Instant;
trait Saturating { fn saturating_add(self, d: Duration) -> Self; }
impl Saturating for Instant {
    fn saturating_add(self, d: Duration) -> Self { self.checked_add(d).unwrap() }
}""")
main = '\nfn main() {\n let t = Instant::now(); let p = Keyframes::trial();\n let mut g = Gate::new(true); g.note(Cause::Startup,t); g.poll_send(&p,t,true);\n g.note(Cause::Loss,t+Duration::from_millis(300));\n assert_eq!(g.deadline(),Some(t+Duration::from_secs(2)));\n println!("BUG: loss pending at 300ms still scheduled for 2000ms, not floor 1000ms");\n let mut p = p; p.period=Duration::from_millis(100);\n let mut g=Gate::new(true); g.note(Cause::Startup,t);g.poll_send(&p,t,true);\n let now=t+Duration::from_millis(100);\n for _ in 0..100 { assert!(g.take_deadline(now).is_some());g.note(Cause::Period,now);assert!(!g.ready(&p,now)); }\n println!("BUG: 100 consecutive due timer polls at fixed 100ms while floor forbids send");\n let mut g=Gate::new(false);g.on_keyframe(&p,t);\n for _ in 0..100 { assert!(g.take_deadline(now).is_some());g.note(Cause::Period,now);assert!(!g.ready(&p,now)); }\n println!("BUG: 100 consecutive due polls without negotiated PLI (unbounded spin)");\n let mut w=JoinWatch::default();w.observe(&p,Some(0),Some(0));\n assert!(!w.observe(&p,Some(1),Some(0)));\n println!("BUG: eligible next-group demand 1 over largest 0 ignored with ratio 4");\n}\n'
with tempfile.TemporaryDirectory(prefix="mj-b33-review-") as temp:
    temp = Path(temp)
    (temp / "repro.rs").write_text(source + main)
    subprocess.run(["rustc", "--edition", "2024", str(temp / "repro.rs"), "-o", str(temp / "repro")], check=True)
    subprocess.run([str(temp / "repro")], check=True)
