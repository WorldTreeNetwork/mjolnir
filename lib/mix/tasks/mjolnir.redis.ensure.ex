defmodule Mix.Tasks.Mjolnir.Redis.Ensure do
  @shortdoc "Stamp REDIS_URL into deploy secrets (ADR 0007)"

  @moduledoc """
  Merge `REDIS_URL` for the host Redis sidecar. Does not start Redis
  (systemd) and does not start the Mjolnir OTP app.

      mix mjolnir.redis.ensure --slug hypersigil-api
      mix mjolnir.redis.ensure --slug hypersigil-api --rotate
  """

  use Mix.Task

  @impl Mix.Task
  def run(["--slug", slug | rest]) do
    ensure(slug, rest)
  end

  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [slug: :string, rotate: :boolean])
    slug = Keyword.get(opts, :slug)

    if is_nil(slug) or slug == "" do
      Mix.raise("usage: mix mjolnir.redis.ensure --slug <slug> [--rotate]")
    else
      ensure(slug, argv)
    end
  end

  defp ensure(slug, argv) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(argv, strict: [slug: :string, rotate: :boolean])
    rotate = Keyword.get(opts, :rotate, false)

    case Mjolnir.Redis.ensure(slug, rotate: rotate) do
      {:ok, result} ->
        Mix.shell().info("REDIS_URL ready (slug=#{result.slug})")

      {:error, reason} ->
        Mix.raise("ensure failed: #{inspect(reason)}")
    end
  end
end
