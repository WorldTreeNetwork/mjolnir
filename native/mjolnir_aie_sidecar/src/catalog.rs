// SPDX-License-Identifier: AGPL-3.0-or-later

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Catalog {
    pub ids: HashSet<String>,
    pub argv: HashMap<String, Vec<String>>,
}

impl Catalog {
    pub fn load() -> Self {
        let mut ids: HashSet<String> = ["vector-add", "validate", "npu2-vector-add"]
            .into_iter()
            .map(str::to_string)
            .collect();
        let mut argv = HashMap::new();
        let path = std::env::var("AIE_CATALOG")
            .map(PathBuf::from)
            .unwrap_or_else(|_| default_catalog_path());
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(arr) = v.get("designs").and_then(|d| d.as_array()) {
                    ids = arr
                        .iter()
                        .filter_map(|x| x.as_str().map(|s| s.to_string()))
                        .collect();
                }
                if let Some(map) = v.get("argv").and_then(|d| d.as_object()) {
                    for (k, val) in map {
                        if let Some(args) = val.as_array() {
                            argv.insert(
                                k.clone(),
                                args.iter()
                                    .filter_map(|x| x.as_str().map(|s| s.to_string()))
                                    .collect(),
                            );
                        }
                    }
                }
            }
        }
        Self { ids, argv }
    }

    pub fn accepted(&self, design_id: &str) -> bool {
        self.ids.contains(design_id) && !guest_xclbin(design_id)
    }

    pub fn worker_argv(&self, design_id: &str) -> Option<Vec<String>> {
        if !self.accepted(design_id) {
            return None;
        }
        self.argv.get(design_id).cloned().or_else(|| {
            Some(vec![
                "/bin/sleep".into(),
                std::env::var("AIE_STUB_SLEEP_SECS").unwrap_or_else(|_| "1".into()),
            ])
        })
    }
}

pub fn guest_xclbin(id: &str) -> bool {
    id.contains('/') || id.contains('\\') || id.ends_with(".xclbin")
}

pub fn default_catalog_path() -> PathBuf {
    PathBuf::from("/etc/mjolnir/aie-catalog.json")
}
