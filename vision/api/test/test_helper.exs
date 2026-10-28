# `mix test --no-start` starts nothing; the endpoint and PubSub back every channel and conn test.
{:ok, _apps} = Application.ensure_all_started(:vision_api)
ExUnit.start()
