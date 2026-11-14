defmodule InfotainmentCore.Models.TimeSettingTest do
  use ExUnit.Case, async: true

  alias InfotainmentCore.Models.TimeSetting

  test "takes the timezone, time format and date format" do
    settings = %{timezone: "Europe/Brussels", time_format: "12h", date_format: "YYYY-MM-DD"}
    changeset = TimeSetting.changeset(%TimeSetting{}, settings)

    assert changeset.valid?
    assert changeset.changes == settings
  end

  test "changes only the settings given" do
    changeset = TimeSetting.changeset(%TimeSetting{}, %{time_format: "12h"})

    assert changeset.changes == %{time_format: "12h"}
    assert Ecto.Changeset.apply_changes(changeset).timezone == "UTC"
  end

  test "keeps an empty setting as given" do
    changeset = TimeSetting.changeset(%TimeSetting{timezone: "Europe/Brussels"}, %{timezone: ""})

    assert changeset.changes == %{timezone: ""}
  end
end
