defmodule Mix.Tasks.Mjolnir.Pg.Tenant do
  @shortdoc "Declare a host-sidecar tenant database (ADR 0005)"

  @moduledoc """
  Provision or rotate a tenant database on the OTP Postgres sidecar.

  Not run from sidecar bootstrap. First tenant: `hypersigil` / slug
  `hypersigil-api`.

      mix mjolnir.pg.tenant ensure hypersigil --slug hypersigil-api
      mix mjolnir.pg.tenant ensure --declared
      mix mjolnir.pg.tenant ensure hypersigil --rotate
  """

  use Mix.Task

  @impl Mix.Task
  def run(["ensure", "--declared"]) do
    Mix.Task.run("app.start")

    case Mjolnir.Postgres.Tenants.ensure_declared() do
      :ok -> Mix.shell().info("declared tenants ready")
      {:error, reason} -> Mix.raise("ensure_declared failed: #{inspect(reason)}")
    end
  end

  def run(["ensure", name | rest]) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(rest, strict: [slug: :string, rotate: :boolean])
    slug = Keyword.get(opts, :slug, name)
    rotate = Keyword.get(opts, :rotate, false)

    case Mjolnir.Postgres.Tenants.ensure(name, slug: slug, rotate: rotate) do
      {:ok, tenant} ->
        Mix.shell().info("tenant #{tenant.name} ready (slug=#{tenant.slug})")

      {:error, reason} ->
        Mix.raise("ensure failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix mjolnir.pg.tenant ensure <name> [--slug s] [--rotate]")
end
