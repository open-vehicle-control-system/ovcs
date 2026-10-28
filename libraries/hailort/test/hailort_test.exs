defmodule HailortTest do
  use ExUnit.Case, async: true

  test "the library ships under priv, the headers outside it" do
    app_dir = Application.app_dir(:hailort)

    assert Hailort.lib_dir() == Path.join(app_dir, "priv/lib")
    assert Hailort.include_dir() == Path.join(app_dir, "native/include")
    assert Hailort.link_dir() == Path.join(app_dir, "native/lib")
  end
end
