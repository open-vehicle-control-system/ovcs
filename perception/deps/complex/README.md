# Complex

*Complex* is a library for types and mathematical functions for complex
numbers.

Each complex number is represented as a structure holding the real and
imaginary part.  There are functions for creation and manipulation of
them. Users can `use Complex.Kernel` to get operators to work on a mix
of real and complex numbers.

## Installation

Add *complex* as a dependency in your `mix.exs` file.

```elixir
def deps do
  [{:complex, "~> 0.4.1"}]
end
```

After you are done, run `mix deps.get` in your shell to fetch and compile
Complex. Start an interactive Elixir shell with `iex -S mix` and try the examples
in the [examples section](#examples).

## Documentation

Documentation for the package is available online via Hex at
[http://hexdocs.pm/complex](http://hexdocs.pm/complex).  You can also generate
local docs via the mix task

```elixir
mix docs
```

This will generate the HTML documentation and place it into the `doc` subdirectory.

## Examples

```elixir
iex> Complex.new(3, 4)
%Complex{im: 4.0, re: 3.0}

iex> Complex.new(0, 1)
%Complex{im: 1.0, re: 0.0}
```

## License

   Copyright 2015 Thomas Krauss

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
