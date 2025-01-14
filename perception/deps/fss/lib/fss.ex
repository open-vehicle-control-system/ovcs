defmodule FSS do
  # The initial work is from Explorer's code base.
  #
  # See https://github.com/elixir-explorer/explorer/pull/645
  # and the PRs that followed that one.

  @moduledoc """
  A small abstraction to describe how to access files.

  It works with different file systems, for local files
  and remote ones.

  It's a library to parse and validate URIs, with the necessary
  attributes.

  See the supported specifications for more details:

  * `FSS.Local`
  * `FSS.HTTP`
  * `FSS.S3`
  """

  @typedoc """
  Can be used to refer to any entry that FSS supports.
  """
  @type entry() :: FSS.Local.Entry.t() | FSS.S3.Entry.t() | FSS.HTTP.Entry.t()
end
