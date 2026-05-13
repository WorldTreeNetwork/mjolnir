defmodule Mjolnir.Repo.Migrations.CreateSitesHeadIndex do
  use Ecto.Migration

  def change do
    create table(:head_index, prefix: "sites", primary_key: false) do
      add(:identikey_fp, :text, null: false, primary_key: true)
      add(:site_name, :text, null: false, primary_key: true)
      add(:snapshot_hash, :text, null: false)
      add(:sequence, :bigint, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:head_index, [:snapshot_hash], prefix: "sites"))
  end
end
