defmodule FSS.Local do
  @moduledoc """
  Specification for local files.

  The `FSS.Local.Entry` represents a local file with its path.
  """

  defmodule Entry do
    defstruct [:path]

    @moduledoc """
    Represents a local file.
    """

    @typedoc """
    The only attribute is the `:path` to a local file.
    """
    @type t :: %__MODULE__{path: String.t()}
  end

  @doc """
  Builds a `FSS.Local.Entry` struct from a path.

  ## Examples

      iex> FSS.Local.from_path("/home/joe/file.txt")
      %FSS.Local.Entry{path: "/home/joe/file.txt"}

      iex> FSS.Local.from_path("C:/joe/file.txt")
      %FSS.Local.Entry{path: "C:/joe/file.txt"}

  """
  @spec from_path(String.t()) :: Entry.t()
  def from_path(path) when is_binary(path) do
    %Entry{path: path}
  end
end
