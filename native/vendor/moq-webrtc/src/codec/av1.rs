// Modified by the Mjolnir contributors for World Tree Network Foundation in 2026.
//! AV1 bridge.
//!
//! str0m hands us complete AV1 temporal units (OBU-framed, with inline sequence
//! headers). This feeds the moq-mux AV1 splitter/importer so catalog config and
//! keyframe detection stay shared with the other ingest paths.

use crate::{Result, codec};

/// Bridges str0m AV1 temporal units into a MoQ AV1 track.
pub struct Bridge {
	split: moq_mux::codec::av1::Split,
	import: moq_mux::codec::av1::Import,
	track: moq_net::track::Producer,
	demand: moq_net::track::Demand,
}

impl Bridge {
	/// Publish an `.av1` track on `broadcast`, adding the catalog rendition once config is known.
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
		let track = broadcast.unique_track(".av1", info)?;
		let demand = track.demand();
		let import = moq_mux::codec::av1::Import::new(track.clone(), catalog.reserve(), Default::default())?;
		let split = moq_mux::codec::av1::Split::new();
		Ok(Self { split, import, track, demand })
	}
}

impl codec::Bridge for Bridge {
	fn push(&mut self, frame: codec::Frame) -> Result<()> {
		let pts = moq_net::Timestamp::from_micros(frame.timestamp_us).map_err(moq_mux::Error::from)?;
		// str0m hands over one whole temporal unit per frame, so flush to emit it.
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
}
