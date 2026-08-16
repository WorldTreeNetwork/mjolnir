defmodule Mjolnir.API.LoginPage do
  @moduledoc "Waiting-room HTML for an in-flight IdentiKey Connect login."

  @spec render(map()) :: String.t()
  def render(%{id: id, verification_uri: uri, user_code: code}) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Sign in · IdentiKey</title>
      <style>
        :root { --bg:#0b0c0b; --fg:#d7d4c8; --dim:#6d7168; --accent:#c4a35a; --line:#1c1e1b; }
        html,body { margin:0; height:100%; background:var(--bg); color:var(--fg);
          font:15px/1.45 "IBM Plex Mono", ui-monospace, Menlo, monospace; }
        main { max-width: 28rem; margin: 18vh auto 0; padding: 0 1.25rem; }
        .mark { color: var(--accent); letter-spacing: 0.08em; font-size: 12px; }
        h1 { font-size: 1.25rem; font-weight: 500; margin: 0.6rem 0 0.4rem; }
        p { color: var(--dim); margin: 0 0 1.25rem; }
        a.btn { display:inline-block; color:var(--bg); background:var(--accent);
          text-decoration:none; padding:0.55rem 0.9rem; }
        code { color: var(--fg); }
        #status { margin-top: 1.4rem; color: var(--dim); font-size: 13px; }
      </style>
    </head>
    <body>
      <main>
        <div class="mark">IDENTIKEY CONNECT</div>
        <h1>Sign in to continue</h1>
        <p>Same login <code>mj login</code> uses. Complete it in the IdentiKey window; this tab waits.</p>
        <a class="btn" href="#{Plug.HTML.html_escape(uri)}" target="_blank" rel="noopener">Open IdentiKey</a>
        <p id="status">Waiting#{if code, do: " · code <code>#{Plug.HTML.html_escape(to_string(code))}</code>", else: "…"}</p>
      </main>
      <script>
        const ID = #{Jason.encode!(id)};
        async function tick() {
          try {
            const r = await fetch("/auth/wait/" + ID, { credentials: "same-origin" });
            const j = await r.json();
            if (j.ok && j.next) { location.replace(j.next); return; }
            if (j.error) { document.getElementById("status").textContent = "Sign-in failed: " + j.error; return; }
          } catch (e) {}
          setTimeout(tick, 2000);
        }
        tick();
      </script>
    </body>
    </html>
    """
  end
end
