//! Host-to-(apex, subdomain, backend) routing table.
//!
//! The table is built from a `LoadedConfig` and consumed by `main.rs`. It is
//! cheap to clone (backing data is an `Arc`) but the **live** table is stored
//! behind an [`arc_swap::ArcSwap`] so SIGHUP can atomically swap it in.

use std::net::SocketAddr;
use std::sync::Arc;

use crate::config::{Alias, Apex, LoadedConfig, Route};

/// Immutable snapshot of the routing state: apex list (sorted for longest-suffix
/// match) + `(apex, subdomain) → backend` map + vanity `(apex, subdomain) → Iroh
/// node` alias map.
#[derive(Debug, Clone)]
pub struct RouteTable {
    /// Apex list, sorted by `suffix.len()` descending so the longest match wins.
    apexes: Arc<Vec<Apex>>,
    /// Flat route list — small N, linear scan is fine.
    routes: Arc<Vec<Route>>,
    /// Flat alias list — vanity subdomains pinned to Iroh node IDs.
    aliases: Arc<Vec<Alias>>,
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
            aliases: Arc::new(cfg.aliases.clone()),
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

    /// Look up the retained Iroh fallback for `(apex, subdomain)`. On hit (the
    /// route shadowed an alias), returns the synthetic `<node>[-<port>]`
    /// subdomain to feed into the Iroh proxy path — used for self-healing
    /// failover when the local backend is unreachable (Phase 3).
    pub fn lookup_local_fallback(&self, apex: &Apex, subdomain: &str) -> Option<String> {
        let sub_lower = subdomain.to_ascii_lowercase();
        self.routes
            .iter()
            .find(|r| r.apex == apex.suffix && r.subdomain == sub_lower)
            .and_then(|r| r.fallback_target_subdomain())
    }

    /// Look up a vanity alias for `(apex, subdomain)`. On hit, returns the
    /// synthetic `<node>[-<port>]` subdomain string to feed into the Iroh proxy
    /// path — letting a friendly name like `zine` resolve to a pinned node ID.
    pub fn lookup_alias(&self, apex: &Apex, subdomain: &str) -> Option<String> {
        let sub_lower = subdomain.to_ascii_lowercase();
        self.aliases
            .iter()
            .find(|a| a.apex == apex.suffix && a.subdomain == sub_lower)
            .map(|a| a.target_subdomain())
    }

    pub fn alias_count(&self) -> usize {
        self.aliases.len()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Alias, Apex, Fallthrough, Route};

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
            aliases: Arc::new(Vec::new()),
        }
    }

    /// Like `table` but also seeds the alias list.
    fn table_with_aliases(apexes: Vec<Apex>, routes: Vec<Route>, aliases: Vec<Alias>) -> RouteTable {
        let mut apexes = apexes;
        apexes.sort_by(|a, b| b.suffix.len().cmp(&a.suffix.len()));
        RouteTable {
            apexes: Arc::new(apexes),
            routes: Arc::new(routes),
            aliases: Arc::new(aliases),
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
                fallback_node: None,
                fallback_port: None,
            }],
        );
        let (a, sub) = t.match_host("git-3001.worldtree.network").expect("match");
        assert_eq!(sub, "git-3001");
        let backend = t.lookup_local(a, &sub).expect("route hit");
        assert_eq!(backend, "127.0.0.1:3000".parse::<SocketAddr>().unwrap());
    }

    #[test]
    fn lookup_local_matches_empty_apex_route() {
        // An apex-level route (subdomain="") is looked up with the empty
        // subdomain that match_host yields for a bare apex host.
        let t = table(
            vec![apex("startupcentral.build", Fallthrough::None)],
            vec![Route {
                apex: "startupcentral.build".into(),
                subdomain: String::new(),
                backend: "127.0.0.1:3000".parse().unwrap(),
                fallback_node: None,
                fallback_port: None,
            }],
        );
        let (a, sub) = t.match_host("startupcentral.build").expect("match");
        assert_eq!(sub, "", "bare apex yields empty subdomain");
        let backend = t.lookup_local(a, &sub).expect("apex route hit");
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
                fallback_node: None,
                fallback_port: None,
            }],
        );
        let (a, sub) = t.match_host("Git.Worldtree.NETWORK").expect("match");
        assert_eq!(sub, "git");
        assert!(t.lookup_local(a, &sub).is_some());
    }

    // A valid 52-char z32 string that decodes to 32 bytes.
    const NODE_Z32: &str = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";

    fn alias(apex: &str, sub: &str, port: Option<u16>) -> Alias {
        Alias {
            apex: apex.into(),
            subdomain: sub.into(),
            node_z32: NODE_Z32.into(),
            port,
        }
    }

    #[test]
    fn alias_lookup_hit_renders_synthetic_subdomain() {
        // `zine.identikey.io` under a `none` apex still resolves via the alias,
        // yielding the synthetic `<node>` subdomain (no port → bare node).
        let t = table_with_aliases(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![],
            vec![alias("identikey.io", "zine", None)],
        );
        let (a, sub) = t.match_host("zine.identikey.io").expect("match");
        assert!(t.lookup_local(a, &sub).is_none(), "no local route");
        assert_eq!(t.lookup_alias(a, &sub).as_deref(), Some(NODE_Z32));
    }

    #[test]
    fn alias_lookup_appends_port() {
        let t = table_with_aliases(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![],
            vec![alias("identikey.io", "zine", Some(3000))],
        );
        let (a, sub) = t.match_host("zine.identikey.io").expect("match");
        assert_eq!(
            t.lookup_alias(a, &sub).as_deref(),
            Some(format!("{NODE_Z32}-3000").as_str())
        );
    }

    #[test]
    fn alias_lookup_is_case_insensitive_and_apex_scoped() {
        let t = table_with_aliases(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![],
            vec![alias("identikey.io", "zine", None)],
        );
        let (a, sub) = t.match_host("ZINE.identikey.io").expect("match");
        assert!(t.lookup_alias(a, &sub).is_some(), "matching is case-insensitive");
        // A different subdomain under the same apex misses.
        let (a2, sub2) = t.match_host("other.identikey.io").expect("match");
        assert!(t.lookup_alias(a2, &sub2).is_none());
    }

    #[test]
    fn lookup_local_fallback_returns_retained_iroh_target() {
        // A route that shadowed an alias carries the alias's node as a fallback;
        // lookup_local_fallback renders the synthetic `<node>-<port>` subdomain.
        let t = table_with_aliases(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![Route {
                apex: "identikey.io".into(),
                subdomain: "zine".into(),
                backend: "10.0.0.5:3000".parse().unwrap(),
                fallback_node: Some(NODE_Z32.into()),
                fallback_port: Some(3000),
            }],
            vec![],
        );
        let (a, sub) = t.match_host("zine.identikey.io").expect("match");
        assert!(t.lookup_local(a, &sub).is_some(), "local route present");
        assert_eq!(
            t.lookup_local_fallback(a, &sub).as_deref(),
            Some(format!("{NODE_Z32}-3000").as_str())
        );
    }

    #[test]
    fn lookup_local_fallback_none_when_no_fallback() {
        let t = table(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![Route {
                apex: "identikey.io".into(),
                subdomain: "git".into(),
                backend: "10.0.0.5:3000".parse().unwrap(),
                fallback_node: None,
                fallback_port: None,
            }],
        );
        let (a, sub) = t.match_host("git.identikey.io").expect("match");
        assert!(t.lookup_local_fallback(a, &sub).is_none());
    }
}
