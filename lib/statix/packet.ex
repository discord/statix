defmodule Statix.Packet do
  @moduledoc false

  def build_metric(prefix, name, key, val, options) do
    [prefix, key, ?:, val, ?|, metric_type(name)]
    |> set_option(:sample_rate, options[:sample_rate])
    |> set_option(:tags, options[:tags])
  end

  @doc """
  Builds a DataDog event packet.

  Uses the DogStatsD event format (`_e{title_len,text_len}:title|text`),
  which is a DataDog-specific extension to the StatsD protocol. Standard StatsD
  servers do not support events.
  """
  def build_event(title, text, options) do
    title_bin = IO.iodata_to_binary(title)
    text_bin = IO.iodata_to_binary(text)

    [
      "_e{",
      Integer.to_string(byte_size(title_bin)),
      ",",
      Integer.to_string(byte_size(text_bin)),
      "}:",
      title_bin,
      "|",
      text_bin
    ]
    |> set_option(:tags, options[:tags])
  end

  metrics = %{
    counter: "c",
    gauge: "g",
    histogram: "h",
    timing: "ms",
    set: "s",

    # DogStatsD.
    distribution: "d"
  }

  for {name, type} <- metrics do
    defp metric_type(unquote(name)), do: unquote(type)
  end

  defp set_option(packet, _kind, nil) do
    packet
  end

  defp set_option(packet, :sample_rate, sample_rate) when is_float(sample_rate) do
    [packet | ["|@", :erlang.float_to_binary(sample_rate, [:compact, decimals: 2])]]
  end

  defp set_option(packet, :tags, []), do: packet

  defp set_option(packet, :tags, tags) when is_list(tags) do
    [packet | ["|#", Enum.join(tags, ",")]]
  end
end
