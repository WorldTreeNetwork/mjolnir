# Spike fixture minter for the claim route (add-open-room-kind). Not product code.
#
#   mix run --no-start openspec/changes/add-open-room-kind/spikes/claim/mint_fixtures.exs <outdir>
#
# Signs with JOSE exactly as Mjolnir.Relay.Mint does (EdDSA, kid header, compact JWS), with a dummy
# Ed25519 key generated per run. Writes <outdir>/verify.json (a moq-auth public key set) and
# <outdir>/fixtures.json. Offline cases use iat = 1735689600 (kio Manual::WALL_START) and exp = iat+600,
# so they verify only under the spike's manual clock. Live cases use the host clock, life 300 s.
[outdir] = System.argv()
File.mkdir_p!(outdir)

kid = "spike-claim"
jwk = JOSE.JWK.generate_key({:okp, :Ed25519}) |> JOSE.JWK.merge(%{"kid" => kid})
{_, pub_map} = JOSE.JWK.to_public_map(jwk)
pub_map = Map.new(pub_map, fn {k, v} -> {to_string(k), v} end) |> Map.put("alg", "EdDSA")
File.write!(Path.join(outdir, "verify.json"), Jason.encode!(%{"keys" => [pub_map]}))

owner = Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
root = "t/#{owner}/standup"
t0 = 1_735_689_600
jti = fn -> :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) end

base = fn iat, exp ->
  %{"root" => root, "publish" => ["alice/**"], "subscribe" => ["**"], "iat" => iat, "exp" => exp, "jti" => jti.()}
end

header = %{"alg" => "EdDSA", "kid" => kid}

sign_map = fn payload, hdr ->
  {_, jws} = JOSE.JWT.sign(jwk, hdr, payload)
  {_, token} = JOSE.JWS.compact(jws)
  token
end

# Raw bytes, for payloads a map cannot spell (a repeated member).
sign_raw = fn raw, hdr ->
  {_, token} = JOSE.JWS.sign(jwk, raw, hdr) |> JOSE.JWS.compact()
  token
end

offline = fn -> base.(t0, t0 + 600) end
b = offline.()
raw_obj = fn pairs -> "{" <> Enum.map_join(pairs, ",", fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end) <> "}" end
pairs = Enum.to_list(b)

tamper = fn token ->
  [h, p, s] = String.split(token, ".")
  claims = p |> Base.url_decode64!(padding: false) |> Jason.decode!() |> Map.put("root", "t/#{owner}/other")
  Enum.join([h, Base.url_encode64(Jason.encode!(claims), padding: false), s], ".")
end

hs = fn payload ->
  secret = JOSE.JWK.from_oct(:crypto.strong_rand_bytes(32)) |> JOSE.JWK.merge(%{"kid" => kid})
  {_, jws} = JOSE.JWT.sign(secret, %{"alg" => "HS256", "kid" => kid}, payload)
  {_, token} = JOSE.JWS.compact(jws)
  token
end

cases =
  [
    {"no_kind (today's mint)", sign_map.(b, header)},
    {"kind=open", sign_map.(Map.put(offline.(), "kind", "open"), header)},
    {"kind=protected", sign_map.(Map.put(offline.(), "kind", "protected"), header)},
    {"kind=OPEN", sign_map.(Map.put(offline.(), "kind", "OPEN"), header)},
    {"kind=\"open \"", sign_map.(Map.put(offline.(), "kind", "open "), header)},
    {"kind=1", sign_map.(Map.put(offline.(), "kind", 1), header)},
    {"kind=null", sign_map.(Map.put(offline.(), "kind", nil), header)},
    {"kind=[\"open\"]", sign_map.(Map.put(offline.(), "kind", ["open"]), header)},
    {"foo=bar (other unknown claim)", sign_map.(Map.put(offline.(), "foo", "bar"), header)},
    {"kind=open + foo=bar", sign_map.(offline.() |> Map.put("kind", "open") |> Map.put("foo", "bar"), header)},
    {"kind repeated (open, protected)", sign_raw.(raw_obj.(pairs ++ [{"kind", "open"}, {"kind", "protected"}]), header)},
    {"root repeated", sign_raw.(raw_obj.(pairs ++ [{"root", "t/#{owner}/other"}]), header)},
    {"payload is an array", sign_raw.(Jason.encode!([root]), header)},
    {"tampered payload (kind=open)", tamper.(sign_map.(Map.put(offline.(), "kind", "open"), header))},
    {"HS256 (kind=open)", hs.(Map.put(offline.(), "kind", "open"))},
    {"(a) sub=\"room-kind:open\"", sign_map.(Map.put(offline.(), "sub", "room-kind:open"), header)},
    {"(a) sub={kind:open}", sign_map.(Map.put(offline.(), "sub", %{"kind" => "open"}), header)},
    {"(a) iss=\"mjolnir-room-kind:open\"", sign_map.(Map.put(offline.(), "iss", "mjolnir-room-kind:open"), header)},
    {"(a) header param kind=open", sign_map.(offline.(), Map.put(header, "kind", "open"))}
  ]
  |> Enum.map(fn {name, token} -> %{"name" => name, "token" => token} end)

now = System.system_time(:second)
live = fn kind_value ->
  payload = base.(now, now + 300)
  payload = if kind_value, do: Map.put(payload, "kind", kind_value), else: payload
  sign_map.(payload, header)
end

File.write!(
  Path.join(outdir, "fixtures.json"),
  Jason.encode!(%{
    "owner" => owner,
    "root" => root,
    "t0" => t0,
    "offline" => cases,
    "live" => %{"open" => live.("open"), "protected" => live.("protected"), "none" => live.(nil)}
  })
)

IO.puts("wrote #{length(cases)} offline cases and 3 live tokens to #{outdir}")
