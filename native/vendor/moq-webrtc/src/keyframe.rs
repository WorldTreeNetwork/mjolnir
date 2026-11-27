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

/// Why the one armed deadline exists.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Wake {
	#[default]
	Period,
	/// A held request becomes sendable at the floor boundary.
	Send,
}

/// One held request: a bit, a cause mask, and one deadline.
#[derive(Clone, Debug, Default)]
pub struct Gate {
	pending: bool,
	causes: u8,
	deadline: Option<Instant>,
	wake: Wake,
	/// A refused or missing writer. The timer stays disarmed until media arrives
	/// or a cause schedules a strictly future instant.
	parked: bool,
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

	/// Enabled video line. Arms the period immediately when the line can send PLI,
	/// before any RTP. A line that did not negotiate PLI contributes no timer.
	pub fn open(policy: &Keyframes, now: Instant, pli: bool) -> Self {
		let mut gate = Self::new(pli);
		if policy.enabled && pli {
			gate.arm_period(policy, now);
		}
		gate
	}

	pub fn note(&mut self, cause: Cause, when: Instant, policy: &Keyframes) {
		self.pending = true;
		self.causes |= cause.bit();
		let at = self.earliest_send(policy, when);
		// A cause whose send is strictly after `when` is the future re-arm that
		// lifts a parked line. An immediate cause stays parked until media arrives.
		if self.parked && at <= when {
			return;
		}
		self.parked = false;
		self.schedule_send(policy, when);
	}

	/// Media arrived on a parked line. Schedule the held request, at the floor if one is still in force.
	pub fn on_receiver(&mut self, policy: &Keyframes, now: Instant) {
		if !(self.parked && self.pending && self.pli) {
			return;
		}
		self.parked = false;
		self.schedule_send(policy, now);
	}

	/// A keyframe cancels the held request and starts the period from now.
	pub fn on_keyframe(&mut self, policy: &Keyframes, now: Instant) {
		self.pending = false;
		self.causes = 0;
		self.parked = false;
		self.deadline = None;
		self.last_keyframe = Some(now);
		if policy.enabled && self.pli {
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
		self.wake = Wake::Period;
	}

	fn earliest_send(&self, policy: &Keyframes, not_before: Instant) -> Instant {
		match self.last_sent {
			Some(sent) => not_before.max(sent.saturating_add(policy.floor)),
			None => not_before,
		}
	}

	/// Arm the soonest send that still respects the floor. Never replaces an earlier deadline.
	fn schedule_send(&mut self, policy: &Keyframes, not_before: Instant) {
		if !self.pli {
			self.deadline = None;
			return;
		}
		let at = self.earliest_send(policy, not_before);
		let sooner = self.deadline.is_none_or(|existing| at < existing);
		if sooner {
			self.deadline = Some(at);
			self.wake = Wake::Send;
		}
	}

	/// The armed instant was reached. Period is recorded only when this wake is the period itself.
	/// A floor-blocked request is rescheduled at the floor. A line without PLI is left disarmed.
	pub fn on_timer(&mut self, policy: &Keyframes, now: Instant) {
		let wake = self.wake;
		self.deadline = None;
		if !self.pli {
			return;
		}
		if wake == Wake::Period {
			self.pending = true;
			self.causes |= Cause::Period.bit();
		}
		if self.parked || !self.pending {
			return;
		}
		if let Some(sent) = self.last_sent {
			let floor = sent.saturating_add(policy.floor);
			if now < floor {
				self.deadline = Some(floor);
				self.wake = Wake::Send;
			}
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
			self.parked = true;
			self.deadline = None;
			return Some(Send::Held { causes });
		}
		self.pending = false;
		self.causes = 0;
		self.last_sent = Some(now);
		self.arm_period(policy, now);
		Some(Send::Sent { causes })
	}

}

/// Earliest armed instant. A disarmed line contributes nothing.
pub fn earliest_deadline<I>(times: I) -> Option<Instant>
where
	I: IntoIterator<Item = Option<Instant>>,
{
	times.into_iter().flatten().min()
}

/// Join against live demand. The ratio itself is the track's payload-byte refresh.
/// This watch only sees the group that demand already asked for, and the first
/// reading is the baseline.
#[derive(Clone, Debug, Default)]
pub struct JoinWatch {
	/// `None` until the first sample. The sample's wanted value is the baseline.
	baseline: Option<Option<u64>>,
	fired_at: Option<u64>,
}

impl JoinWatch {
	/// `wanted` is the group consumers want. `largest` is the largest written group, `None` when empty.
	///
	/// Fires when `wanted` changes past the baseline to a group strictly after `largest`.
	/// An empty track's group 0 is not a join. The same sample never fires twice.
	pub fn observe(&mut self, policy: &Keyframes, wanted: Option<u64>, largest: Option<u64>) -> bool {
		if self.baseline.is_none() {
			self.baseline = Some(wanted);
			return false;
		}
		if self.baseline == Some(wanted) {
			return false;
		}
		self.baseline = Some(wanted);
		if !policy.enabled || !policy.on_join {
			return false;
		}
		let Some(wanted) = wanted else {
			return false;
		};
		if largest.is_none() && wanted == 0 {
			return false;
		}
		let Some(largest) = largest else {
			return false;
		};
		if wanted > largest && self.fired_at != Some(wanted) {
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
		gate.note(Cause::Startup, t0, &policy);
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
		gate.note(Cause::Step, t0, &policy);
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
			gate.note(cause, t0, &policy);
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
		gate.note(Cause::Startup, t0, &policy);
		gate.on_keyframe(&policy, t0);
		assert!(gate.poll_send(&policy, t0, true).is_none());
	}

	#[test]
	fn an_unanswered_pli_arms_the_period_four_seconds_out() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		let sent_at = t0.saturating_add(Duration::from_secs(2));
		gate.note(Cause::Period, sent_at, &policy);
		assert!(matches!(gate.poll_send(&policy, sent_at, true), Some(Send::Sent { .. })));
		let deadline = gate.deadline().unwrap();
		assert_eq!(deadline, sent_at.saturating_add(Duration::from_secs(2)));
		gate.on_timer(&policy, deadline);
		assert!(gate.deadline().is_none_or(|at| at > deadline), "the matured period is not armed again at the same instant");
	}

	#[test]
	fn a_refused_writer_holds_and_does_not_move_last_sent() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		gate.note(Cause::Startup, t0, &policy);
		assert!(matches!(gate.poll_send(&policy, t0, false), Some(Send::Held { .. })));
		assert_eq!(gate.held, 1);
		assert!(gate.last_sent.is_none());
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
	}

	#[test]
	fn a_line_without_pli_never_sends() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(false);
		gate.note(Cause::Startup, Instant::now(), &policy);
		assert!(gate.poll_send(&policy, Instant::now(), true).is_none());
	}

	#[test]
	fn held_loss_is_scheduled_at_the_floor_not_the_period() {
		let policy = Keyframes::trial();
		let mut gate = Gate::new(true);
		let t0 = Instant::now();
		gate.note(Cause::Startup, t0, &policy);
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
		let loss_at = t0.saturating_add(Duration::from_millis(300));
		gate.note(Cause::Loss, loss_at, &policy);
		let floor = t0.saturating_add(policy.floor);
		assert_eq!(gate.deadline(), Some(floor));
		assert!(floor > loss_at);
		assert!(gate.deadline().is_some_and(|at| at == floor));
		gate.on_timer(&policy, floor);
		match gate.poll_send(&policy, floor, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["loss"]),
			other => panic!("{other:?}"),
		}
	}

	#[test]
	fn a_period_shorter_than_the_floor_wakes_once_then_waits() {
		let mut policy = Keyframes::trial();
		policy.period = Duration::from_millis(100);
		let t0 = Instant::now();
		let mut gate = Gate::new(true);
		gate.note(Cause::Startup, t0, &policy);
		assert!(matches!(gate.poll_send(&policy, t0, true), Some(Send::Sent { .. })));
		let early = t0.saturating_add(policy.period);
		assert_eq!(gate.deadline(), Some(early));
		gate.on_timer(&policy, early);
		let floor = t0.saturating_add(policy.floor);
		assert_eq!(gate.deadline(), Some(floor));
		for _ in 0..100 {
			assert!(gate.deadline().is_some_and(|at| early < at));
			if gate.deadline().is_some_and(|at| early >= at) {
				gate.on_timer(&policy, early);
			}
		}
		gate.on_timer(&policy, floor);
		match gate.poll_send(&policy, floor, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["period"]),
			other => panic!("{other:?}"),
		}
	}

	#[test]
	fn a_line_without_pli_contributes_no_timer() {
		let mut policy = Keyframes::trial();
		policy.period = Duration::from_millis(100);
		let t0 = Instant::now();
		let mut gate = Gate::open(&policy, t0, false);
		assert!(gate.deadline().is_none());
		gate.on_keyframe(&policy, t0);
		assert!(gate.deadline().is_none());
		let later = t0.saturating_add(Duration::from_secs(10));
		for _ in 0..100 {
			if gate.deadline().is_some_and(|at| later >= at) {
				gate.on_timer(&policy, later);
			}
			assert!(gate.deadline().is_none());
		}
	}

	#[test]
	fn silence_parks_a_missing_writer_until_media() {
		let policy = Keyframes::trial();
		let t0 = Instant::now();
		let mut gate = Gate::open(&policy, t0, true);
		let due = t0.saturating_add(policy.period);
		assert_eq!(gate.deadline(), Some(due));
		gate.on_timer(&policy, due);
		assert!(matches!(gate.poll_send(&policy, due, false), Some(Send::Held { .. })));
		assert!(gate.deadline().is_none(), "parked, so ten seconds of silence do not spin");
		let later = due.saturating_add(Duration::from_secs(10));
		assert!(gate.poll_send(&policy, later, true).is_some());
		// The direct retry above is the caller asking again. The timer path stays quiet
		// until a receiver or a future cause. Rebuild the parked state and wait for media.
		let mut gate = Gate::open(&policy, t0, true);
		gate.on_timer(&policy, due);
		assert!(matches!(gate.poll_send(&policy, due, false), Some(Send::Held { .. })));
		gate.on_receiver(&policy, later);
		assert_eq!(gate.deadline(), Some(later));
		gate.on_timer(&policy, later);
		match gate.poll_send(&policy, later, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["period"]),
			other => panic!("{other:?}"),
		}
	}

	#[test]
	fn the_first_join_reading_is_a_baseline() {
		let policy = Keyframes::trial();
		let mut watch = JoinWatch::default();
		assert!(!watch.observe(&policy, None, None));
		assert!(watch.observe(&policy, Some(1), Some(0)), "demand moved past the baseline to the next group");
		assert!(!watch.observe(&policy, Some(1), Some(0)), "unchanged demand");
		let mut high = JoinWatch::default();
		assert!(!high.observe(&policy, Some(1), Some(0)), "the first reading, even when already eligible");
		assert!(!high.observe(&policy, Some(1), Some(0)), "the same initial demand is not a change");
		assert!(!watch.observe(&policy, Some(0), Some(0)), "not past the largest group");
		assert!(!watch.observe(&policy, Some(0), None), "an empty track's group 0");
		let mut again = JoinWatch::default();
		assert!(!again.observe(&policy, Some(1), Some(0)), "a rendition's first sample is its own baseline");
	}

	#[test]
	fn a_real_track_join_past_ratio_four_asks_for_the_next_group_once() {
		let broadcast = moq_net::broadcast::Info::new().produce();
		let track = broadcast
			.unique_track("v", moq_net::track::Info::default().with_refresh(Some(4)))
			.unwrap();
		let mut group = track.create_group(moq_net::group::Info { start: 1 }).unwrap();
		group
			.write_frame(moq_net::Timestamp::unscaled(1), &b"key"[..])
			.unwrap();
		group
			.write_frame(moq_net::Timestamp::unscaled(1), vec![0u8; 13])
			.unwrap();
		group.finish().unwrap();
		let largest = track.largest().map(|position| position.group);
		let demand = track.demand();
		let policy = Keyframes::trial();
		let mut watch = JoinWatch::default();
		assert!(!watch.observe(&policy, demand.wanted(), largest));
		let _subscriber = track.subscribe(None);
		let wanted = demand.wanted();
		assert_eq!(wanted, Some(largest.unwrap() + 1));
		assert!(watch.observe(&policy, wanted, largest));
		assert!(!watch.observe(&policy, demand.wanted(), largest));

		let under = broadcast
			.unique_track("u", moq_net::track::Info::default().with_refresh(Some(4)))
			.unwrap();
		let mut group = under.create_group(moq_net::group::Info { start: 1 }).unwrap();
		group
			.write_frame(moq_net::Timestamp::unscaled(1), &b"key"[..])
			.unwrap();
		group.finish().unwrap();
		let largest = under.largest().map(|position| position.group);
		let mut watch = JoinWatch::default();
		assert!(!watch.observe(&policy, under.demand().wanted(), largest));
		let _subscriber = under.subscribe(None);
		assert_eq!(under.demand().wanted(), Some(0));
		assert!(!watch.observe(&policy, under.demand().wanted(), largest));
	}

	#[tokio::test]
	async fn a_disarmed_timer_does_not_starve_the_peer_event() {
		let mut policy = Keyframes::trial();
		policy.period = Duration::from_millis(100);
		let mut gate = Gate::open(&policy, Instant::now(), false);
		let (tx, mut rx) = tokio::sync::mpsc::channel(1);
		tx.try_send(()).unwrap();
		let peer = tokio::time::timeout(Duration::from_secs(1), async {
			tokio::select! {
				biased;
				_ = async {
					loop {
						match gate.deadline() {
							Some(at) => {
								kio::clock::sleep_until(at).await;
								let now = Instant::now();
								if gate.deadline().is_some_and(|due| now >= due) {
									gate.on_timer(&policy, now);
								}
							}
							None => std::future::pending::<()>().await,
						}
					}
				} => panic!("the timer arm ended"),
				_ = rx.recv() => {}
			}
		})
		.await;
		assert!(peer.is_ok(), "a line without PLI left the peer event unpolled");
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
			gate.note(Cause::Loss, t0, &policy);
		}
		gate.note(Cause::Startup, t0, &policy);
		match gate.poll_send(&policy, t0, true) {
			Some(Send::Sent { causes }) => assert_eq!(cause_names(causes), ["startup"]),
			other => panic!("{other:?}"),
		}
	}
}
