defmodule VisionCore.Stereo.MatcherTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{Matcher, NativeSegment, Pair, Pipeline, Stage}

  @moduletag :stereo_match
  @moduletag :capture_log
  @moduletag timeout: 600_000

  setup do
    start_supervised!(Matcher)
    :ok
  end

  @calibration Path.expand("../../support/calibration", __DIR__)

  defp sgm_opts(opts) do
    Keyword.merge(
      [disparities: 64, paths: 3, p1: 8, p2: 64, uniqueness: 1.0526315789473684],
      opts
    )
  end

  # The disparity of a segment of one native Disparity stage.
  defp match(left, right, opts, state_change \\ & &1) do
    {segment, pair} = disparity_segment(left, right, opts, state_change)

    case NativeSegment.run(pair, segment) do
      {:ok, pair, _segment} -> {:ok, pair.disparity}
      {:error, reason, _segment} -> {:error, reason}
    end
  end

  defp disparity_segment(left, right, opts, state_change \\ & &1) do
    {height, width} = Nx.shape(left)

    context =
      Pipeline.context(
        left_calibration_path: Path.join(@calibration, "stereo_left.yaml"),
        right_calibration_path: Path.join(@calibration, "stereo_right.yaml"),
        width: width,
        height: height
      )

    stage_opts =
      opts |> Keyword.put(:num_disparities, opts[:disparities]) |> Keyword.delete(:disparities)

    {:ok, state} = Stage.Disparity.init(stage_opts, context)
    member = %{module: Stage.Disparity, name: :disparity, state: state_change.(state)}
    {:ok, segment} = NativeSegment.build([member], context)
    pair = %Pair{left_frame: nil, right_frame: nil, left: left, right: right, geometry: context}
    {segment, pair}
  end

  defp await_response(request_id, segment) do
    receive do
      message ->
        case NativeSegment.response(message, request_id, segment) do
          :no_reply -> await_response(request_id, segment)
          {:ok, outputs, _segment, _done_ns} -> {:ok, outputs.disparity}
          {:error, _reason} = error -> error
        end
    after
      60_000 -> flunk("no reply")
    end
  end

  defp send_pairs(segment, pairs) do
    for pair <- pairs do
      {:ok, request_id} = NativeSegment.send_request(pair, segment)
      request_id
    end
  end

  # Noise seen with a disparity of `shift`, with a flat patch, where costs
  # tie and matches are refused.
  defp textured_pair(seed, {height, width}, shift) do
    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(seed), 0, 256, shape: {height, width + shift}, type: :s32)

    texture =
      texture
      |> Nx.put_slice([div(height, 2), div(width, 3)], Nx.broadcast(90, {6, 10}))
      |> Nx.as_type(:u8)

    {Nx.slice_along_axis(texture, shift, width, axis: 1),
     Nx.slice_along_axis(texture, 0, width, axis: 1)}
  end

  # A smooth texture behind a slanted plane, for subpixel disparities.
  defp slanted_pair({height, width}) do
    x = Nx.iota({height, width}, axis: 1, type: :f32)
    y = Nx.iota({height, width}, axis: 0, type: :f32)
    disparity = x |> Nx.multiply(20 / width) |> Nx.add(Nx.multiply(y, 5 / height)) |> Nx.add(4)
    {to_u8(texture(x, y)), to_u8(texture(Nx.add(x, disparity), y))}
  end

  defp texture(u, y) do
    fine = u |> Nx.multiply(0.7) |> Nx.sin() |> Nx.multiply(50)
    coarse = u |> Nx.multiply(0.13) |> Nx.add(Nx.multiply(y, 0.9)) |> Nx.sin() |> Nx.multiply(60)
    fine |> Nx.add(coarse) |> Nx.add(128)
  end

  defp to_u8(image), do: image |> Nx.round() |> Nx.clip(0, 255) |> Nx.as_type(:u8)

  defp nx_reference(left, right, opts) do
    Nx.Defn.jit_apply(&NxStereo.sgm(&1, &2, opts), [left, right], compiler: EXLA)
  end

  defp assert_matches_nx(left, right, opts) do
    {:ok, native} = match(left, right, opts)
    reference = nx_reference(left, right, opts)

    assert Nx.shape(native) == Nx.shape(reference)
    assert Nx.type(native) == {:f, 32}

    native = Nx.to_flat_list(native)
    reference = Nx.to_flat_list(reference)
    pairs = Enum.zip(native, reference)

    refute Enum.any?(pairs, fn {got, want} -> got < 0 != want < 0 end),
           "unmatched pixels differ for #{inspect(opts)}"

    refute Enum.any?(pairs, fn {got, want} -> floor(got) != floor(want) end),
           "integer disparities differ for #{inspect(opts)}"

    refute Enum.any?(pairs, fn {got, want} -> got != want end),
           "subpixel values differ for #{inspect(opts)}"

    assert Enum.any?(reference, &(&1 >= 0))
  end

  for {size, disparities, paths} <- [
        {{48, 64}, 64, 3},
        {{48, 64}, 64, 8},
        {{48, 64}, 128, 3},
        {{48, 64}, 128, 8},
        {{120, 160}, 64, 3},
        {{120, 160}, 64, 8},
        {{120, 160}, 128, 8}
      ] do
    test "matches NxStereo.sgm/3 on #{inspect(size)}, #{disparities} disparities, #{paths} paths" do
      opts = sgm_opts(disparities: unquote(disparities), paths: unquote(paths))
      {left, right} = textured_pair(1, unquote(Macro.escape(size)), 12)
      assert_matches_nx(left, right, opts)

      {left, right} = slanted_pair(unquote(Macro.escape(size)))
      assert_matches_nx(left, right, opts)
    end
  end

  test "matches NxStereo.sgm/3 with other penalties and uniqueness" do
    {left, right} = slanted_pair({120, 160})

    for {p1, p2, uniqueness} <- [{4, 40, 1.2}, {20, 79, 1.0}, {0, 1, 2.5}], paths <- [3, 8] do
      assert_matches_nx(
        left,
        right,
        sgm_opts(p1: p1, p2: p2, uniqueness: uniqueness, paths: paths)
      )
    end
  end

  test "refuses settings NxStereo.sgm/3 refuses, and serves the next request" do
    {left, right} = textured_pair(2, {48, 64}, 8)

    assert {:error, :bad_request} =
             match(left, right, sgm_opts([]), &Keyword.put(&1, :p2, 80))

    assert {:ok, %Nx.Tensor{shape: {48, 64}}} = match(left, right, sgm_opts([]))
  end

  test "forgets a segment once the process that ran it exits" do
    {left, right} = textured_pair(6, {48, 64}, 8)
    task = Task.async(fn -> match(left, right, sgm_opts([])) end)
    assert {:ok, _disparity} = Task.await(task, 60_000)

    forgotten? = fn -> map_size(:sys.get_state(Matcher).configured) == 0 end
    assert Enum.any?(1..100, fn _try -> forgotten?.() or (Process.sleep(10) && false) end)
  end

  test "without the binary, says where it looked" do
    path = Application.get_env(:vision_core, :stereo_match_path)
    on_exit(fn -> Application.put_env(:vision_core, :stereo_match_path, path) end)
    Application.put_env(:vision_core, :stereo_match_path, "/nonexistent/stereo_match")
    stop_supervised!(Matcher)
    start_supervised!(Matcher)

    {left, right} = textured_pair(3, {48, 64}, 8)

    assert {:error, {:no_matcher, "/nonexistent/stereo_match"}} =
             match(left, right, sgm_opts([]))
  end

  test "a request without a reply in time closes the Port, so its reply cannot answer the next" do
    stop_supervised!(Matcher)
    matcher = start_supervised!({Matcher, timeout_ms: 1})
    {left, right} = textured_pair(4, {360, 480}, 8)
    {segment, pair} = disparity_segment(left, right, sgm_opts(paths: 8, disparities: 128))

    assert [{:error, :timeout}, {:error, :timeout}] =
             segment |> send_pairs([pair, pair]) |> Enum.map(&await_response(&1, segment))

    assert {:error, :timeout} = match(left, right, sgm_opts(paths: 8, disparities: 128))

    :sys.replace_state(matcher, &%{&1 | timeout_ms: 60_000})
    {small_left, small_right} = textured_pair(5, {48, 64}, 8)

    assert {:ok, %Nx.Tensor{shape: {48, 64}}} =
             match(small_left, small_right, sgm_opts([]))
  end

  test "answers requests sent without waiting for the previous reply, in the order sent" do
    pairs = for seed <- 10..12, do: textured_pair(seed, {120, 160}, 4 * seed - 32)

    [{left, right} | _] = pairs
    {segment, _pair} = disparity_segment(left, right, sgm_opts([]))
    expected = for {left, right} <- pairs, do: match(left, right, sgm_opts([]))

    sent =
      send_pairs(
        segment,
        Enum.map(pairs, fn {left, right} ->
          %Pair{left_frame: nil, right_frame: nil, left: left, right: right}
        end)
      )

    assert Enum.map(sent, &await_response(&1, segment)) == expected
  end

  test "a Port that exits fails every request waiting for it" do
    {left, right} = textured_pair(7, {360, 480}, 8)
    opts = sgm_opts(paths: 8, disparities: 128)
    {segment, pair} = disparity_segment(left, right, opts)
    assert {:ok, _disparity} = match(left, right, opts)

    sent = send_pairs(segment, [pair, pair])
    {:os_pid, os_pid} = Port.info(:sys.get_state(Matcher).port, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(os_pid)])

    assert [{:error, {:exited, _status}}, {:error, {:exited, _}}] =
             Enum.map(sent, &await_response(&1, segment))

    assert {:ok, %Nx.Tensor{}} = match(left, right, opts)
  end
end
