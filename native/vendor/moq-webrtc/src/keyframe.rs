//! Ingest keyframe gate. One per video line. There is no viewer cause.
//!
//! Modified by the Mjolnir contributors for World Tree Network Foundation in 2026.
//! Added the ingest keyframe policy. Upstream: rs/moq-webrtc/src at
//! 4a6f522483168ace392718d68b58a402533c897d. This file is new.

use std::time::Duration;

use kio::clock::Instant;

/// Policy carried on [`crate::server::whip::Request`]. Default is off, which is the pin.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Keyframes {
	/// When false, the session keeps the pinned PLI paths and this gate is not called.
	pub enabled: bool,
	/// Minimum gap between two sends on one line.
	pub floor: Duration,
	/// Request cadence after the later of the last keyframe and the last sent PLI.
	pub period: Duration,
	/// A non-contiguous delta may add a loss cause.
	pub on_loss: bool,
	/// A join past [`Self::ratio`] may add a join cause.
	pub on_join: bool,
	/// Groups ahead of the largest written that count as one join request.
	pub ratio: u32,
}

impl Default for Keyframes {
	fn default() -> Self {
		Self {
			enabled: false,
			floor: Duration::from_secs(1),
			period: Duration::from_secs(2),
			on_loss: true,
			on_join: true,
			ratio: 4,
		}
	}
}

impl Keyframes {
	/// Enabled trial: floor 1s, period 2s, loss on, join ratio 4.
	pub fn trial() -> Self {
		Self { enabled: true, ..Self::default() }
	}

	/// `Err` when enabled with a zero floor or a zero period.
	pub fn validate(self) -> Result<(), ()> {
		if self.enabled && (self.floor.is_zero() || self.period.is_zero()) {
			Err(())
		} else {
			Ok(())
		}
	}
}

/// Why a line wants a keyframe. A viewer PLI is not a cause.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cause {
	Startup,
	Step,
	Period,
	Loss,
	Join,
}

impl Cause {
	fn bit(self) -> u8 {
		match self {
			Self::Startup => 1,
			Self::Step => 2,
			Self::Period => 4,
			Self::Loss => 8,
			Self::Join => 16,
		}
	}
}

/// One held request: a bit, a cause mask, and one deadline.
#[derive(Clone, Debug, Default)]
pub struct Gate {
	pending: bool,
	causes: u8,
	deadline: Option<Instant>,
	last_sent: Option<Instant>,
	last_keyframe: Option<Instant>,
	/// How many sends were held because the writer was missing or refused.
	pub held: u64,
	pli: bool,
}

/// What a due request did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Send {
	/// The writer accepted the PLI. `causes` is the mask of everything since the previous send.
	Sent { causes: u8 },
	/// Still held. `last_sent` did not move.
	Held { causes: u8 },
}

impl Gate {
	pub fn new(pli: bool) -> Self {
		Self { pli, ..Self::default() }
	}

	pub fn note(&mut self, cause: Cause, when: Instant) {
		self.pending = true;
		self.causes |= cause.bit();
		if self.deadline.is_none() {
			self.deadline = Some(when);
		}
	}

	/// A keyframe cancels the held request and starts the period from now.
	pub fn on_keyframe(&mut self, policy: &Keyframes, now: Instant) {
		self.pending = false;
		self.causes = 0;
		self.deadline = None;
		self.last_keyframe = Some(now);
		if policy.enabled {
			self.arm_period(policy, now);
		}
	}

	fn arm_period(&mut self, policy: &Keyframes, now: Instant) {
		let base = match (self.last_keyframe, self.last_sent) {
			(Some(k), Some(s)) => k.max(s),
			(Some(k), None) => k,
			(None, Some(s)) => s,
			(None, None) => now,
		};
		self.deadline = Some(base.saturating_add(policy.period));
	}

	/// The armed deadline, once. A past deadline is cleared so it is not returned again.
	pub fn take_deadline(&mut self, now: Instant) -> Option<Instant> {
		match self.deadline {
			Some(at) if now >= at => {
				self.deadline = None;
				Some(at)
			}
			_ => None,
		}
	}

	pub fn deadline(&self) -> Option<Instant> {
		self.deadline
	}

	/// Whether a send is allowed now, before the writer is touched.
	pub fn ready(&self, policy: &Keyframes, now: Instant) -> bool {
		if !self.pending || !self.pli {
			return false;
		}
		match self.last_sent {
			Some(sent) => now >= sent.saturating_add(policy.floor),
			None => true,
		}
	}

	/// Send when the floor allows and the line negotiated PLI. A refused send stays held.
	pub fn poll_send(&mut self, policy: &Keyframes, now: Instant, writer_accepted: bool) -> Option<Send> {
		if !self.pending || !self.pli {
			return None;
		}
		if let Some(sent) = self.last_sent
			&& now < sent.saturating_add(policy.floor)
		{
			return None;
		}
		let causes = self.causes;
		if !writer_accepted {
			self.held += 1;
			if self.deadline.is_some_and(|at| now >= at) {
				self.deadline = None;
			}
			return Some(Send::Held { causes });
		}
		self.pending = false;
		self.causes = 0;
		self.last_sent = Some(now);
		self.arm_period(policy, now);
		Some(Send::Sent { causes })
	}

	/// A strictly future deadline from another cause re-arms a disarmed line.
	pub fn rearm(&mut self, at: Instant, now: Instant) {
		if at > now {
			self.deadline = Some(at);
		}
	}
}

/// Earliest armed instant. A disarmed line contributes nothing.
pub fn earliest_deadline<I>(times: I) -> Option<Instant>
where
	I: IntoIterator<Item = Option<Instant>>,
{
	times.into_iter().flatten().min()
}

/// Join against the live demand. The first reading requests nothing.
#[derive(Clone, Debug)]
pub struct JoinWatch {
	seen: bool,
	fired_at: Option<u64>,
}

impl Default for JoinWatch {
	fn default() -> Self {
		Self { seen: false, fired_at: None }
	}
}

impl JoinWatch {
	/// `wanted` is the group consumers want. `largest` is the largest written group, `None` when empty.
	pub fn observe(&mut self, policy: &Keyframes, wanted: Option<u64>, largest: Option<u64>) -> bool {
		if !self.seen {
			self.seen = true;
			return false;
		}
		if !policy.enabled || !policy.on_join {
			return false;
		}
		let Some(wanted) = wanted else {
			return false;
		};
		if largest.is_none() && wanted == 0 {
			return false;
		}
		let largest = largest.unwrap_or(0);
		let over = wanted > largest && wanted - largest >= u64::from(policy.ratio);
		if over && self.fired_at != Some(wanted) {
			self.fired_at = Some(wanted);
			true
		} else {
			false
		}
	}
}

/// Causes on one send, for tests and the gate log.
pub fn cause_names(mask: u8) -> Vec<&'static str> {
	let mut names = Vec::new();
	for (cause, name) in [
		(Cause::Startup, "startup"),
		(Cause::Step, "step"),
		(Cause::Period, "period"),
		(Cause::Loss, "loss"),
		(Cause::Join, "join"),
	] {
		if mask & cause.bit() != 0 {
			names.push(name);
		}
	}
	names
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn floor_default_is_one_second_and_zero_is_invalid() {
		assert_eq!(Keyframes::default().floor, Duration::from_secs(1));
		assert!(Keyframes::default().validate().is_ok());
		let mut bad = Keyframes::trial();
		bad.floor = Duration::ZERO;
		assert!(bad.validate().is_err());
		bad = Keyframes::trial();
		bad.period = Duration::ZERO;
		assert!(bad.validate().is_err());
	}

	#[test]
	fn two_enabled_requests_are_a_second_apart() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		gate.note(Cause::Startup, t0);
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
		gate.note(Cause::Step, t0);
		assert!(gate.poll_send(&policy, t0, true).is_none(), "inside the floor");
		let later = t0.saturating_add(policy.floor);
		assert!(matches!(gate.poll_send(&policy, later, true), Some(Send::Sent { .. })));
	}

	#[test]
	fn overlapping_causes_are_one_send() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		for cause in [Cause::Startup, Cause::Step, Cause::Period, Cause::Loss, Cause::Join] {
			gate.note(cause, t0);
		}
		match gate.poll_send(&policy, t0, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["startup", "step", "period", "loss", "join"]),
			other => panic!("{other:?}"),
		}
		assert!(gate.poll_send(&policy, t0, true).is_none());
	}

	#[test]
	fn a_keyframe_cancels_the_held_request() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		gate.note(Cause::Startup, t0);
		gate.on_keyframe(&policy, t0);
		assert!(gate.poll_send(&policy, t0, true).is_none());
	}

	#[test]
	fn an_unanswered_pli_arms_the_period_four_seconds_out() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		let sent_at = t0.saturating_add(Duration::from_secs(2));
		gate.note(Cause::Period, sent_at);
		assert!(matches!(gate.poll_send(&policy, sent_at, true), Some(Send::Sent { .. })));
		let deadline = gate.deadline().unwrap();
		assert_eq!(deadline, sent_at.saturating_add(Duration::from_secs(2)));
		assert!(gate.take_deadline(sent_at).is_none(), "not due yet");
		assert!(gate.take_deadline(deadline).is_some());
		assert!(gate.take_deadline(deadline).is_none(), "a past deadline is returned once");
	}

	#[test]
	fn a_refused_writer_holds_and_does_not_move_last_sent() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		gate.note(Cause::Startup, t0);
		assert!(matches!(gate.poll_send(&policy, t0, false), Some(Send::Held { .. })));
		assert_eq!(gate.held, 1);
		assert!(gate.last_sent.is_none());
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
	}

	#[test]
	fn a_line_without_pli_never_sends() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(false);
		gate.note(Cause::Startup, Instant::now());
		assert!(gate.poll_send(&policy, Instant::now(), true).is_none());
	}

	#[test]
	fn a_future_deadline_rearms() {
		let mut gate = Gate::new(true);
		let now = Instant::now();
		gate.take_deadline(now);
		let later = now.saturating_add(Duration::from_secs(3));
		gate.rearm(later, now);
		assert_eq!(gate.deadline(), Some(later));
	}

	#[test]
	fn the_first_join_reading_requests_nothing() {
		let policy = Keyframes::trial();
		let mut watch = JoinWatch::default();
		assert!(!watch.observe(&policy, Some(8), Some(0)));
		assert!(watch.observe(&policy, Some(8), Some(0)), "the same demand, once it is a change past the first read");
		assert!(!watch.observe(&policy, Some(2), Some(0)), "under the ratio");
		assert!(!watch.observe(&policy, Some(0), None), "an empty track's group 0");
	}

	#[tokio::test(start_paused = true)]
	async fn the_earliest_armed_deadline_is_the_paused_clock() {
		let now = Instant::now();
		let remb = Some(now.saturating_add(Duration::from_secs(5)));
		let gate = Some(now.saturating_add(Duration::from_secs(1)));
		assert_eq!(earliest_deadline([remb, gate, None]), gate);
		assert!(earliest_deadline([None, None]).is_none());
	}

	#[test]
	fn loss_off_adds_no_loss_cause_and_startup_still_notes() {
		let mut policy = Keyframes::trial();
		policy.on_loss = false;
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		if policy.on_loss {
			gate.note(Cause::Loss, t0);
		}
		gate.note(Cause::Startup, t0);
		match gate.poll_send(&policy, t0, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["startup"]),
			other => panic!("{other:?}"),
		}
	}
}
