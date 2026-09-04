//! Default page for an unbound name on a `fallthrough = "parked"` apex.
//!
//! This is the berth: the hostname exists in the fabric, but no machine is
//! tied to it yet. Binding the name is writing an `[[alias]]` (Iroh node ID)
//! — the page goes away the moment classify hits the alias.
//!
//! Unknown incoming names (unbound parked hosts, Sites misses) 302 to
//! [`CANONICAL_HOST`]. The berth page may mention the original host as an
//! aside, from `?from=` or the Referer.

/// Public berth URL. Unbound names redirect here.
pub const CANONICAL_HOST: &str = "park.worldtree.network";

/// True when `host` (already stripped of `:port`) is the canonical berth.
pub fn is_canonical_host(host: &str) -> bool {
    host.eq_ignore_ascii_case(CANONICAL_HOST)
}

/// HTML-escape a string that will be interpolated into the page.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// Visible name on the page: the subdomain if present, otherwise the apex.
pub fn display_name(host: &str, subdomain: &str) -> String {
    if subdomain.is_empty() {
        host.to_owned()
    } else {
        subdomain.to_owned()
    }
}

/// Full HTTP/1.1 response for the berth page.
pub fn http_response(host: &str, subdomain: &str, from: Option<&str>) -> Vec<u8> {
    let body = page(host, subdomain, from);
    format!(
        "HTTP/1.1 200 OK\r\n\
Content-Type: text/html; charset=utf-8\r\n\
Cache-Control: no-store\r\n\
Content-Length: {}\r\n\
Connection: close\r\n\
\r\n\
{}",
        body.len(),
        body
    )
    .into_bytes()
}

/// 302 to the canonical berth, carrying the original host as `?from=`.
pub fn redirect_to_canonical(from_host: &str) -> Vec<u8> {
    let location = match sanitize_hostname(from_host).filter(|h| !is_canonical_host(h)) {
        Some(h) => format!("https://{CANONICAL_HOST}/?from={h}"),
        None => format!("https://{CANONICAL_HOST}/"),
    };
    format!(
        "HTTP/1.1 302 Found\r\n\
Location: {location}\r\n\
Cache-Control: no-store\r\n\
Content-Length: 0\r\n\
Connection: close\r\n\
\r\n"
    )
    .into_bytes()
}

/// Hostname allowed in `?from=` / Referer: labels, dots, hyphens; no scheme, path, or port.
pub fn sanitize_hostname(raw: &str) -> Option<String> {
    let s = raw.trim();
    let s = s
        .strip_prefix("https://")
        .or_else(|| s.strip_prefix("http://"))
        .unwrap_or(s);
    let s = s.split(['/', '?', '#']).next().unwrap_or(s);
    let s = s.rsplit('@').next().unwrap_or(s);
    let s = match s.rsplit_once(':') {
        Some((h, port)) if port.bytes().all(|b| b.is_ascii_digit()) => h,
        _ => s,
    };
    let s = s.trim_matches('.');
    if s.is_empty() || s.len() > 253 {
        return None;
    }
    let ok = s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    if !ok || s.starts_with('-') || s.ends_with('-') || s.contains("..") {
        return None;
    }
    Some(s.to_ascii_lowercase())
}

/// Original host from `?from=` on the request line, else the Referer host.
pub fn origin_from_request(header_bytes: &[u8]) -> Option<String> {
    let end = header_bytes
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(header_bytes.len());
    let header_str = String::from_utf8_lossy(&header_bytes[..end]);
    let mut referer = None;
    for (i, line) in header_str.split("\r\n").enumerate() {
        if i == 0 {
            if let Some(from) = from_query(line) {
                return Some(from);
            }
        }
        let b = line.as_bytes();
        if b.len() > 8 && b[..8].eq_ignore_ascii_case(b"referer:") {
            referer = sanitize_hostname(line[8..].trim());
        }
    }
    referer.filter(|h| !is_canonical_host(h))
}

fn from_query(request_line: &str) -> Option<String> {
    // "GET /?from=foo.identikey.me HTTP/1.1"
    let target = request_line.split_whitespace().nth(1)?;
    let query = target.split_once('?')?.1;
    for pair in query.split('&') {
        let (k, v) = match pair.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        if k == "from" {
            return sanitize_hostname(&percent_decode(v)).filter(|h| !is_canonical_host(h));
        }
    }
    None
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(v) = u8::from_str_radix(hex, 16) {
                    out.push(v as char);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// Self-contained berth page. `host` is the bare hostname (no port);
/// `subdomain` is the label under the parked apex (empty on the apex itself).
/// `from` is an optional original host (redirect query or Referer).
pub fn page(host: &str, subdomain: &str, from: Option<&str>) -> String {
    let name = escape(&display_name(host, subdomain));
    let from_aside = match from.and_then(sanitize_hostname) {
        Some(h) if !h.eq_ignore_ascii_case(host) => {
            format!(r#" <span class="from">from {}</span>"#, escape(&h))
        }
        _ => String::new(),
    };
    let host = escape(host);
    format!(
        r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{name} — parked on mjolnir</title>
<link rel="preconnect" href="https://fonts.bunny.net">
<link href="https://fonts.bunny.net/css?family=syne:800|literata:400,400i|ibm-plex-mono:400" rel="stylesheet">
<style>
  :root {{
    --void: #070708;
    --ash: #8a857c;
    --steel: #e8e2d6;
    --copper: #d4783a;
    --ember: #ffb060;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  html, body {{ height: 100%; background: var(--void); color: var(--steel); }}
  body {{
    font-family: Literata, "Iowan Old Style", Georgia, serif;
    overflow: hidden;
    isolation: isolate;
  }}
  .grain {{
    position: fixed; inset: 0; pointer-events: none; z-index: 4;
    opacity: 0.14;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='4' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 .55 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>");
    mix-blend-mode: overlay;
  }}
  .vignette {{
    position: fixed; inset: 0; pointer-events: none; z-index: 3;
    background:
      radial-gradient(ellipse 70% 55% at 38% 48%, transparent 0%, rgba(7,7,8,.35) 58%, rgba(7,7,8,.92) 100%),
      linear-gradient(180deg, rgba(7,7,8,.25), transparent 18%, transparent 82%, rgba(7,7,8,.4));
  }}
  .dock {{
    position: fixed; inset: 0; z-index: 0;
    background:
      repeating-linear-gradient(
        90deg,
        transparent 0, transparent 79px,
        rgba(232,226,214,.035) 80px, rgba(232,226,214,.035) 81px
      ),
      repeating-linear-gradient(
        0deg,
        transparent 0, transparent 79px,
        rgba(232,226,214,.035) 80px, rgba(232,226,214,.035) 81px
      );
    mask-image: radial-gradient(ellipse 55% 50% at 38% 48%, #000 0%, transparent 75%);
  }}
  .ember {{
    position: fixed;
    width: 42vmin; height: 42vmin;
    left: 28%; top: 48%;
    transform: translate(-50%, -50%);
    background: radial-gradient(circle, rgba(212,120,58,.22) 0%, rgba(212,120,58,.06) 38%, transparent 70%);
    filter: blur(8px);
    z-index: 1;
    animation: breathe 7.5s ease-in-out infinite;
  }}
  .orbit {{
    position: fixed;
    width: min(78vmin, 820px); height: min(78vmin, 820px);
    left: 28%; top: 48%;
    transform: translate(-50%, -50%);
    z-index: 2;
    pointer-events: none;
  }}
  .orbit::before, .orbit::after {{
    content: "";
    position: absolute; inset: 0;
    border-radius: 50%;
    border: 1px solid rgba(232,226,214,.14);
  }}
  .orbit::after {{
    inset: 7%;
    border-color: rgba(212,120,58,.28);
    animation: spin 48s linear infinite;
    clip-path: polygon(50% 0, 54% 0, 54% 100%, 50% 100%);
  }}
  .tick {{
    position: absolute;
    top: -3px; left: 50%;
    width: 7px; height: 7px;
    background: var(--copper);
    border-radius: 50%;
    box-shadow: 0 0 12px var(--ember);
    transform: translateX(-50%);
  }}
  main {{
    position: relative; z-index: 5;
    height: 100%;
    display: grid;
    grid-template-rows: 1fr auto 1fr;
    padding: 7vh 8vw 6vh;
  }}
  .stamp {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.42em;
    text-transform: uppercase;
    color: var(--copper);
    align-self: end;
    padding-bottom: 3.5vh;
    animation: rise 1.1s cubic-bezier(.2,.8,.2,1) both;
  }}
  h1 {{
    font-family: Syne, "Arial Black", sans-serif;
    font-weight: 800;
    font-size: clamp(3.4rem, 11vw, 9.5rem);
    line-height: 0.88;
    letter-spacing: -0.045em;
    max-width: 16ch;
    text-wrap: balance;
    animation: rise 1.25s cubic-bezier(.2,.8,.2,1) 0.08s both;
  }}
  .lede {{
    font-style: italic;
    font-size: clamp(1.05rem, 2vw, 1.35rem);
    color: var(--ash);
    max-width: 42ch;
    line-height: 1.45;
    margin-top: 1.6rem;
    animation: rise 1.3s cubic-bezier(.2,.8,.2,1) 0.16s both;
  }}
  .lede .from {{
    font-size: 0.92em;
    opacity: 0.72;
  }}
  footer {{
    align-self: start;
    padding-top: 5vh;
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--ash);
    animation: rise 1.4s cubic-bezier(.2,.8,.2,1) 0.22s both;
  }}
  footer span {{ color: var(--steel); }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  @keyframes breathe {{
    0%, 100% {{ opacity: 0.7; transform: translate(-50%, -50%) scale(1); }}
    50% {{ opacity: 1; transform: translate(-50%, -50%) scale(1.08); }}
  }}
  @keyframes rise {{
    from {{ opacity: 0; transform: translateY(18px); filter: blur(6px); }}
    to {{ opacity: 1; transform: none; filter: none; }}
  }}
  @media (max-width: 720px) {{
    .orbit, .ember {{ left: 50%; }}
    h1 {{ font-size: clamp(2.8rem, 18vw, 5.2rem); }}
    main {{ padding: 8vh 7vw; }}
  }}
  @media (prefers-reduced-motion: reduce) {{
    .orbit::after, .ember, h1, .stamp, .lede, footer {{ animation: none; }}
  }}
</style>
</head>
<body>
  <div class="dock" aria-hidden="true"></div>
  <div class="ember" aria-hidden="true"></div>
  <div class="orbit" aria-hidden="true"><i class="tick"></i></div>
  <div class="vignette" aria-hidden="true"></div>
  <div class="grain" aria-hidden="true"></div>
  <main>
    <p class="stamp">parked</p>
    <div>
      <h1>{name}</h1>
      <p class="lede">A berth on the fabric. No machine is tied to this name yet.{from_aside}</p>
    </div>
    <footer>mjolnir · <span>{host}</span></footer>
  </main>
</body>
</html>
"##
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_is_html_safe() {
        assert_eq!(escape(r#"a<b>&"c'"#), "a&lt;b&gt;&amp;&quot;c&#39;");
    }

    #[test]
    fn display_name_prefers_subdomain() {
        assert_eq!(display_name("park.identikey.me", "park"), "park");
        assert_eq!(display_name("identikey.me", ""), "identikey.me");
    }

    #[test]
    fn page_embeds_escaped_host_and_is_html() {
        let html = page("park.identikey.me", "park", None);
        assert!(html.starts_with("<!DOCTYPE html>"));
        assert!(html.contains("<h1>park</h1>"));
        assert!(html.contains("park.identikey.me"));
        assert!(!html.contains("<script"));
        assert!(!html.contains(r#"class="from""#));
    }

    #[test]
    fn page_mentions_from_host_as_aside() {
        let html = page(
            "park.worldtree.network",
            "",
            Some("https://foo.identikey.me/path"),
        );
        assert!(html.contains(
            "A berth on the fabric. No machine is tied to this name yet. <span class=\"from\">from foo.identikey.me</span>"
        ));
        assert!(html.contains("<h1>park.worldtree.network</h1>"));
    }

    #[test]
    fn page_from_is_html_escaped() {
        let html = page("park.worldtree.network", "", Some("<script>x</script>.me"));
        assert!(!html.contains("<script>x</script>"));
        // invalid hostname dropped entirely
        assert!(!html.contains(r#"class="from""#));
    }

    #[test]
    fn http_response_is_200_html_no_store() {
        let raw = String::from_utf8(http_response("park.identikey.me", "park", None)).unwrap();
        assert!(raw.starts_with("HTTP/1.1 200 OK"));
        assert!(raw.contains("Content-Type: text/html; charset=utf-8"));
        assert!(raw.contains("Cache-Control: no-store"));
        assert!(raw.contains("<h1>park</h1>"));
    }

    #[test]
    fn redirect_carries_from_query() {
        let raw = String::from_utf8(redirect_to_canonical("Foo.IdentiKey.me")).unwrap();
        assert!(raw.starts_with("HTTP/1.1 302 Found"));
        assert!(raw.contains("Location: https://park.worldtree.network/?from=foo.identikey.me"));
    }

    #[test]
    fn redirect_drops_canonical_from() {
        let raw = String::from_utf8(redirect_to_canonical("park.worldtree.network")).unwrap();
        assert!(raw.contains("Location: https://park.worldtree.network/"));
        assert!(!raw.contains("?from="));
    }

    #[test]
    fn origin_from_request_prefers_query_over_referer() {
        let req = b"GET /?from=a.identikey.me HTTP/1.1\r\nHost: park.worldtree.network\r\nReferer: https://b.identikey.me/\r\n\r\n";
        assert_eq!(
            origin_from_request(req).as_deref(),
            Some("a.identikey.me")
        );
    }

    #[test]
    fn origin_from_request_falls_back_to_referer() {
        let req = b"GET / HTTP/1.1\r\nHost: park.worldtree.network\r\nReferer: https://park.identikey.me/x\r\n\r\n";
        assert_eq!(
            origin_from_request(req).as_deref(),
            Some("park.identikey.me")
        );
    }
}
