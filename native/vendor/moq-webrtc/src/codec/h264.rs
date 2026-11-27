// Modified by the Mjolnir contributors for World Tree Network Foundation in 2026.
//! H.264 bridge.
//!
//! str0m hands us reassembled Annex-B frames (start-code prefixed NALs with
//! inline SPS/PPS), which is exactly what
//! [`moq_mux::codec::h264::Import`] in Avc3 mode wants. We just convert the
//! timestamp and stream NALs in.

use crate::{Result, codec};

pub struct Bridge {
	split: moq_mux::codec::h264::Split,
	import: moq_mux::codec::h264::Import,
	track: moq_net::track::Producer,
	demand: moq_net::track::Demand,
}

impl Bridge {
	#[allow(dead_code)] // Pin constructor. Ingest calls `opening` so a refresh ratio can be set.
	pub fn new(broadcast: moq_net::broadcast::Producer, catalog: moq_mux::catalog::Producer) -> Result<Self> {
		Self::opening(broadcast, catalog, None)
	}

	/// As [`new`](Self::new), with a refresh ratio on the video track when set.
	pub fn opening(
		broadcast: moq_net::broadcast::Producer,
		catalog: moq_mux::catalog::Producer,
		refresh: Option<u32>,
	) -> Result<Self> {
		let mut info = catalog.track_info(hang::catalog::PRIORITY.video);
		if let Some(ratio) = refresh {
			info = info.with_refresh(Some(ratio));
		}
		let track = broadcast.unique_track(".avc3", info)?;
		let demand = track.demand();
		let import = moq_mux::codec::h264::Import::new(track.clone(), catalog.reserve(), Default::default())?;
		let split = moq_mux::codec::h264::Split::new();
		Ok(Self { split, import, track, demand })
	}
}

impl codec::Bridge for Bridge {
	fn push(&mut self, frame: codec::Frame) -> Result<()> {
		let pts = moq_net::Timestamp::from_micros(frame.timestamp_us).map_err(moq_mux::Error::from)?;
		// str0m hands over one whole access unit per frame, so flush to emit it.
		let mut frames = self.split.decode(&frame.payload, Some(pts))?;
		frames.extend(self.split.flush(Some(pts))?);
		self.import.decode(frames)?;
		Ok(())
	}

	fn discontinuity(&mut self) -> Result<()> {
		self.import.discontinuity()?;
		Ok(())
	}

	fn finish(self: Box<Self>) -> Result<codec::Finished> {
		Ok(Box::new(self.import.finish()?))
	}

	fn abort(self: Box<Self>, err: moq_net::Error) {
		self.import.abort(err);
	}

	fn join_sample(&self) -> Option<(Option<u64>, Option<u64>)> {
		Some((self.demand.wanted(), self.track.largest().map(|position| position.group)))
	}

	fn demand(&self) -> Option<moq_net::track::Demand> {
		Some(self.demand.clone())
	}
}
