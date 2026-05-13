defmodule Mjolnir.Repo.Migrations.CreateSitesManifestIndex do
  use Ecto.Migration

  def change do
    create table(:manifest_index, prefix: "sites", primary_key: false) do
      add(:snapshot_hash, :text, null: false, primary_key: true)
      add(:identikey_fp, :text, null: false)
      add(:site_name, :text, null: false)
      add(:mode, :text, null: false)
      add(:entry_count, :integer, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:indexed_at, :utc_datetime_usec, null: false)
    end

    create(index(:manifest_index, [:identikey_fp, :site_name], prefix: "sites"))
  end
end
