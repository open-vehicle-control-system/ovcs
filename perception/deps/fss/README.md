# FSS - File system specifications

[![Docs](https://img.shields.io/badge/hex.pm-docs-8e7ce6.svg)](https://hexdocs.pm/fss)
[![Actions Status](https://github.com/elixir-explorer/fss/actions/workflows/ci.yml/badge.svg)](https://github.com/elixir-explorer/fss/actions)

`FSS` is a small abstraction to describe how to access files in different filesystems.

The docs can be found at <https://hexdocs.pm/fss>.

## Installation

The package can be installed by adding `fss` to your list of dependencies
in `mix.exs`:

```elixir
def deps do
  [
    {:fss, "~> 0.1.0"}
  ]
end
```

Or by using `Mix.install/2`:

```elixir
Mix.install([{:fss, "~> 0.1.0"}])
```

## License

Copyright 2023 Philip Sampaio, José Valim

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
