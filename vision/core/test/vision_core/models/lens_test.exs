defmodule VisionCore.Models.LensTest do
  use ExUnit.Case, async: true

  alias VisionCore.Models.Lens
  alias VisionCore.Ros2.CameraCalibration

  @calibration %CameraCalibration{
    width: 728,
    height: 544,
    distortion_model: "plumb_bob",
    distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
    camera_matrix: [886.3, 0.0, 364.6, 0.0, 887.3, 298.6, 0.0, 0.0, 1.0],
    rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    projection_matrix: [864.8, 0.0, 396.4, -171.2, 0.0, 864.8, 292.7, 0.0, 0.0, 0.0, 1.0, 0.0]
  }

  describe "changeset/2" do
    test "takes a camera's calibration, without its error" do
      {:ok, attributes} = Lens.attributes(@calibration)
      changeset = Lens.changeset(%Lens{}, attributes)

      assert changeset.valid?
      lens = Ecto.Changeset.apply_changes(changeset)

      assert {lens.fx, lens.k1, Enum.at(lens.projection, 3), lens.rms_px} ==
               {886.3, -0.478, -171.2, nil}

      assert Lens.to_calibration(lens) == @calibration
    end

    test "refuses a lens missing an element" do
      {:ok, attributes} = Lens.attributes(@calibration)

      changeset = Lens.changeset(%Lens{}, %{attributes | fx: nil, k3: nil})

      refute changeset.valid?
      assert {_message, [validation: :required]} = changeset.errors[:fx]
      assert {_message, [validation: :required]} = changeset.errors[:k3]
    end

    test "refuses a rectification or a projection matrix of another size" do
      {:ok, attributes} = Lens.attributes(@calibration)

      changeset =
        Lens.changeset(%Lens{}, %{attributes | rectification: [1.0], projection: [1.0, 0.0]})

      refute changeset.valid?

      assert {_message, [count: 9, validation: :length, kind: :is, type: :list]} =
               changeset.errors[:rectification]

      assert {_message, [count: 12, validation: :length, kind: :is, type: :list]} =
               changeset.errors[:projection]
    end
  end

  test "has no fields for another distortion model" do
    rational = %{@calibration | distortion_model: "rational_polynomial"}

    assert {:error, reason} = Lens.attributes(rational)
    assert reason =~ "plumb_bob"
  end

  test "holds a calibration element for element, to the rounding of its file" do
    {:ok, attributes} = Lens.attributes(@calibration)
    lens = %Lens{} |> Lens.changeset(attributes) |> Ecto.Changeset.apply_changes()

    assert Lens.holds?(lens, @calibration)

    assert Lens.holds?(lens, %{
             @calibration
             | camera_matrix: [886.3 + 1.0e-10 | tl(@calibration.camera_matrix)]
           })

    refute Lens.holds?(lens, %{
             @calibration
             | camera_matrix: [886.4 | tl(@calibration.camera_matrix)]
           })

    refute Lens.holds?(lens, %{@calibration | distortion_model: "rational_polynomial"})
  end
end
