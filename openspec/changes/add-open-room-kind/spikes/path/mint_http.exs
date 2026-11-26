# HTTP spelling of today's mint through Bandit. Not the product router.
# Product Mjolnir.API.Router does not compile in this working tree.
owner = Mjolnir.Deploy.Owner.encode(<<9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9>>)
dir = Path.join(System.tmp_dir!(), "mint-spike-#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)
File.chmod!(dir, 0o700)
key = JOSE.JWK.generate_key({:okp, :Ed25519})
{_, map} = JOSE.JWK.to_map(JOSE.JWK.merge(key, %{"kid" => "spikeKid"}))
map = map |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("alg", "EdDSA")
key_path = Path.join(dir, "current.jwk")
File.write!(key_path, Jason.encode!(map))
File.chmod!(key_path, 0o600)
env = Path.join(dir, "relay.env")
File.write!(env, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=relay.test\nMJOLNIR_RELAY_TOKEN_MAX_TTL=3600\n")
opts = [key_path: key_path, env_path: env, uid: File.stat!(key_path).uid]
caller = %{kind: :user, sub: owner, scopes: "relay:join"}

defmodule Spike.Http do
  @behaviour Plug
  def init(o), do: o

  def call(conn, o) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = if body == "", do: %{}, else: Jason.decode!(body)
    room =
      case conn.path_info do
        ["rooms", room | _] -> room
        _ -> ""
      end

    payload =
      case Mjolnir.Relay.Mint.issue(o.caller, room, "alice", params, o.opts) do
        {:ok, token} ->
          claims =
            token.token
            |> String.split(".")
            |> Enum.at(1)
            |> Base.url_decode64!(padding: false)
            |> Jason.decode!()

          %{
            status: 200,
            request_path: conn.request_path,
            room_param: room,
            root: token.root,
            response_kind: Map.get(token, :kind),
            response_keys: token |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
            claim_names: claims |> Map.keys() |> Enum.sort(),
            publish: token.publish
          }

        {:error, status, reason} ->
          %{status: status, error: reason, request_path: conn.request_path, room_param: room}
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(payload.status, Jason.encode!(payload))
  end
end

Application.ensure_all_started(:inets)
Application.ensure_all_started(:bandit)
port = 5891
{:ok, _pid} = Bandit.start_link(plug: {Spike.Http, %{caller: caller, opts: opts}}, ip: {127, 0, 0, 1}, port: port)
Process.sleep(150)

paths = [
  {"/rooms/standup/participants/alice/token", "{}"},
  {"/rooms/standup/participants/alice/token", ~s({"kind":"open"})},
  {"/rooms/standup/participants/alice/token", ~s({"kind":"protected"})},
  {"/rooms/~open/participants/alice/token", "{}"},
  {"/rooms/%7Eopen/participants/alice/token", "{}"},
  {"/rooms/%257Eopen/participants/alice/token", "{}"}
]

Enum.each(paths, fn {path, json} ->
  url = String.to_charlist("http://127.0.0.1:#{port}#{path}")
  {:ok, {{_, status, _}, _, resp}} =
    :httpc.request(:post, {url, [], ~c"application/json", String.to_charlist(json)}, [], [])
  IO.puts("sent=#{path} http=#{status} body=#{resp}")
end)
