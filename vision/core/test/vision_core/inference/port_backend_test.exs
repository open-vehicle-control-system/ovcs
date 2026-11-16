defmodule VisionCore.Inference.PortBackendTest do
  use ExUnit.Case, async: true

  alias VisionCore.Inference.PortBackend
  alias VisionCore.PortProcess

  @moduletag :tmp_dir
  @moduletag :capture_log

  # Runs the script it is given; a request is its sequence, and any reply answers request 1.
  defmodule Probe do
    @behaviour PortBackend

    @impl PortBackend
    def init(opts), do: %{executable: Keyword.fetch!(opts, :executable)}

    @impl PortBackend
    def wording(_settings),
      do: %{label: "Probe", program: "probe", loaded: "ready", input: "frame", output: "results"}

    @impl PortBackend
    def inference_group(_settings),
      do:
        VisionCore.Parameters.step(:port_backend_probe, "inference", "Inference", 102, %{
          summary: "Probe",
          parameters: []
        })

    @impl PortBackend
    def open(settings, nil),
      do:
        {:ok,
         Port.open({:spawn_executable, settings.executable}, [
           :binary,
           :exit_status,
           {:packet, 4}
         ])}

    @impl PortBackend
    def final?(_reason), do: false

    @impl PortBackend
    def request(sequence, _input), do: <<sequence::32>>

    @impl PortBackend
    def parse(_packet), do: {:ok, 1, :done, nil}

    @impl PortBackend
    def reply_tag, do: :probe_result
  end

  # Two lanes, `:near` and `:far`: a request is its lane's byte and its sequence, and the
  # program's echo of it answers that request on that lane, with the lane as the result.
  defmodule LanedProbe do
    @behaviour PortBackend

    @lanes %{near: 10, far: 11}

    @impl PortBackend
    def init(opts), do: %{executable: Keyword.fetch!(opts, :executable)}

    @impl PortBackend
    def wording(_settings),
      do: %{label: "Laned", program: "laned", loaded: "ready", input: "frame", output: "results"}

    @impl PortBackend
    def inference_group(_settings),
      do: [
        VisionCore.Parameters.step(:laned_near, "inference", "Inference", 102, %{
          summary: "Near",
          parameters: []
        }),
        VisionCore.Parameters.step(:laned_far, "inference", "Inference", 102, %{
          summary: "Far",
          parameters: []
        })
      ]

    @impl PortBackend
    def open(settings, nil),
      do:
        {:ok,
         Port.open({:spawn_executable, settings.executable}, [
           :binary,
           :exit_status,
           {:packet, 4}
         ])}

    @impl PortBackend
    def final?(_reason), do: false

    @impl PortBackend
    def lanes(_settings), do: [:near, :far]

    @impl PortBackend
    def lane_request(_settings, lane, sequence, _input), do: <<@lanes[lane], sequence::32>>

    @impl PortBackend
    def lane_parse(_settings, <<byte, sequence::32>>) do
      {lane, _byte} = Enum.find(@lanes, fn {_lane, value} -> value == byte end)
      {:ok, lane, sequence, lane, 7}
    end

    @impl PortBackend
    def lane_reply_tag(_settings, lane), do: :"#{lane}_result"
  end

  defp start_laned(tmp_dir, script) do
    executable = Path.join(tmp_dir, "laned.sh")
    File.write!(executable, "#!/bin/sh\n" <> script)
    File.chmod!(executable, 0o755)

    start_supervised!(%{
      id: LanedProbe,
      start:
        {PortBackend, :start_link,
         [LanedProbe, [executable: executable, name: nil, reopen_delays_ms: [60_000]]]}
    })
  end

  test "each lane carries its own request in flight and its own reply", %{tmp_dir: tmp_dir} do
    server = start_laned(tmp_dir, "exec cat\n")

    assert PortBackend.submit(server, :near, 1, :frame) == :ok
    assert PortBackend.submit(server, :far, 2, :frame) == :ok

    assert_receive {:near_result, 1, :near}
    assert_receive {:far_result, 2, :far}
    assert PortBackend.inference_times(server, :near) == %{sum_us: 7, count: 1}
    assert PortBackend.inference_times(server, :far) == %{sum_us: 7, count: 1}
  end

  test "a lane busy with a request leaves the other lane free", %{tmp_dir: tmp_dir} do
    server = start_laned(tmp_dir, "exec sleep 60\n")

    assert PortBackend.submit(server, :near, 1, :frame) == :ok
    assert PortBackend.submit(server, :near, 2, :frame) == {:error, :busy}
    assert PortBackend.submit(server, :far, 3, :frame) == :ok
  end

  test "a Port that exits answers every lane's request in flight with no result", %{
    tmp_dir: tmp_dir
  } do
    server = start_laned(tmp_dir, "head -c 4 > /dev/null; exit 1\n")

    assert PortBackend.submit(server, :near, 1, :frame) == :ok
    assert PortBackend.submit(server, :far, 2, :frame) == :ok

    assert_receive {:near_result, 1, nil}, 2_000
    assert_receive {:far_result, 2, nil}, 2_000
  end

  defp start_probe(tmp_dir, script, opts) do
    executable = Path.join(tmp_dir, "probe.sh")
    File.write!(executable, "#!/bin/sh\n" <> script)
    File.chmod!(executable, 0o755)

    server =
      start_supervised!(%{
        id: Probe,
        start:
          {PortBackend, :start_link,
           [Probe, [executable: executable, name: nil, reopen_delays_ms: [60_000]] ++ opts]}
      })

    %{port: port} = :sys.get_state(server)
    {server, port, PortProcess.os_pid(port)}
  end

  defp eventually(check, attempts \\ 300) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "a program that neither answers nor reads its stdin is killed once its request times out",
       %{tmp_dir: tmp_dir} do
    {server, _port, os_pid} =
      start_probe(tmp_dir, "exec sleep 600 < /dev/null\n", infer_timeout_ms: 50)

    assert PortProcess.alive?(os_pid)
    assert PortBackend.submit(server, 1, :frame) == :ok
    assert_receive {:probe_result, 1, nil}, 2_000

    eventually(fn -> not PortProcess.alive?(os_pid) end)
    assert PortBackend.state(server) == :failed
  end

  test "a Port that dies under a program still running takes the program with it", %{
    tmp_dir: tmp_dir
  } do
    {server, port, os_pid} = start_probe(tmp_dir, "exec sleep 600\n", [])

    send(server, {:EXIT, port, :epipe})

    eventually(fn -> not PortProcess.alive?(os_pid) end)
    assert PortBackend.state(server) == :failed
  end

  test "a request handed to a Port whose program has just exited is refused, the backend as it was",
       %{tmp_dir: tmp_dir} do
    {server, port, os_pid} = start_probe(tmp_dir, "exec sleep 600\n", [])

    :sys.suspend(server)
    submit = Task.async(fn -> PortBackend.submit(server, 1, :frame) end)
    eventually(fn -> Process.info(server, :message_queue_len) == {:message_queue_len, 1} end)
    {_output, 0} = System.cmd("kill", [Integer.to_string(os_pid)])
    eventually(fn -> Port.info(port) == nil end)
    :sys.resume(server)

    assert Task.await(submit) == {:error, :unavailable}
    assert PortBackend.state(server) == :failed
    assert Process.alive?(server)
    refute_received {:probe_result, _sequence, _result}
  end
end
