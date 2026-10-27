unless Node.alive?() do
  {_, 0} = System.cmd("epmd", ["-daemon"])
  {:ok, _} = Node.start(:"gateway_test@127.0.0.1", :longnames)
end

ExUnit.start()
