defmodule RosBridge.Inference.DnnTest do
  @moduledoc """
  Tests for the YOLO output decode, which is the part of the DNN
  backend with no model and no accelerator in the loop — and the part
  most likely to be silently wrong. A box decoded from the wrong
  tensor layout still lands on the image and still looks plausible;
  only its position is nonsense.

  The tensors here are hand-built rather than captured from a model, so
  the expected boxes are arithmetic rather than an oracle.

  They are built as `Evision.Mat`s from raw float32, in the
  attribute-major order yolov8 emits (`[1, 4 + classes, anchors]`: an
  anchor's cx is `anchors` elements away from its cy), because the
  decode reduces in OpenCV rather than in Elixir — see `Dnn.decode/6`.
  Building the fixture from a binary keeps the layout explicit: a
  row-major fixture would agree with a row-major bug.
  """
  use ExUnit.Case, async: true

  alias RosBridge.Inference.Dnn

  @attributes 84
  @input_size 640

  defp tensor(anchors, classes \\ 80) do
    columns =
      for anchor <- anchors do
        scores =
          0.0
          |> List.duplicate(classes)
          |> List.replace_at(anchor.class_id, anchor.score)

        [anchor.cx, anchor.cy, anchor.w, anchor.h | scores]
      end

    attributes = 4 + classes

    values =
      for attribute <- 0..(attributes - 1), column <- columns, do: Enum.at(column, attribute)

    mat(values, attributes, length(anchors))
  end

  # `{1, attributes, anchors}`, batch included: the shape `Net.forward/1` returns.
  defp mat(values, attributes, anchors) do
    binary = for value <- values, into: <<>>, do: <<value::float-32-little>>

    binary
    |> Evision.Mat.from_binary({:f, 32}, attributes, anchors, 1)
    |> Evision.Mat.reshape([1, attributes, anchors])
  end

  defp anchor(cx, cy, w, h, class_id, score),
    do: %{cx: cx, cy: cy, w: w, h: h, class_id: class_id, score: score}

  describe "decode/6" do
    test "a centred box maps back to the source image's pixels" do
      # 640x640 model input, 1280x720 source: sx = 2.0, sy = 1.125.
      output = tensor([anchor(320.0, 320.0, 64.0, 32.0, 0, 0.9)])
      [detection] = Dnn.decode(output, 1280, 720, @input_size, 0.4, 0.45)

      assert detection.class_id == 0
      assert_in_delta detection.score, 0.9, 1.0e-6
      # x: (320 - 32) * 2.0 = 576 .. (320 + 32) * 2.0 = 704
      assert_in_delta detection.x0, 576.0, 1.0e-6
      assert_in_delta detection.x1, 704.0, 1.0e-6
      # y: (320 - 16) * 1.125 = 342 .. (320 + 16) * 1.125 = 378
      assert_in_delta detection.y0, 342.0, 1.0e-6
      assert_in_delta detection.y1, 378.0, 1.0e-6
    end

    test "the attribute-major layout is read per anchor, not per row" do
      # Two anchors with deliberately different geometry. Reading the
      # tensor row-major would blend them — the first box would take
      # its cy from the second anchor's cx.
      output =
        tensor([
          anchor(100.0, 100.0, 20.0, 20.0, 1, 0.8),
          anchor(500.0, 400.0, 40.0, 60.0, 2, 0.7)
        ])

      detections = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45)
      assert length(detections) == 2

      by_class = Map.new(detections, &{&1.class_id, &1})
      assert_in_delta by_class[1].x0, 90.0, 1.0e-6
      assert_in_delta by_class[1].y0, 90.0, 1.0e-6
      assert_in_delta by_class[2].x0, 480.0, 1.0e-6
      assert_in_delta by_class[2].y0, 370.0, 1.0e-6
    end

    test "anchors below the score threshold are dropped" do
      output =
        tensor([
          anchor(100.0, 100.0, 20.0, 20.0, 0, 0.95),
          anchor(300.0, 300.0, 20.0, 20.0, 1, 0.20)
        ])

      detections = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45)
      assert length(detections) == 1
      assert hd(detections).class_id == 0
    end

    test "the highest-scoring class wins for an anchor" do
      # Two classes scoring on one anchor, which `tensor/2` cannot
      # express: it sets exactly one. A single anchor means the column
      # *is* the flat tensor.
      column =
        [320.0, 320.0, 10.0, 10.0 | List.duplicate(0.0, 80)]
        |> List.replace_at(4 + 5, 0.51)
        |> List.replace_at(4 + 37, 0.93)

      [detection] = Dnn.decode(mat(column, @attributes, 1), 640, 640, @input_size, 0.4, 0.45)
      assert detection.class_id == 37
      assert_in_delta detection.score, 0.93, 1.0e-6
    end

    test "overlapping boxes of one class collapse to the best" do
      output =
        tensor([
          anchor(300.0, 300.0, 100.0, 100.0, 0, 0.95),
          # Almost the same box, lower score: NMS should drop it.
          anchor(305.0, 302.0, 100.0, 100.0, 0, 0.60)
        ])

      detections = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45)
      assert length(detections) == 1
      assert_in_delta hd(detections).score, 0.95, 1.0e-6
    end

    test "overlapping boxes of different classes both survive" do
      # NMS is per class: a person standing in front of a car should not
      # suppress the car.
      output =
        tensor([
          anchor(300.0, 300.0, 100.0, 100.0, 0, 0.95),
          anchor(305.0, 302.0, 100.0, 100.0, 2, 0.60)
        ])

      detections = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45)
      assert length(detections) == 2
    end

    test "distant boxes of one class both survive" do
      output =
        tensor([
          anchor(100.0, 100.0, 40.0, 40.0, 0, 0.95),
          anchor(500.0, 500.0, 40.0, 40.0, 0, 0.90)
        ])

      detections = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45)
      assert length(detections) == 2
    end

    test "results come back highest score first" do
      output =
        tensor([
          anchor(100.0, 100.0, 20.0, 20.0, 0, 0.55),
          anchor(400.0, 400.0, 20.0, 20.0, 1, 0.91),
          anchor(200.0, 500.0, 20.0, 20.0, 2, 0.72)
        ])

      scores = Dnn.decode(output, 640, 640, @input_size, 0.4, 0.45) |> Enum.map(& &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "an output of the wrong shape yields nothing rather than nonsense" do
      # Four attributes is a box with no class scores at all, so there
      # is nothing to take a maximum over.
      assert Dnn.decode(mat([1.0, 2.0, 3.0, 4.0], 4, 1), 640, 640, @input_size, 0.4, 0.45) == []

      # And what Evision hands back when `forward/1` fails: a return
      # value, not a raise, so it has to be matched rather than
      # rescued.
      assert Dnn.decode({:error, "forward failed"}, 640, 640, @input_size, 0.4, 0.45) == []
    end

    test "a model with a class count other than 80 decodes" do
      # `decode/6` takes a Mat so the class count comes from its shape.
      [detection] =
        Dnn.decode(
          tensor([anchor(320.0, 320.0, 64.0, 64.0, 0, 0.9)], 1),
          640,
          640,
          @input_size,
          0.4,
          0.45
        )

      assert detection.class_id == 0
      assert_in_delta detection.score, 0.9, 0.001
      assert_in_delta detection.x0, 288.0, 0.01
      assert_in_delta detection.x1, 352.0, 0.01
    end

    test "the per-anchor maximum is taken across every class, at scale" do
      # 8400 anchors, one confident: the shape of a real frame. Built
      # outside the timer, because `tensor/2` is quadratic.
      full_frame_output =
        for anchor_index <- 0..8399 do
          if anchor_index == 5000,
            do: anchor(320.0, 320.0, 64.0, 64.0, 17, 0.95),
            else: anchor(1.0 * anchor_index, 1.0, 2.0, 2.0, rem(anchor_index, 80), 0.01)
        end
        |> tensor()

      {microseconds, detections} =
        :timer.tc(fn -> Dnn.decode(full_frame_output, 640, 640, @input_size, 0.4, 0.45) end)

      assert [%{class_id: 17}] = detections
      assert_in_delta hd(detections).score, 0.95, 0.001

      # Loose enough for a busy CI runner, tight enough to fail on a
      # pure-Elixir reduction.
      assert microseconds < 100_000,
             "decode took #{div(microseconds, 1000)} ms for 8400 anchors"
    end
  end
end
