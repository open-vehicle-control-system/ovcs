defmodule VisionCore.Camera.Camss do
  @moduledoc """
  Routes a sensor through Qualcomm's CAMSS media graph, as on the Arduino
  VENTUNO Q, so `v4l2_capture` reads its raw frames: CSI PHY `N` → CSID
  `N` → VFE `N`'s first RDI, whose video node delivers the frames.

  A sensor is found by the CSI PHY it is wired to, not by its name: the
  name carries its I2C bus (`"imx296 5-001a"`), and the buses can be
  numbered differently from one boot to the next.
  """

  @type link :: %{
          source: String.t(),
          source_pad: non_neg_integer(),
          sink: String.t(),
          sink_pad: non_neg_integer(),
          enabled: boolean(),
          immutable: boolean()
        }

  @type entity :: %{name: String.t(), devnode: String.t() | nil}

  @type graph :: %{entities: %{String.t() => entity()}, links: [link()]}

  @type route :: %{sensor: String.t(), video: String.t(), subdev: String.t()}

  @doc "The entities and links of `media-ctl -p`'s output."
  @spec parse(String.t()) :: graph()
  def parse(text) do
    {entities, links, _entity, _pad} =
      text
      |> String.split("\n")
      |> Enum.reduce({%{}, [], nil, nil}, &parse_line/2)

    %{entities: entities, links: Enum.reverse(links)}
  end

  defp parse_line(line, {entities, links, entity, pad} = acc) do
    cond do
      match = Regex.run(~r/^- entity \d+: (.+?) \(\d+ pads?/, line) ->
        name = Enum.at(match, 1)
        {Map.put(entities, name, %{name: name, devnode: nil}), links, name, nil}

      entity == nil ->
        acc

      match = Regex.run(~r/device node name (\S+)/, line) ->
        {put_in(entities[entity].devnode, Enum.at(match, 1)), links, entity, pad}

      match = Regex.run(~r/^\s*pad(\d+):/, line) ->
        {entities, links, entity, String.to_integer(Enum.at(match, 1))}

      match = Regex.run(~r/-> "([^"]+)":(\d+) \[([A-Z,]*)\]/, line) ->
        [_, sink, sink_pad, flags] = match

        link = %{
          source: entity,
          source_pad: pad,
          sink: sink,
          sink_pad: String.to_integer(sink_pad),
          enabled: flags =~ "ENABLED",
          immutable: flags =~ "IMMUTABLE"
        }

        {entities, [link | links], entity, pad}

      true ->
        acc
    end
  end

  @doc """
  Links the sensor wired to CSI PHY `csiphy` through CSID and VFE
  `csiphy`, disabling the links that fed them from elsewhere, and sets
  the format on the sensor and on each pad of the path. Returns the
  sensor's entity name, the VFE's video node and the sensor's subdevice
  node.

  Options:

    * `:width`, `:height` - the sensor's mode, 1456×1088 by default (the
      IMX296's).
    * `:code` - the media bus code, `"SRGGB10_1X10"` by default.
    * `:media` - the media device, `"/dev/media0"` by default.
    * `:await` - how many milliseconds to keep reading a media graph that
      does not answer yet or has no sensor on the PHY yet, as while CAMSS
      and the sensors probe at boot; 0 by default.
    * `:runner` - runs a command as `(command, args) -> {output, status}`;
      `System.cmd/3`, its error output included, by default.
  """
  @spec route(0..2, keyword()) :: {:ok, route()} | {:error, String.t()}
  def route(csiphy, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        width: 1456,
        height: 1088,
        code: "SRGGB10_1X10",
        media: "/dev/media0",
        await: 0,
        runner: &System.cmd(&1, &2, stderr_to_stdout: true)
      )

    media_ctl = fn args -> run(opts[:runner], ["-d", opts[:media] | args]) end
    phy = "msm_csiphy#{csiphy}"
    csid = "msm_csid#{csiphy}"
    rdi = "msm_vfe#{csiphy}_rdi0"
    format = "fmt:#{opts[:code]}/#{opts[:width]}x#{opts[:height]}"
    wanted = [{{phy, 1}, {csid, 0}}, {{csid, 1}, {rdi, 0}}]

    deadline = System.monotonic_time(:millisecond) + opts[:await]

    with {:ok, graph, sensor} <- sensor_graph(media_ctl, phy, deadline),
         {:ok, subdev} <- devnode(graph, sensor),
         {:ok, video} <- devnode(graph, "msm_vfe#{csiphy}_video0"),
         {:ok, _} <- media_ctl.(["-l", links(graph, wanted)]),
         {:ok, _} <- media_ctl.(["-V", ~s("#{sensor}":0[#{format}])]),
         {:ok, _} <-
           media_ctl.(["-V", Enum.map_join([phy, csid, rdi], ",", &~s("#{&1}":0[#{format}]))]) do
      {:ok, %{sensor: sensor, video: video, subdev: subdev}}
    end
  end

  # The media graph and the sensor linked to `phy`, read again until both are there or `deadline`.
  defp sensor_graph(media_ctl, phy, deadline) do
    with {:ok, text} <- media_ctl.(["-p"]),
         graph = parse(text),
         {:ok, sensor} <- sensor(graph, phy) do
      {:ok, graph, sensor}
    else
      {:error, _} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(200)
          sensor_graph(media_ctl, phy, deadline)
        else
          error
        end
    end
  end

  defp run(runner, args) do
    case runner.("media-ctl", args) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, "media-ctl #{Enum.join(args, " ")} exited #{status}: #{output}"}
    end
  end

  defp sensor(graph, phy) do
    case Enum.find(graph.links, &(&1.sink == phy)) do
      %{source: sensor} -> {:ok, sensor}
      nil -> {:error, "no sensor is linked to #{phy}"}
    end
  end

  defp devnode(graph, entity) do
    case graph.entities[entity] do
      %{devnode: devnode} when is_binary(devnode) -> {:ok, devnode}
      _ -> {:error, "#{entity} has no device node in the media graph"}
    end
  end

  # The links to enable, after the enabled ones that feed the same sink pads from elsewhere.
  defp links(graph, wanted) do
    off =
      for link <- graph.links,
          link.enabled and not link.immutable,
          {source, sink} <- wanted,
          {link.sink, link.sink_pad} == sink,
          {link.source, link.source_pad} != source,
          do: ~s("#{link.source}":#{link.source_pad}->"#{link.sink}":#{link.sink_pad}[0])

    on = for {{source, p}, {sink, q}} <- wanted, do: ~s("#{source}":#{p}->"#{sink}":#{q}[1])
    Enum.join(off ++ on, ",")
  end
end
