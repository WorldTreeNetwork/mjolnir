//! Host-to-(apex, subdomain, backend) routing table.
//!
//! The table is built from a `LoadedConfig` and consumed by `main.rs`. It is
//! cheap to clone (backing data is an `Arc`) but the **live** table is stored
//! behind an [`arc_swap::ArcSwap`] so SIGHUP can atomically swap it in.

use std::net::SocketAddr;
use std::sync::Arc;

use crate::config::{Apex, LoadedConfig, Route};

/// Immutable snapshot of the routing state: apex list (sorted for longest-suffix
/// match) + `(apex, subdomain) → backend` map.
#[derive(Debug, Clone)]
pub struct RouteTable {
    /// Apex list, sorted by `suffix.len()` descending so the longest match wins.
    apexes: Arc<Vec<Apex>>,
    /// Flat route list — small N, linear scan is fine.
    routes: Arc<Vec<Route>>,
}

impl RouteTable {
    /// Build a table from the normalized config. Apexes and route subdomains
    /// must already be lowercased (the config loader enforces this).
    pub fn from_config(cfg: &LoadedConfig) -> Self {
        let mut apexes = cfg.apexes.clone();
        // Longest first — critical for the overlapping-apex test case.
        apexes.sort_by(|a, b| b.suffix.len().cmp(&a.suffix.len()));
        Self {
            apexes: Arc::new(apexes),
            routes: Arc::new(cfg.routes.clone()),
        }
    }

    pub fn apex_count(&self) -> usize {
        self.apexes.len()
    }

    pub fn route_count(&self) -> usize {
        self.routes.len()
    }

    pub fn apexes(&self) -> &[Apex] {
        &self.apexes
    }

    pub fn routes(&self) -> &[Route] {
        &self.routes
    }

    /// Match a Host header's bare hostname (already stripped of any `:port`
    /// suffix) against the apex list. Returns `(apex_ref, subdomain_lower)` on
    /// success.
    ///
    /// Longest-suffix wins: `git.vm.worldtree.network` with apexes
    /// `{vm.worldtree.network, worldtree.network}` resolves to the former.
    ///
    /// The subdomain is the raw substring before `.<apex>` — **not** split on
    /// `-<port>` (that's an Iroh-path concern).
    pub fn match_host<'a>(&'a self, host: &str) -> Option<(&'a Apex, String)> {
        let host_lower = host.to_ascii_lowercase();
        for apex in self.apexes.iter() {
            // Require a literal `.<apex>` boundary OR exact equality.
            if host_lower == apex.suffix {
                return Some((apex, String::new()));
            }
            let boundary = format!(".{}", apex.suffix);
            if let Some(prefix) = host_lower.strip_suffix(&boundary) {
                return Some((apex, prefix.to_owned()));
            }
        }
        None
    }

    /// Look up a local backend for `(apex, subdomain)`.
    pub fn lookup_local(&self, apex: &Apex, subdomain: &str) -> Option<SocketAddr> {
        let sub_lower = subdomain.to_ascii_lowercase();
        self.routes
            .iter()
            .find(|r| r.apex == apex.suffix && r.subdomain == sub_lower)
            .map(|r| r.backend)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Apex, Fallthrough, Route};

    fn apex(suffix: &str, ft: Fallthrough) -> Apex {
        Apex {
            suffix: suffix.to_owned(),
            fallthrough: ft,
        }
    }

    fn table(apexes: Vec<Apex>, routes: Vec<Route>) -> RouteTable {
        // Cannot call from_config without a LoadedConfig — build directly and
        // manually sort.
        let mut apexes = apexes;
        apexes.sort_by(|a, b| b.suffix.len().cmp(&a.suffix.len()));
        RouteTable {
            apexes: Arc::new(apexes),
            routes: Arc::new(routes),
        }
    }

    #[test]
    fn apex_match_longest_suffix_overlapping() {
        // `vm.worldtree.network` and `worldtree.network` both match
        // `git.vm.worldtree.network`; the longer one must win.
        let t = table(
            vec![
                apex("worldtree.network", Fallthrough::None),
                apex("vm.worldtree.network", Fallthrough::Iroh),
            ],
            vec![],
        );
        let (a, sub) = t.match_host("git.vm.worldtree.network").expect("match");
        assert_eq!(a.suffix, "vm.worldtree.network");
        assert_eq!(sub, "git");

        // And the short-apex request correctly resolves to the short apex.
        let (a2, sub2) = t.match_host("git.worldtree.network").expect("match");
        assert_eq!(a2.suffix, "worldtree.network");
        assert_eq!(sub2, "git");
    }

    #[test]
    fn apex_match_longest_suffix_disjoint() {
        let t = table(
            vec![
                apex("alice.dev", Fallthrough::Iroh),
                apex("bob.net", Fallthrough::None),
            ],
            vec![],
        );
        let (a, sub) = t.match_host("foo.alice.dev").expect("match");
        assert_eq!(a.suffix, "alice.dev");
        assert_eq!(sub, "foo");

        let (a, sub) = t.match_host("bar.bob.net").expect("match");
        assert_eq!(a.suffix, "bob.net");
        assert_eq!(sub, "bar");

        // Host not under any apex → None.
        assert!(t.match_host("foo.carol.io").is_none());
    }

    #[test]
    fn apex_match_requires_dot_boundary() {
        // `evm.worldtree.network` must not match apex `vm.worldtree.network`.
        let t = table(vec![apex("vm.worldtree.network", Fallthrough::Iroh)], vec![]);
        assert!(t.match_host("evm.worldtree.network").is_none());
    }

    #[test]
    fn apex_match_exact_equals_empty_subdomain() {
        // Host == apex → match with empty subdomain (caller decides to 400).
        let t = table(vec![apex("worldtree.network", Fallthrough::None)], vec![]);
        let (a, sub) = t.match_host("worldtree.network").expect("match");
        assert_eq!(a.suffix, "worldtree.network");
        assert_eq!(sub, "");
    }

    #[test]
    fn route_lookup_uses_raw_subdomain_not_port_split() {
        // A route declared as `git-3001` under apex `worldtree.network` must
        // match a request for `git-3001.worldtree.network` and NOT be
        // interpreted as `git` + port 3001.
        let t = table(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![Route {
                apex: "worldtree.network".into(),
                subdomain: "git-3001".into(),
                backend: "127.0.0.1:3000".parse().unwrap(),
            }],
        );
        let (a, sub) = t.match_host("git-3001.worldtree.network").expect("match");
        assert_eq!(sub, "git-3001");
        let backend = t.lookup_local(a, &sub).expect("route hit");
        assert_eq!(backend, "127.0.0.1:3000".parse::<SocketAddr>().unwrap());
    }

    #[test]
    fn nested_subdomain_preserves_dots() {
        // `git.internal.worldtree.network` under apex `worldtree.network` must
        // yield subdomain `git.internal` — the internal dot is preserved verbatim.
        let t = table(vec![apex("worldtree.network", Fallthrough::None)], vec![]);
        let (a, sub) = t.match_host("git.internal.worldtree.network").expect("match");
        assert_eq!(a.suffix, "worldtree.network");
        assert_eq!(sub, "git.internal", "dots inside subdomain must be preserved");
    }

    #[test]
    fn case_insensitive_tom_matches_git() {
        // Host sent as `Git.Worldtree.NETWORK`, route declared as `git`.
        let t = table(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![Route {
                apex: "worldtree.network".into(),
                subdomain: "git".into(),
                backend: "127.0.0.1:3000".parse().unwrap(),
            }],
        );
        let (a, sub) = t.match_host("Git.Worldtree.NETWORK").expect("match");
        assert_eq!(sub, "git");
        assert!(t.lookup_local(a, &sub).is_some());
    }
}
