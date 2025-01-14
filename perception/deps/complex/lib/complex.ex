defmodule Complex do
  @moduledoc """
  *Complex* is a library that brings complex number support to Elixir.

  Each complex number is represented as a `%Complex{}` struct, that holds
  the real and imaginary parts. There are functions for the creation and
  manipulation of complex numbers.

  This module implements mathematical functions such as `add/2`, `subtract/2`,
  `divide/2`, and `multiply/2` that subtitute the `+`, `-`, `/` and `*` operators.

  Operator overloading is provided through `Complex.Kernel`

  ### Examples

      iex> Complex.new(3, 4)
      %Complex{im: 4.0, re: 3.0}

      iex> Complex.new(0, 1)
      %Complex{im: 1.0, re: 0.0}
  """

  @vsn 2

  import Kernel, except: [abs: 1]

  math_fun_supported? = fn fun, arity ->
    Code.ensure_loaded?(:math) and
      try do
        args =
          case {fun, arity} do
            {:atan, 1} -> [3.14]
            {:atanh, 1} -> [0.9]
            {_, 1} -> [1.0]
            {_, 2} -> [1.0, 1.0]
          end

        _ = apply(:math, fun, args)
        true
      rescue
        UndefinedFunctionError ->
          false
      end
  end

  @typedoc """
  A complex number represented as a `%Complex{}` struct.
  """
  @type t :: %Complex{re: number, im: number}
  defstruct re: 0, im: 0

  @type non_finite_number :: :infinity | :neg_infinity | :nan

  @non_finite_numbers [:infinity, :neg_infinity, :nan]

  @sin_pi :math.sin(:math.pi())
  @cos_pi_on_2 :math.cos(:math.pi() / 2)

  defguardp is_non_finite_number(x) when x in @non_finite_numbers

  defimpl Inspect do
    def inspect(val, _opts),
      do: Complex.to_string(val)
  end

  defimpl String.Chars do
    def to_string(%Complex{} = z), do: Complex.to_string(z)
  end

  @doc """
  Conveniency function that is used to implement the `String.Chars` and `Inspect` protocols.
  """
  @spec to_string(t) :: String.t()
  def to_string(%Complex{re: re, im: im}) do
    "#{to_string_real(re)}#{to_string_component(im)}i"
  end

  defp to_string_real(n) do
    case to_string_component(n) do
      "-" <> _ = s -> s
      "+" <> s -> s
    end
  end

  defp to_string_component(:infinity), do: "+Inf"
  defp to_string_component(:neg_infinity), do: "-Inf"
  defp to_string_component(:nan), do: "+NaN"

  defp to_string_component(n) when n == 0, do: "+0.0"

  defp to_string_component(n) do
    abs_s = Kernel.to_string(abs(n))

    if n >= 0 do
      "+#{abs_s}"
    else
      "-#{abs_s}"
    end
  end

  @doc """
  Returns a new complex with specified real and imaginary components. The
  imaginary part defaults to zero so a real number can be created with `new/1`.

  ### See also

  `from_polar/2`

  ### Examples

      iex> Complex.new(3, 4)
      %Complex{im: 4.0, re: 3.0}

      iex> Complex.new(2)
      %Complex{im: 0.0, re: 2.0}

      iex> Complex.new(:infinity)
      %Complex{im: 0.0, re: :infinity}

      iex> Complex.new(:nan, :neg_infinity)
      %Complex{im: :neg_infinity, re: :nan}
  """
  @spec new(number | non_finite_number, number | non_finite_number) :: t
  def new(re, im \\ 0)

  def new(re, im) do
    re_f = as_float(re)
    im_f = as_float(im)

    %Complex{re: re_f, im: im_f}
  end

  @doc """
  Parses a complex number from a string.  The values of the real and imaginary
  parts must be represented by a float, including decimal and at least one
  trailing digit (e.g. 1.2, 0.4).

  ### See also

  `new/2`

  ### Examples

      iex> Complex.parse("1.1+2.2i")
      {%Complex{im: 2.2, re: 1.1}, ""}

      iex> Complex.parse("1+2i")
      {%Complex{im: 2.0, re: 1.0}, ""}

      iex> Complex.parse("2-3i")
      {%Complex{im: -3.0, re: 2.0}, ""}

      iex> Complex.parse("-1.0-3.i")
      {%Complex{im: -3.0, re: -1.0}, ""}

      iex> Complex.parse("-1.0+3.i 2.2+3.3i")
      {%Complex{im: 3.0, re: -1.0}, " 2.2+3.3i"}

      iex> Complex.parse("1e-4-3e-3i")
      {%Complex{im: -3.0e-3, re: 1.0e-4}, ""}

      iex> Complex.parse("2i")
      {%Complex{im: 2.0, re: 0.0}, ""}

      iex> Complex.parse("-3.0i")
      {%Complex{im: -3.0, re: 0.0}, ""}

      iex> Complex.parse("NaN+Infi")
      {%Complex{im: :infinity, re: :nan}, ""}

      iex> Complex.parse("-Inf+NaNi")
      {%Complex{im: :nan, re: :neg_infinity}, ""}

      iex> Complex.parse("Inf-NaNi")
      {%Complex{im: :nan, re: :infinity}, ""}

      iex> Complex.parse("Inf")
      {%Complex{im: 0.0, re: :infinity}, ""}
  """
  @spec parse(String.t()) :: {t, String.t()} | :error
  def parse(str) do
    with {real_part, sign_multiplier, tail} <- parse_real(str),
         {imag_part, tail} <- parse_imag(tail) do
      {new(real_part, multiply(sign_multiplier, imag_part)), tail}
    else
      {:imag_non_finite, {imag_part, tail}} ->
        {new(0, imag_part), tail}

      {:real_non_finite, {real_part, tail}} ->
        {new(real_part, 0), tail}

      _ ->
        case parse_imag(str) do
          :error -> :error
          {val, tail} -> {new(0, val), tail}
        end
    end
  end

  defp parse_real("Inf+" <> tail), do: {:infinity, 1, tail}
  defp parse_real("+Inf+" <> tail), do: {:infinity, 1, tail}
  defp parse_real("Inf-" <> tail), do: {:infinity, -1, tail}
  defp parse_real("+Inf-" <> tail), do: {:infinity, -1, tail}
  defp parse_real("-Inf+" <> tail), do: {:neg_infinity, 1, tail}
  defp parse_real("-Inf-" <> tail), do: {:neg_infinity, -1, tail}
  defp parse_real("NaN+" <> tail), do: {:nan, 1, tail}
  defp parse_real("+NaN+" <> tail), do: {:nan, 1, tail}
  defp parse_real("-NaN+" <> tail), do: {:nan, 1, tail}
  defp parse_real("NaN-" <> tail), do: {:nan, -1, tail}
  defp parse_real("+NaN-" <> tail), do: {:nan, -1, tail}
  defp parse_real("-NaN-" <> tail), do: {:nan, -1, tail}

  defp parse_real("Infi" <> tail), do: {:imag_non_finite, {:infinity, tail}}
  defp parse_real("-Infi" <> tail), do: {:imag_non_finite, {:neg_infinity, tail}}
  defp parse_real("NaNi" <> tail), do: {:imag_non_finite, {:nan, tail}}

  defp parse_real("Inf" <> tail), do: {:real_non_finite, {:infinity, tail}}
  defp parse_real("-Inf" <> tail), do: {:real_non_finite, {:neg_infinity, tail}}
  defp parse_real("NaN" <> tail), do: {:real_non_finite, {:nan, tail}}

  defp parse_real(str) do
    case Float.parse(str) do
      {val, ".+" <> tail} -> {val, 1, tail}
      {val, ".-" <> tail} -> {val, -1, tail}
      {val, "+" <> tail} -> {val, 1, tail}
      {val, "-" <> tail} -> {val, -1, tail}
      _ -> :error
    end
  end

  defp parse_imag("i" <> tail), do: {1, tail}
  defp parse_imag("Infi" <> tail), do: {:infinity, tail}
  defp parse_imag("+Infi" <> tail), do: {:infinity, tail}
  defp parse_imag("-Infi" <> tail), do: {:neg_infinity, tail}
  defp parse_imag("NaNi" <> tail), do: {:nan, tail}
  defp parse_imag("+NaNi" <> tail), do: {:nan, tail}
  defp parse_imag("-NaNi" <> tail), do: {:nan, tail}

  defp parse_imag(str) do
    case Float.parse(str) do
      {val, ".i" <> tail} -> {val, tail}
      {val, "i" <> tail} -> {val, tail}
      _ -> :error
    end
  end

  @doc ~S"""
  Turns a representation in polar coordinates $r\phase\phi$, into
  the complex number $z = r.cos(\phi) + r.sin(\phi) i$

  ### See also

  `new/2`

  ### Examples

      iex> Complex.from_polar(1, :math.pi/2)
      %Complex{im: 1.0, re: 6.123233995736766e-17}

      iex> polar = Complex.to_polar(%Complex{re: 6, im: 20})
      iex> Complex.from_polar(polar)
      %Complex{im: 20.0, re: 6.0}

  """
  @spec from_polar({number | non_finite_number, number | non_finite_number}) :: t
  def from_polar({r, phi}), do: from_polar(r, phi)

  @spec from_polar(number | non_finite_number, number | non_finite_number) :: t
  def from_polar(r, phi) when phi == 0, do: new(r, 0)

  def from_polar(r, phi) do
    s = sin(phi)
    c = cos(phi)

    # treat pure imaginary and pure real cases
    cond do
      s == @sin_pi and (r == :infinity or r == :neg_infinity) ->
        new(multiply(r, c), 0)

      c == @cos_pi_on_2 and (r == :infinity or r == :neg_infinity) ->
        new(0, multiply(r, s))

      c == -@cos_pi_on_2 and (r == :infinity or r == :neg_infinity) ->
        new(0, multiply(r, s))

      :otherwise ->
        multiply(r, new(c, s))
    end
  end

  @doc """
  Returns the phase angle of the supplied complex, in radians.

  ### See also

  `new/2`, `from_polar/2`

  ### Examples

      iex> Complex.phase(Complex.from_polar(1,:math.pi/2))
      1.5707963267948966

  """
  @spec phase(t | number | non_finite_number) :: float | non_finite_number
  def phase(z)

  def phase(:nan), do: :nan
  def phase(:infinity), do: 0
  def phase(:neg_infinity), do: :math.pi()

  def phase(%Complex{re: :nan, im: im}) when is_number(im), do: :nan
  def phase(%Complex{re: :infinity, im: im}) when is_number(im), do: 0
  def phase(%Complex{re: :neg_infinity, im: im}) when is_number(im), do: :math.pi()

  def phase(%Complex{re: :infinity, im: :infinity}), do: :math.pi() / 4
  def phase(%Complex{re: :infinity, im: :neg_infinity}), do: -:math.pi() / 4
  def phase(%Complex{re: :neg_infinity, im: :infinity}), do: 3 * :math.pi() / 4
  def phase(%Complex{re: :neg_infinity, im: :neg_infinity}), do: 5 * :math.pi() / 4

  def phase(%Complex{re: :infinity}), do: :nan
  def phase(%Complex{re: :neg_infinity}), do: :nan

  def phase(%Complex{im: :infinity}), do: :math.pi() / 2
  def phase(%Complex{im: :neg_infinity}), do: -:math.pi() / 2
  def phase(%Complex{im: :nan}), do: :nan

  def phase(n) when n < 0, do: :math.pi()
  def phase(n) when is_number(n), do: 0

  def phase(z = %Complex{}) do
    atan2(z.im, z.re)
  end

  @doc """
  Returns the polar coordinates of the supplied complex.  That is, the
  returned tuple {r,phi} is the magnitude and phase (in radians) of z.

  ### See also

  `from_polar/2`

  ### Examples

      iex> Complex.to_polar(Complex.from_polar(1,:math.pi/2))
      {1.0, 1.5707963267948966}

  """
  @spec to_polar(t | number | non_finite_number) ::
          {float | non_finite_number, float | non_finite_number}
  def to_polar(t)

  def to_polar(z = %Complex{}) do
    {abs(z), phase(z)}
  end

  def to_polar(n) when n < 0, do: {n, :math.pi()}
  def to_polar(n) when is_number(n), do: {n, 0}

  def to_polar(:infinity), do: {:infinity, 0}
  def to_polar(:neg_infinity), do: {:infinity, :math.pi()}
  def to_polar(:nan), do: {:nan, :nan}

  @doc """
  Returns a new complex that is the sum of the provided complex numbers.  Also
  supports a mix of complex and number.

  ### See also

  `div/2`, `multiply/2`, `subtract/2`

  ### Examples

      iex> Complex.add(Complex.from_polar(1, :math.pi/2), Complex.from_polar(1, :math.pi/2))
      %Complex{im: 2.0, re: 1.2246467991473532e-16}

      iex> Complex.add(Complex.new(4, 4), 1)
      %Complex{im: 4.0, re: 5.0}

      iex> Complex.add(2, Complex.new(4, 3))
      %Complex{im: 3.0, re: 6.0}

      iex> Complex.add(2, 3)
      5

      iex> Complex.add(2.0, 2)
      4.0

  """
  @spec add(t | number | non_finite_number, t | number | non_finite_number) ::
          t | number | non_finite_number

  def add(z, %Complex{re: re, im: im}) when z in [:infinity, :neg_infinity, :nan],
    do: Complex.new(add(z, re), im)

  def add(%Complex{re: re, im: im}, z) when z in [:infinity, :neg_infinity, :nan],
    do: Complex.new(add(z, re), im)

  def add(:nan, _), do: :nan
  def add(_, :nan), do: :nan

  def add(:infinity, :neg_infinity), do: :nan
  def add(:neg_infinity, :infinity), do: :nan
  def add(:infinity, _), do: :infinity
  def add(_, :infinity), do: :infinity

  def add(:neg_infinity, _), do: :neg_infinity
  def add(_, :neg_infinity), do: :neg_infinity

  def add(left, right) when is_number(left) and is_number(right), do: left + right

  def add(left, right) do
    %Complex{re: re_left, im: im_left} = as_complex(left)
    %Complex{re: re_right, im: im_right} = as_complex(right)
    new(add(re_left, re_right), add(im_left, im_right))
  end

  @doc """
  Returns a new complex that is the difference of the provided complex numbers.
  Also supports a mix of complex and number.

  ### See also

  `add/2`, `div/2`, `multiply/2`

  ### Examples

      iex> Complex.subtract(Complex.new(1,2), Complex.new(3,4))
      %Complex{im: -2.0, re: -2.0}

      iex> Complex.subtract(Complex.new(1, 2), 3)
      %Complex{im: 2.0, re: -2.0}

      iex> Complex.subtract(10, Complex.new(1, 2))
      %Complex{im: -2.0, re: 9.0}

  """
  @spec subtract(t | number | non_finite_number, t | number | non_finite_number) ::
          t | number | non_finite_number

  def subtract(z, %Complex{re: re, im: im}) when z in [:infinity, :neg_infinity, :nan],
    do: Complex.new(subtract(z, re), negate(im))

  def subtract(%Complex{re: re, im: im}, z) when z in [:infinity, :neg_infinity, :nan],
    do: Complex.new(subtract(re, z), im)

  def subtract(:nan, _), do: :nan
  def subtract(_, :nan), do: :nan
  def subtract(:infinity, :infinity), do: :nan
  def subtract(:neg_infinity, :neg_infinity), do: :nan

  def subtract(:infinity, _), do: :infinity
  def subtract(_, :infinity), do: :neg_infinity
  def subtract(:neg_infinity, _), do: :neg_infinity
  def subtract(_, :neg_infinity), do: :infinity

  def subtract(left, right) when is_number(left) and is_number(right), do: left - right

  def subtract(left, right) do
    %Complex{re: re_left, im: im_left} = as_complex(left)
    %Complex{re: re_right, im: im_right} = as_complex(right)
    new(subtract(re_left, re_right), subtract(im_left, im_right))
  end

  @doc """
  Returns a new complex that is the product of the provided complex numbers.
  Also supports a mix of complex and number.

  ### See also

  `add/2`, `div/2`, `subtract/2`

  ### Examples

      iex> Complex.multiply(Complex.new(1,2), Complex.new(3,4))
      %Complex{im: 10.0, re: -5.0}

      iex> Complex.multiply(Complex.new(0, 1), Complex.new(0, 1))
      %Complex{im: 0.0, re: -1.0}

      iex> Complex.multiply(Complex.new(1, 2), 3)
      %Complex{im: 6.0, re: 3.0}

      iex> Complex.multiply(3, Complex.new(1, 2))
      %Complex{im: 6.0, re: 3.0}

      iex> Complex.multiply(-2, Complex.new(:infinity, :neg_infinity))
      %Complex{im: :nan, re: :nan}

  """
  @spec multiply(t | number | non_finite_number, t | number | non_finite_number) ::
          t | number | non_finite_number

  def multiply(x, c = %Complex{re: _re, im: _im}) when is_non_finite_number(x) or is_number(x) do
    z = new(x, 0)
    multiply(z, c)
  end

  def multiply(c = %Complex{re: _re, im: _im}, x) when is_non_finite_number(x) or is_number(x) do
    z = new(x, 0)
    multiply(c, z)
  end

  def multiply(:infinity, right) when is_number(right) and right > 0, do: :infinity
  def multiply(:infinity, right) when right == 0, do: :nan
  def multiply(:infinity, right) when is_number(right) and right < 0, do: :neg_infinity
  def multiply(left, :infinity) when is_number(left) and left > 0, do: :infinity
  def multiply(left, :infinity) when left == 0, do: :nan
  def multiply(left, :infinity) when is_number(left) and left < 0, do: :neg_infinity

  def multiply(:neg_infinity, right) when is_number(right) and right > 0, do: :neg_infinity
  def multiply(:neg_infinity, right) when right == 0, do: :nan
  def multiply(:neg_infinity, right) when is_number(right) and right < 0, do: :infinity
  def multiply(left, :neg_infinity) when is_number(left) and left > 0, do: :neg_infinity
  def multiply(left, :neg_infinity) when left == 0, do: :nan
  def multiply(left, :neg_infinity) when is_number(left) and left < 0, do: :infinity

  def multiply(:nan, _), do: :nan
  def multiply(_, :nan), do: :nan

  def multiply(:neg_infinity, :neg_infinity), do: :infinity
  def multiply(:neg_infinity, :infinity), do: :neg_infinity
  def multiply(:infinity, :neg_infinity), do: :neg_infinity
  def multiply(:infinity, :infinity), do: :infinity

  def multiply(left, right) when is_number(left) and is_number(right), do: left * right

  def multiply(left, right) do
    %Complex{re: r1, im: i1} = as_complex(left)
    %Complex{re: r2, im: i2} = as_complex(right)
    new(subtract(multiply(r1, r2), multiply(i1, i2)), add(multiply(i1, r2), multiply(r1, i2)))
  end

  @doc """
  Returns a new complex that is the square of the provided complex number.

  ### See also

  `multiply/2`

  ### Examples

      iex> Complex.square(Complex.new(2.0, 0.0))
      %Complex{im: 0.0, re: 4.0}

      iex> Complex.square(Complex.new(0, 1))
      %Complex{im: 0.0, re: -1.0}

  """
  @spec square(t | number | non_finite_number) :: t | number | non_finite_number
  def square(z), do: multiply(z, z)

  @doc """
  Returns a new complex that is the ratio (division) of the provided complex
  numbers.

  ### See also

  `add/2`, `multiply/2`, `subtract/2`

  ### Examples

      iex> Complex.divide(Complex.from_polar(1, :math.pi/2), Complex.from_polar(1, :math.pi/2))
      %Complex{im: 0.0, re: 1.0}

  """
  @spec divide(t | number | non_finite_number, t | number | non_finite_number) ::
          t | number | non_finite_number

  def divide(x, y) when is_non_finite_number(x) and is_non_finite_number(y), do: :nan
  def divide(x, y) when is_non_finite_number(x) and is_number(y) and y >= 0, do: x
  def divide(x, y) when x == 0 and y == 0, do: :nan
  def divide(:nan, a) when is_number(a), do: :nan
  def divide(a, :nan) when is_number(a), do: :nan
  def divide(:infinity, y) when is_number(y) and y < 0, do: :neg_infinity
  def divide(:neg_infinity, y) when is_number(y) and y < 0, do: :infinity
  def divide(a, :infinity) when is_number(a), do: 0
  def divide(a, :neg_infinity) when is_number(a), do: 0

  def divide(x, y) when is_number(x) and is_number(y), do: x / y

  def divide(n, b) when is_number(n) and b in [:infinity, :neg_infinity] do
    0
  end

  def divide(n, %Complex{re: re_r, im: im_r})
      when is_number(n) and re_r in [:infinity, :neg_infinity] and im_r == 0 do
    new(0, 0)
  end

  def divide(%Complex{re: re, im: im}, b)
      when is_number(re) and is_number(im) and b in [:infinity, :neg_infinity] do
    new(0, 0)
  end

  def divide(%Complex{re: re, im: im}, %Complex{re: re_r, im: im_r})
      when is_number(re) and is_number(im) and re_r in [:infinity, :neg_infinity] and im_r == 0 do
    new(0, 0)
  end

  def divide(x, y) do
    %Complex{re: r1, im: i1} = as_complex(x)
    %Complex{re: r2, im: i2} = as_complex(y)

    num_re = add(multiply(r1, r2), multiply(i1, i2))
    num_im = subtract(multiply(i1, r2), multiply(r1, i2))
    den = add(square(r2), square(i2))

    new(divide(num_re, den), divide(num_im, den))
  end

  @doc """
  Returns the magnitude (length) of the provided complex number.

  ### See also

  `new/2`, `phase/1`

  ### Examples

      iex> Complex.abs(Complex.from_polar(1, :math.pi/2))
      1.0

  """
  @spec abs(t | number | non_finite_number) :: number | non_finite_number
  def abs(z)

  def abs(:nan), do: :nan
  def abs(:infinity), do: :infinity
  def abs(:neg_infinity), do: :infinity

  def abs(n) when is_number(n), do: Kernel.abs(n)

  def abs(%Complex{re: :nan, im: :nan}), do: :nan

  def abs(%Complex{re: r, im: i}) when is_non_finite_number(r) or is_non_finite_number(i),
    do: :infinity

  def abs(%Complex{re: r, im: i}) do
    # optimized by checking special cases (sqrt is expensive)
    x = Kernel.abs(r)
    y = Kernel.abs(i)

    cond do
      x == 0.0 -> y
      y == 0.0 -> x
      x > y -> x * :math.sqrt(1.0 + y / x * (y / x))
      true -> y * :math.sqrt(1.0 + x / y * (x / y))
    end
  end

  @doc """
  Returns the square of the magnitude of the provided complex number.

  The square of the magnitude is faster to compute---no square roots!

  ### See also

  `new/2`, `abs/1`

  ### Examples

      iex> Complex.abs_squared(Complex.from_polar(1, :math.pi/2))
      1.0

      iex> Complex.abs_squared(Complex.from_polar(2, :math.pi/2))
      4.0

  """
  @spec abs_squared(t | number | non_finite_number) :: number
  def abs_squared(z)

  def abs_squared(:nan), do: :nan
  def abs_squared(:infinity), do: :infinity
  def abs_squared(:neg_infinity), do: :infinity

  def abs_squared(n) when is_number(n), do: n * n

  def abs_squared(%Complex{re: :nan, im: :nan}), do: :nan

  def abs_squared(%Complex{re: r, im: i}) when is_non_finite_number(r) or is_non_finite_number(i),
    do: :infinity

  def abs_squared(%Complex{re: r, im: i}) do
    r * r + i * i
  end

  @doc """
  Returns the real part of the provided complex number.

  ### See also

  `imag/1`

  ### Examples

      iex> Complex.real(Complex.new(1, 2))
      1.0

      iex> Complex.real(1)
      1
  """
  @spec real(t | number | non_finite_number) :: number | non_finite_number
  def real(z)

  def real(n) when is_number(n) or is_non_finite_number(n), do: n

  def real(%Complex{re: r, im: _i}), do: r

  @doc """
  Returns the imaginary part of the provided complex number.
  If a real number is provided, 0 is returned.

  ### See also

  `real/1`

  ### Examples

      iex> Complex.imag(Complex.new(1, 2))
      2.0

      iex> Complex.imag(1)
      0
  """

  @spec imag(t | number | non_finite_number) :: number | non_finite_number
  def imag(z)

  def imag(n) when is_number(n), do: n * 0
  def imag(n) when is_non_finite_number(n), do: 0

  def imag(%Complex{re: _r, im: i}), do: i

  @doc """
  Returns a new complex that is the complex conjugate of the provided complex
  number.

  If $z = a + bi$, $conjugate(z) = z^* = a - bi$

  ### See also

  `abs/2`, `phase/1`

  ### Examples

      iex> Complex.conjugate(Complex.new(1,2))
      %Complex{im: -2.0, re: 1.0}

  """
  @spec conjugate(t | number | non_finite_number) :: t | number | non_finite_number
  def conjugate(z)

  def conjugate(n) when is_number(n) or is_non_finite_number(n), do: n

  def conjugate(%Complex{re: r, im: :neg_infinity}), do: new(r, :infinity)
  def conjugate(%Complex{re: r, im: :infinity}), do: new(r, :neg_infinity)
  def conjugate(%Complex{re: r, im: :nan}), do: new(r, :nan)

  def conjugate(%Complex{re: r, im: i}) do
    new(r, -i)
  end

  @doc """
  Returns a new complex that is the complex square root of the provided
  complex number.

  ### See also

  `abs/1`, `cbrt/1`, `phase/1`

  ### Examples

      iex> Complex.sqrt(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.4142135623730951, re: 8.659560562354933e-17}

  """
  @spec sqrt(t | number | non_finite_number) :: t | number | non_finite_number
  def sqrt(z)
  def sqrt(:infinity), do: :infinity
  def sqrt(:neg_infinity), do: :nan
  def sqrt(:nan), do: :nan
  def sqrt(n) when is_number(n), do: :math.sqrt(n)

  def sqrt(%Complex{re: :nan}), do: Complex.new(:nan, :nan)
  def sqrt(%Complex{im: :nan}), do: Complex.new(:nan, :nan)
  def sqrt(%Complex{im: :infinity}), do: Complex.new(:infinity, :infinity)
  def sqrt(%Complex{im: :neg_infinity}), do: Complex.new(:infinity, :neg_infinity)
  def sqrt(%Complex{re: :infinity}), do: Complex.new(:infinity)
  def sqrt(%Complex{re: :neg_infinity}), do: Complex.new(0, :infinity)

  def sqrt(%Complex{re: r, im: i}) do
    if r == 0.0 and i == 0.0 do
      new(r, i)
    else
      x = Kernel.abs(r)
      y = Kernel.abs(i)

      w =
        if x >= y do
          :math.sqrt(x) * :math.sqrt(0.5 * (1.0 + :math.sqrt(1.0 + y / x * (y / x))))
        else
          :math.sqrt(y) * :math.sqrt(0.5 * (x / y + :math.sqrt(1.0 + x / y * (x / y))))
        end

      if r >= 0.0 do
        new(w, i / (2 * w))
      else
        i2 =
          if i >= 0.0 do
            w
          else
            -w
          end

        new(i / (2 * i2), i2)
      end
    end
  end

  @doc """
  Returns a new number that is the complex cube root of the provided
  number.

  Returns the principal branch of the cube root for complex inputs.

  ### See also

  `abs/1`, `phase/1`, `sqrt/1`

  ### Examples

      iex> Complex.cbrt(-8)
      -2.0

  When a negative number is given as a complex input,
  the output now changes. Instead of still giving a
  negative number, we now get a number with phase
  $\\frac{\\pi}{3}$

      iex> z = Complex.cbrt(Complex.new(-8, 0))
      %Complex{re: 1.0000000000000002, im: 1.7320508075688772}
      iex> Complex.abs(z)
      2.0
      iex> Complex.phase(z)
      1.0471975511965976
      iex> :math.pi() / 3
      1.0471975511965976

  """
  @spec cbrt(t | number | non_finite_number) :: t | float() | non_finite_number
  def cbrt(z)
  def cbrt(:infinity), do: :infinity
  def cbrt(:neg_infinity), do: :neg_infinity
  def cbrt(:nan), do: :nan
  def cbrt(n) when is_number(n) and n >= 0, do: :math.pow(n, 1 / 3)
  def cbrt(n) when is_number(n), do: -1 * cbrt(abs(n))

  def cbrt(z) do
    r = abs(z)
    theta = phase(z)

    from_polar(cbrt(r), theta / 3)
  end

  @doc """
  Returns a new complex that is the complex exponential of the provided
  complex number: $exp(z) = e^z$.

  ### See also

  `log/1`

  ### Examples

      iex> Complex.exp(Complex.from_polar(2,:math.pi))
      %Complex{im: 3.3147584285483636e-17, re: 0.1353352832366127}

  """
  @spec exp(t | number | non_finite_number) :: t | number | non_finite_number
  def exp(z)

  def exp(:infinity), do: :infinity
  def exp(:neg_infinity), do: 0
  def exp(:nan), do: :nan
  def exp(n) when is_number(n), do: :math.exp(n)

  def exp(%Complex{re: :neg_infinity, im: _}), do: new(0, 0)
  def exp(%Complex{re: :infinity, im: :nan}), do: new(:infinity, :nan)

  def exp(%Complex{re: :infinity, im: im}) when is_number(im) do
    re =
      case :math.cos(im) do
        x when x > 0 -> :infinity
        x when x < 0 -> :neg_infinity
        _ -> :nan
      end

    im =
      case :math.sin(im) do
        x when x > 0 -> :infinity
        x when x < 0 -> :neg_infinity
        _ -> :nan
      end

    new(re, im)
  end

  def exp(%Complex{re: _, im: :neg_infinity}), do: new(:nan, :nan)
  def exp(%Complex{re: _, im: :infinity}), do: new(:nan, :nan)
  def exp(%Complex{re: :nan, im: _}), do: new(:nan, :nan)
  def exp(%Complex{re: _, im: :nan}), do: new(:nan, :nan)

  def exp(z = %Complex{}) do
    rho = :math.exp(z.re)
    theta = z.im
    new(rho * :math.cos(theta), rho * :math.sin(theta))
  end

  @doc """
  Returns a new complex that is the complex natural log of the provided
  complex number, $log(z) = log_e(z)$.

  ### See also

  `exp/1`

  ### Examples

      iex> Complex.log(Complex.from_polar(2,:math.pi))
      %Complex{im: 3.141592653589793, re: 0.6931471805599453}

  """
  @spec log(t | number | non_finite_number) :: t | number | non_finite_number
  def log(z)
  def log(:infinity), do: :infinity
  def log(:neg_infinity), do: new(:infinity, :math.pi())
  def log(:nan), do: :nan
  def log(n) when is_number(n) and n == 0, do: :neg_infinity
  def log(n) when is_number(n) and n < 0, do: :nan
  def log(n) when is_number(n), do: :math.log(n)

  def log(z = %Complex{}) do
    new(log(abs(z)), atan2(z.im, z.re))
  end

  @deprecated "Use log/1 instead"
  def ln(x), do: log(x)

  @doc """
  Returns a new complex that is the complex log base 10 of the provided
  complex number.

  ### See also

  `log/1`

  ### Examples

      iex> Complex.log10(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.3643763538418412, re: 0.30102999566398114}

  """
  @spec log10(t | number | non_finite_number) :: t | number | non_finite_number
  def log10(z)

  def log10(:infinity), do: :infinity

  def log10(:neg_infinity) do
    new(:infinity, :math.pi() / :math.log(10))
  end

  def log10(:nan), do: :nan
  def log10(n) when is_number(n) and n == 0, do: :neg_infinity
  def log10(n) when is_number(n) and n < 0, do: :nan

  def log10(n) when is_number(n), do: :math.log10(n)

  def log10(%Complex{re: :infinity, im: im}) when is_number(im) do
    new(:infinity, 0)
  end

  def log10(%Complex{re: :neg_infinity, im: im}) when is_number(im) do
    new(:infinity, :math.pi() / :math.log(10))
  end

  def log10(%Complex{im: :infinity, re: re}) when is_number(re) do
    new(:infinity, :math.pi() / (2 * :math.log(10)))
  end

  def log10(%Complex{im: :neg_infinity, re: re}) when is_number(re) do
    new(:infinity, -:math.pi() / (2 * :math.log(10)))
  end

  def log10(%Complex{re: :infinity, im: :infinity}) do
    new(:infinity, :math.pi() / (4 * :math.log(10)))
  end

  def log10(%Complex{re: :infinity, im: :neg_infinity}) do
    new(:infinity, -:math.pi() / (4 * :math.log(10)))
  end

  def log10(%Complex{re: :neg_infinity, im: :neg_infinity}) do
    new(:infinity, -3 * :math.pi() / (4 * :math.log(10)))
  end

  def log10(%Complex{re: :neg_infinity, im: :infinity}) do
    new(:infinity, 3 * :math.pi() / (4 * :math.log(10)))
  end

  def log10(z = %Complex{}) do
    divide(log(z), new(:math.log(10.0), 0.0))
  end

  @doc """
  Returns a new complex that is the complex log base 2 of the provided
  complex number.

  ### See also

  `log/1`, `log10/1`

  ### Examples

      iex> Complex.log2(Complex.from_polar(2,:math.pi))
      %Complex{im: 4.532360141827194, re: 1.0}

  """
  @spec log2(t | number | non_finite_number) :: t | number | non_finite_number
  def log2(z)

  def log2(:infinity), do: :infinity
  def log2(:neg_infinity), do: divide(log(:neg_infinity), :math.log(2))
  def log2(:nan), do: :nan
  def log2(n) when is_number(n) and n == 0, do: :neg_infinity
  def log2(n) when is_number(n) and n < 0, do: :nan

  def log2(n) when is_number(n), do: :math.log2(n)

  def log2(%Complex{re: :infinity, im: im}) when is_number(im) do
    new(:infinity, 0)
  end

  def log2(%Complex{re: :neg_infinity, im: im}) when is_number(im) do
    new(:infinity, :math.pi() / :math.log(2))
  end

  def log2(%Complex{im: :infinity, re: re}) when is_number(re) do
    new(:infinity, :math.pi() / (2 * :math.log(2)))
  end

  def log2(%Complex{im: :neg_infinity, re: re}) when is_number(re) do
    new(:infinity, -:math.pi() / (2 * :math.log(2)))
  end

  def log2(%Complex{re: :infinity, im: :infinity}) do
    new(:infinity, :math.pi() / (4 * :math.log(2)))
  end

  def log2(%Complex{re: :infinity, im: :neg_infinity}) do
    new(:infinity, -:math.pi() / (4 * :math.log(2)))
  end

  def log2(%Complex{re: :neg_infinity, im: :neg_infinity}) do
    new(:infinity, -3 * :math.pi() / (4 * :math.log(2)))
  end

  def log2(%Complex{re: :neg_infinity, im: :infinity}) do
    new(:infinity, 3 * :math.pi() / (4 * :math.log(2)))
  end

  def log2(z = %Complex{}) do
    divide(log(z), new(:math.log(2.0), 0.0))
  end

  @doc """
  Returns a new complex that is the provided parameter a raised to the
  complex power b.

  ### See also

  `log/1`, `log10/1`

  ### Examples

      iex> Complex.pow(Complex.from_polar(2,:math.pi), Complex.new(0, 1))
      %Complex{im: 0.027612020368333014, re: 0.03324182700885666}

  """
  @spec pow(t | non_finite_number | number, t | non_finite_number | number) ::
          t | non_finite_number | number

  def pow(%Complex{re: re, im: im}, :infinity) when re == 0 and im == 0, do: new(0, 0)

  def pow(%Complex{re: re, im: im}, %Complex{re: :infinity, im: im_r})
      when re == 0 and im == 0 and im_r == 0,
      do: new(0, 0)

  def pow(z, %Complex{}) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(%Complex{}, z) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(%Complex{re: z}, _) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(%Complex{im: z}, _) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(_, %Complex{re: z}) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(_, %Complex{im: z}) when is_non_finite_number(z), do: new(:nan, :nan)
  def pow(:nan, _), do: :nan
  def pow(_, :nan), do: :nan

  def pow(:infinity, y) when is_number(y) and y > 0, do: :infinity
  def pow(:infinity, y) when y == 0, do: 1
  def pow(:infinity, y) when is_number(y) and y < 0, do: 0

  def pow(:neg_infinity, y) when is_number(y) and y > 0 do
    if rem(y, 2) == 0 do
      :infinity
    else
      :neg_infinity
    end
  end

  def pow(:neg_infinity, y) when y == 0, do: 1
  def pow(:neg_infinity, y) when is_number(y) and y < 0, do: 0

  def pow(x, :infinity) when x == 0, do: 0
  def pow(x, :neg_infinity) when x == 0, do: :infinity
  def pow(%Complex{re: re, im: im}, :neg_infinity) when re == 0 and im == 0, do: new(:infinity, 0)
  def pow(_, :neg_infinity), do: 0
  def pow(_, :infinity), do: :infinity

  def pow(x, y) when is_integer(x) and is_integer(y) and y >= 0, do: Integer.pow(x, y)
  def pow(x, y) when is_number(x) and is_number(y), do: :math.pow(x, y)

  def pow(x, y) do
    x = as_complex(x)
    y = as_complex(y)

    cond do
      x.re == 0.0 and x.im == 0.0 ->
        if y.re == 0.0 and y.im == 0.0 do
          new(1.0, 0.0)
        else
          new(0.0, 0.0)
        end

      y.re == 1.0 and y.im == 0.0 ->
        x

      y.re == -1.0 and y.im == 0.0 ->
        divide(new(1.0, 0.0), x)

      true ->
        rho = abs(x)
        theta = phase(x)
        s = multiply(pow(rho, y.re), exp(multiply(negate(y.im), theta)))
        r = add(multiply(y.re, theta), multiply(y.im, log(rho)))
        new(multiply(s, cos(r)), multiply(s, sin(r)))
    end
  end

  @deprecated "Use pow/2 instead"
  def power(x, y), do: pow(x, y)

  @doc """
  Returns a new complex that is the sine of the provided parameter.

  ### See also

  `cos/1`, `tan/1`

  ### Examples

      iex> Complex.sin(Complex.from_polar(2,:math.pi))
      %Complex{im: -1.0192657827055095e-16, re: -0.9092974268256817}

  """
  @spec sin(t | number | non_finite_number) :: t | number | non_finite_number
  def sin(z)

  def sin(n) when is_number(n), do: :math.sin(n)
  def sin(n) when is_non_finite_number(n), do: :nan

  def sin(%Complex{re: re, im: im}) when is_non_finite_number(re) and is_number(im),
    do: Complex.new(:nan, :nan)

  def sin(%Complex{im: :nan}), do: Complex.new(:nan, :nan)
  def sin(%Complex{re: :nan}), do: Complex.new(:nan, :nan)

  def sin(%Complex{re: re, im: im}) when is_number(re) and is_non_finite_number(im) do
    Complex.new(multiply(re, im), im)
  end

  def sin(%Complex{re: re, im: im}) when is_non_finite_number(re) and is_non_finite_number(im) do
    Complex.new(:nan, :nan)
  end

  def sin(z = %Complex{}) do
    new(
      :math.sin(z.re) * :math.cosh(z.im),
      :math.cos(z.re) * :math.sinh(z.im)
    )
  end

  @doc """
  Returns a new complex that is the "negation" of the provided parameter.
  That is, the real and imaginary parts are negated.

  ### See also

  `new/2`

  ### Examples

      iex> Complex.negate(Complex.new(3,5))
      %Complex{im: -5.0, re: -3.0}

  """
  @spec negate(t | number | non_finite_number) :: t | number | non_finite_number
  def negate(z)

  def negate(:nan), do: :nan
  def negate(:neg_infinity), do: :infinity
  def negate(:infinity), do: :neg_infinity
  def negate(n) when is_number(n), do: -n

  def negate(z = %Complex{}) do
    new(negate(z.re), negate(z.im))
  end

  # TO-DO: support non_finite_numbers in inverse trig functions

  @doc """
  Returns a new complex that is the inverse sine (i.e., arcsine) of the
  provided parameter.

  ### See also

  `sin/1`

  ### Examples

      iex> Complex.asin(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.3169578969248164, re: -1.5707963267948966}

  """
  @spec asin(t | number | non_finite_number) :: t | number | non_finite_number
  def asin(z)

  def asin(n) when is_number(n), do: :math.asin(n)

  def asin(n) when is_non_finite_number(n), do: :nan

  def asin(%Complex{re: re, im: im}) when is_non_finite_number(re) or is_non_finite_number(im),
    do: new(:nan, :nan)

  def asin(z = %Complex{}) do
    i = new(0.0, 1.0)
    # result = -i*log(i*z + sqrt(1.0-z*z))
    # result = -i*log(t1 + sqrt(t2))
    t1 = multiply(i, z)
    t2 = subtract(new(1.0, 0.0), multiply(z, z))
    multiply(negate(i), log(add(t1, sqrt(t2))))
  end

  @doc """
  Returns a new complex that is the cosine of the provided parameter.

  ### See also

  `sin/1`, `tan/1`

  ### Examples

      iex> Complex.cos(Complex.from_polar(2,:math.pi))
      %Complex{im: 2.2271363664699914e-16, re: -0.4161468365471424}

  """
  @spec cos(t | number | non_finite_number) :: t | number | non_finite_number
  def cos(z)

  def cos(n) when is_number(n), do: :math.cos(n)

  def cos(n) when is_non_finite_number(n), do: :nan

  def cos(%Complex{re: re, im: im}) when is_non_finite_number(re) and is_number(im),
    do: Complex.new(:nan, :nan)

  def cos(%Complex{im: :nan}), do: Complex.new(:nan, :nan)
  def cos(%Complex{re: :nan}), do: Complex.new(:nan, :nan)

  def cos(%Complex{re: re, im: im}) when is_number(re) and is_non_finite_number(im) do
    Complex.new(:infinity, -1 |> multiply(im) |> multiply(re))
  end

  def cos(%Complex{re: re, im: im}) when is_non_finite_number(re) and is_non_finite_number(im) do
    Complex.new(:nan, :nan)
  end

  def cos(z = %Complex{}) do
    new(
      :math.cos(z.re) * :math.cosh(z.im),
      -:math.sin(z.re) * :math.sinh(z.im)
    )
  end

  @doc """
  Returns a new complex that is the inverse cosine (i.e., arccosine) of the
  provided parameter.

  ### See also

  `cos/1`

  ### Examples

      iex> Complex.acos(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.3169578969248164, re: -3.141592653589793}

  """
  @spec acos(t | number | non_finite_number) :: t | number | non_finite_number
  def acos(z)

  def acos(n) when is_number(n), do: :math.acos(n)

  def acos(n) when is_non_finite_number(n), do: :nan

  def acos(%Complex{re: re, im: im}) when is_non_finite_number(re) or is_non_finite_number(im),
    do: new(:nan, :nan)

  def acos(z = %Complex{}) do
    i = new(0.0, 1.0)
    one = new(1.0, 0.0)
    # result = -i*log(z + sqrt(z*z-1.0))
    # result = -i*log(z + sqrt(t1))
    t1 = subtract(multiply(z, z), one)
    multiply(negate(i), log(add(z, sqrt(t1))))
  end

  @doc """
  Returns a new complex that is the tangent of the provided parameter.

  ### See also

  `sin/1`, `cos/1`

  ### Examples

      iex> Complex.tan(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.4143199004457915e-15, re: 2.185039863261519}

  """
  @spec tan(t | number | non_finite_number) :: t | number | non_finite_number
  def tan(z)

  def tan(n) when is_number(n), do: :math.tan(n)

  def tan(z) do
    divide(sin(z), cos(z))
  end

  @doc """
  Returns a new complex that is the inverse tangent (i.e., arctangent) of the
  provided parameter.

  ### See also

  `tan/1`, `atan2/2`

  ### Examples

      iex> Complex.atan(Complex.from_polar(2,:math.pi))
      %Complex{im: 0.0, re: -1.1071487177940904}

      iex> Complex.tan(Complex.atan(Complex.new(2,3)))
      %Complex{im: 2.9999999999999996, re: 2.0}

  """
  @spec atan(t | number | non_finite_number) :: t | number | non_finite_number
  def atan(z)

  def atan(:infinity), do: :math.pi() / 2
  def atan(:neg_infinity), do: -:math.pi() / 2
  def atan(:nan), do: :nan

  def atan(n) when is_number(n), do: :math.atan(n)

  def atan(z = %Complex{}) do
    i = new(0.0, 1.0)
    # result = 0.5*i*(log(1-i*z)-log(1+i*z))
    t1 = multiply(new(0.5, 0.0), i)
    t2 = subtract(new(1.0, 0.0), multiply(i, z))
    t3 = add(new(1.0, 0.0), multiply(i, z))
    multiply(t1, subtract(log(t2), log(t3)))
  end

  @doc """
  $atan2(b, a)$ returns the phase of the complex number $a + bi$.

  ### See also

  `tan/1`, `atan/1`

  ### Examples

      iex> phase = Complex.atan2(2, 2)
      iex> phase == :math.pi() / 4
      true

      iex> phase = Complex.atan2(2, Complex.new(0))
      iex> phase == Complex.new(:math.pi() / 2, 0)
      true

  """
  def atan2(b, a) when is_number(a) and is_number(b), do: :math.atan2(b, a)
  def atan2(:infinity, :infinity), do: :math.pi() / 4
  def atan2(:infinity, :neg_infinity), do: 3 * :math.pi() / 4
  def atan2(:infinity, :nan), do: :nan
  def atan2(:infinity, a) when is_number(a), do: :math.pi() / 2
  def atan2(:neg_infinity, :infinity), do: -:math.pi() / 4
  def atan2(:neg_infinity, :neg_infinity), do: -3 * :math.pi() / 4
  def atan2(:neg_infinity, :nan), do: :nan
  def atan2(:neg_infinity, a) when is_number(a), do: -:math.pi() / 2
  def atan2(:nan, a) when is_number(a) or is_non_finite_number(a), do: :nan
  def atan2(a, :nan) when is_number(a) or is_non_finite_number(a), do: :nan
  def atan2(:nan, :nan), do: :nan
  def atan2(a, :infinity) when is_number(a), do: 0
  def atan2(a, :neg_infinity) when is_number(a), do: :math.pi()

  def atan2(b, a) do
    a = as_complex(a)
    b = as_complex(b)

    if b.im != 0 or a.im != 0 do
      raise ArithmeticError, "Complex.atan2 only accepts real numbers as arguments"
    end

    b.re
    |> atan2(a.re)
    |> Complex.new()
  end

  @doc """
  Returns a new complex that is the cotangent of the provided parameter.

  ### See also

  `sin/1`, `cos/1`, `tan/1`

  ### Examples

      iex> Complex.cot(Complex.from_polar(2,:math.pi))
      %Complex{im: -2.962299212953233e-16, re: 0.45765755436028577}

  """
  @spec cot(t | number | non_finite_number) :: t | number | non_finite_number
  def cot(z)

  def cot(n) when is_number(n), do: 1 / :math.tan(n)

  def cot(z) do
    divide(cos(z), sin(z))
  end

  @doc """
  Returns a new complex that is the inverse cotangent (i.e., arccotangent) of
  the provided parameter.

  ### See also

  `cot/1`

  ### Examples

      iex> Complex.acot(Complex.from_polar(2,:math.pi))
      %Complex{im: -9.71445146547012e-17, re: -0.46364760900080615}

      iex> Complex.cot(Complex.acot(Complex.new(2,3)))
      %Complex{im: 2.9999999999999996, re: 1.9999999999999993}

  """
  @spec acot(t | number | non_finite_number) :: t | number | non_finite_number
  def acot(z)

  def acot(n) when is_number(n), do: :math.atan(1 / n)

  def acot(:infinity), do: 0
  def acot(:neg_infinity), do: :math.pi()
  def acot(:nan), do: :nan

  def acot(z) do
    i = new(0.0, 1.0)
    # result = 0.5*i*(log(1-i/z)-log(1+i/z))
    t1 = multiply(new(0.5, 0.0), i)
    t2 = subtract(new(1.0, 0.0), divide(i, z))
    t3 = add(new(1.0, 0.0), divide(i, z))
    multiply(t1, subtract(log(t2), log(t3)))
  end

  @doc """
  Returns a new complex that is the secant of the provided parameter.

  ### See also

  `sin/1`, `cos/1`, `tan/1`

  ### Examples

      iex> Complex.sec(Complex.from_polar(2,:math.pi))
      %Complex{im: -1.2860374461837126e-15, re: -2.402997961722381}

  """
  @spec sec(t | number | non_finite_number) :: t | number | non_finite_number
  def sec(z) do
    divide(1, cos(z))
  end

  @doc """
  Returns a new complex that is the inverse secant (i.e., arcsecant) of
  the provided parameter.

  ### See also

  `sec/1`

  ### Examples

      iex> Complex.asec(Complex.from_polar(2,:math.pi))
      %Complex{im: -0.0, re: 2.0943951023931957}

      iex> Complex.sec(Complex.asec(Complex.new(2,3)))
      %Complex{im: 2.9999999999999982, re: 1.9999999999999987}

  """
  @spec asec(t) :: t
  @spec asec(number) :: number
  def asec(z)

  def asec(n) when is_number(n) do
    :math.acos(1 / n)
  end

  def asec(:infinity), do: :math.pi() / 2
  def asec(:neg_infinity), do: 3 * :math.pi() / 2
  def asec(:nan), do: :nan

  def asec(z = %Complex{}) do
    i = new(0.0, 1.0)
    # result = -i*log(i*sqrt(1-1/(z*z))+1/z)
    # result = -i*log(i*sqrt(1-t2)+t1)
    t1 = divide(1, z)
    t2 = square(t1)
    # result = -i*log(i*sqrt(t3)+t1)
    # result = -i*log(t4+t1)
    t3 = subtract(1, t2)
    t4 = multiply(i, sqrt(t3))
    multiply(negate(i), log(add(t4, t1)))
  end

  @doc """
  Returns a new complex that is the cosecant of the provided parameter.

  ### See also

  `sec/1`, `sin/1`, `cos/1`, `tan/1`

  ### Examples

      iex> Complex.csc(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.2327514463765779e-16, re: -1.0997501702946164}

  """
  @spec csc(t) :: t
  @spec csc(number) :: number
  def csc(z) do
    divide(1, sin(z))
  end

  @doc """
  Returns a new complex that is the inverse cosecant (i.e., arccosecant) of
  the provided parameter.

  ### See also

  `sec/1`

  ### Examples

      iex> Complex.acsc(Complex.from_polar(2,:math.pi))
      %Complex{im: 0.0, re: -0.5235987755982988}

      iex> Complex.csc(Complex.acsc(Complex.new(2,3)))
      %Complex{im: 3.0, re: 1.9999999999999993}

  """
  @spec acsc(t | number | non_finite_number) :: t | number | non_finite_number
  def acsc(z)

  def acsc(n) when is_number(n), do: :math.asin(1 / n)
  def acsc(:infinity), do: 0
  def acsc(:neg_infinity), do: -:math.pi()
  def acsc(:nan), do: :nan

  def acsc(z = %Complex{}) do
    i = new(0.0, 1.0)
    one = new(1.0, 0.0)
    # result = -i*log(sqrt(1-1/(z*z))+i/z)
    # result = -i*log(sqrt(1-t2)+t1)
    t1 = divide(i, z)
    t2 = divide(one, multiply(z, z))
    # result = -i*log(sqrt(t3)+t1)
    # result = -i*log(t4+t1)
    t3 = subtract(one, t2)
    t4 = sqrt(t3)
    multiply(negate(i), log(add(t4, t1)))
  end

  @doc """
  Returns a new complex that is the hyperbolic sine of the provided parameter.

  ### See also

  `cosh/1`, `tanh/1`

  ### Examples

      iex> Complex.sinh(Complex.from_polar(2,:math.pi))
      %Complex{im: 9.214721821703068e-16, re: -3.626860407847019}

  """
  @spec sinh(t) :: t
  @spec sinh(number) :: number
  def sinh(z)

  def sinh(n) when is_non_finite_number(n), do: n

  def sinh(n) when is_number(n), do: :math.sinh(n)

  def sinh(z = %Complex{}) do
    %Complex{re: re, im: im} =
      z
      |> exp()
      |> subtract(exp(negate(z)))

    new(divide(re, 2), divide(im, 2))
  end

  @doc """
  Returns a new complex that is the inverse hyperbolic sine (i.e., arcsinh) of
  the provided parameter.

  ### See also

  `sinh/1`

  ### Examples

      iex> Complex.asinh(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.0953573965284052e-16, re: -1.4436354751788099}

      iex> Complex.sinh(Complex.asinh(Complex.new(2,3)))
      %Complex{im: 3.0, re: 2.0000000000000004}

  """
  @spec asinh(t | number | non_finite_number) :: t | number | non_finite_number
  def asinh(z)

  if math_fun_supported?.(:asinh, 1) do
    def asinh(n) when is_number(n) do
      :math.asinh(n)
    end
  else
    def asinh(n) when is_number(n) do
      :math.log(n + :math.sqrt(1 + n * n))
    end
  end

  def asinh(:infinity), do: :infinity
  def asinh(:neg_infinity), do: :neg_infinity
  def asinh(:nan), do: :nan

  def asinh(z) do
    # result = log(z+sqrt(z*z+1))
    # result = log(z+sqrt(t1))
    # result = log(t2)
    t1 = add(multiply(z, z), 1)
    t2 = add(z, sqrt(t1))
    log(t2)
  end

  @doc """
  Returns a new complex that is the hyperbolic cosine of the provided
  parameter.

  ### See also

  `sinh/1`, `tanh/1`

  ### Examples

      iex> Complex.cosh(Complex.from_polar(2,:math.pi))
      %Complex{im: -8.883245978848233e-16, re: 3.7621956910836314}

  """
  @spec cosh(t | number | non_finite_number) :: t | number | non_finite_number

  def cosh(:infinity), do: :infinity
  def cosh(:neg_infinity), do: :infinity
  def cosh(:nan), do: :nan
  def cosh(n) when is_number(n), do: :math.cosh(n)

  def cosh(z) do
    %Complex{re: re, im: im} =
      z
      |> exp()
      |> add(exp(negate(z)))

    new(divide(re, 2), divide(im, 2))
  end

  @doc """
  Returns a new complex that is the inverse hyperbolic cosine (i.e., arccosh)
  of the provided parameter.

  ### See also

  `cosh/1`

  ### Examples

      iex> Complex.acosh(Complex.from_polar(2,:math.pi))
      %Complex{im: -3.141592653589793, re: -1.3169578969248164}

  """
  @spec acosh(t | number | non_finite_number) :: t | number | non_finite_number
  def acosh(z)

  if math_fun_supported?.(:acosh, 1) do
    def acosh(n) when is_number(n), do: :math.acosh(n)
  else
    def acosh(n) when is_number(n) do
      :math.log(n + :math.sqrt(n * n - 1))
    end
  end

  def acosh(:infinity), do: :infinity

  def acosh(:neg_infinity),
    do: raise(ArithmeticError, "Complex.acosh(:neg_infinity) is undefined")

  def acosh(:nan), do: :nan

  def acosh(z) do
    # result = log(z+sqrt(z*z-1))
    # result = log(z+sqrt(t1))
    # result = log(t2)
    t1 = subtract(multiply(z, z), 1)
    t2 = add(z, sqrt(t1))
    log(t2)
  end

  @doc """
  Returns a new complex that is the hyperbolic tangent of the provided
  parameter.

  ### See also

  `sinh/1`, `cosh/1`

  ### Examples

      iex> Complex.tanh(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.7304461302709575e-17, re: -0.9640275800758169}

  """
  @spec tanh(t | number | non_finite_number) :: t | number | non_finite_number
  def tanh(z)

  def tanh(n) when is_number(n), do: :math.tanh(n)

  def tanh(z) do
    divide(sinh(z), cosh(z))
  end

  @doc """
  Returns a new complex that is the inverse hyperbolic tangent (i.e., arctanh)
  of the provided parameter.

  ### See also

  `tanh/1`

  ### Examples

      iex> Complex.atanh(Complex.from_polar(2,:math.pi))
      %Complex{im: 1.5707963267948966, re: -0.5493061443340549}

      iex> Complex.tanh(Complex.atanh(Complex.new(2,3)))
      %Complex{im: 3.0, re: 1.9999999999999993}

  """
  @spec atanh(t | number | non_finite_number) :: t | number | non_finite_number
  def atanh(z)

  if math_fun_supported?.(:atanh, 1) do
    def atanh(n) when is_number(n), do: :math.atanh(n)
  else
    def atanh(n) when is_number(n) do
      0.5 * :math.log((1 + n) / (1 - n))
    end
  end

  def atanh(z) do
    one = new(1.0, 0.0)
    p5 = new(0.5, 0.0)
    # result = 0.5*(log((1+z)/(1-z)))
    # result = 0.5*(log(t2/t1))
    # result = 0.5*(log(t3))
    t1 = subtract(one, z)
    t2 = add(one, z)
    t3 = divide(t2, t1)
    multiply(p5, log(t3))
  end

  @doc """
  Returns a new complex that is the hyperbolic secant of the provided
  parameter.

  ### See also

  `sinh/1`, `cosh/1`, `tanh/1`

  ### Examples

      iex> Complex.sech(Complex.from_polar(2,:math.pi))
      %Complex{im: 6.27608655779184e-17, re: 0.26580222883407967}

  """
  @spec sech(t | number | non_finite_number) :: t | number | non_finite_number
  def sech(z) do
    divide(1, cosh(z))
  end

  @doc """
  Returns a new complex that is the inverse hyperbolic secant (i.e., arcsech)
  of the provided parameter.

  ### See also

  `sech/1`

  ### Examples

      iex> Complex.asech(Complex.from_polar(2,:math.pi))
      %Complex{im: -2.0943951023931953, re: 0.0}

      iex> Complex.sech(Complex.asech(Complex.new(2,3)))
      %Complex{im: 2.999999999999999, re: 2.0}

  """
  @spec asech(t | number | non_finite_number) :: t | number | non_finite_number
  def asech(z) do
    # result = log(1/z+sqrt(1/z+1)*sqrt(1/z-1))
    # result = log(t1+sqrt(t1+1)*sqrt(t1-1))
    # result = log(t1+t2*t3)
    t1 = divide(1, z)
    t2 = sqrt(add(t1, 1))
    t3 = sqrt(subtract(t1, 1))
    log(add(t1, multiply(t2, t3)))
  end

  @doc """
  Returns a new complex that is the hyperbolic cosecant of the provided
  parameter.

  ### See also

  `sinh/1`, `cosh/1`, `tanh/1`

  ### Examples

      iex> Complex.csch(Complex.from_polar(2,:math.pi))
      %Complex{im: -7.00520014334671e-17, re: -0.2757205647717832}

  """
  @spec csch(t | number | non_finite_number) :: t | number | non_finite_number
  def csch(z), do: divide(1, sinh(z))

  @doc """
  Returns a new complex that is the inverse hyperbolic cosecant (i.e., arccsch)
  of the provided parameter.

  ### See also

  `csch/1`

  ### Examples

      iex> Complex.acsch(Complex.from_polar(2,:math.pi))
      %Complex{im: -5.4767869826420256e-17, re: -0.48121182505960336}

      iex> Complex.csch(Complex.acsch(Complex.new(2,3)))
      %Complex{im: 3.0000000000000018, re: 1.9999999999999984}

  """
  @spec acsch(t | number | non_finite_number) :: t | number | non_finite_number
  def acsch(z) do
    # result = log(1/z+sqrt(1/(z*z)+1))
    # result = log(t1+sqrt(t2+1))
    # result = log(t1+t3)
    t1 = divide(1, z)
    t2 = divide(1, multiply(z, z))
    t3 = sqrt(add(t2, 1))
    log(add(t1, t3))
  end

  @doc """
  Returns a new complex that is the hyperbolic cotangent of the provided
  parameter.

  ### See also

  `sinh/1`, `cosh/1`, `tanh/1`

  ### Examples

      iex> Complex.coth(Complex.from_polar(2,:math.pi))
      %Complex{im: -1.8619978115303644e-17, re: -1.037314720727548}

  """
  @spec coth(t | number | non_finite_number) :: t | number | non_finite_number
  def coth(z) do
    divide(cosh(z), sinh(z))
  end

  @doc """
  Returns a new complex that is the inverse hyperbolic cotangent (i.e., arccoth)
  of the provided parameter.

  ### See also

  `coth/1`

  ### Examples

      iex> Complex.acoth(Complex.from_polar(2,:math.pi))
      %Complex{im: -8.164311994315688e-17, re: -0.5493061443340548}

      iex> Complex.coth(Complex.acoth(Complex.new(2,3)))
      %Complex{im: 2.999999999999998, re: 2.000000000000001}

  """
  @spec acoth(t | number | non_finite_number) :: t | number | non_finite_number
  def acoth(z) do
    # result = 0.5*(log(1+1/z)-log(1-1/z))
    # result = 0.5*(log(1+t1)-log(1-t1))
    # result = 0.5*(log(t2)-log(t3))
    t1 = divide(1, z)
    t2 = add(1, t1)
    t3 = subtract(1, t1)
    multiply(0.5, subtract(log(t2), log(t3)))
  end

  @doc ~S"""
  Calculates $erf(z)$ of the argument, as defined by:

  $$erf(z) = \frac{2}{\sqrt{\pi}} \int_{0}^{z} e^{-t^2}$$

  ### Examples

      iex> x = Complex.erf(0.5)
      iex> Float.round(x, 5)
      0.52050

      iex> z = Complex.erf(Complex.new(-0.5))
      iex> z.im
      0.0
      iex> Float.round(z.re, 5)
      -0.52050

      iex> Complex.erf(Complex.new(1, 1))
      ** (ArithmeticError) erf not implemented for non-real numbers

  """
  @spec erf(t | number | non_finite_number) :: t | number | non_finite_number

  if math_fun_supported?.(:erf, 1) do
    def erf(x) when is_number(x) do
      :math.erf(x)
    end
  else
    def erf(x) when is_number(x) do
      x = x |> max(-4.0) |> min(4.0)
      x2 = x * x

      alpha =
        0.0
        |> muladd(x2, -2.72614225801306e-10)
        |> muladd(x2, 2.77068142495902e-08)
        |> muladd(x2, -2.10102402082508e-06)
        |> muladd(x2, -5.69250639462346e-05)
        |> muladd(x2, -7.34990630326855e-04)
        |> muladd(x2, -2.95459980854025e-03)
        |> muladd(x2, -1.60960333262415e-02)

      beta =
        0.0
        |> muladd(x2, -1.45660718464996e-05)
        |> muladd(x2, -2.13374055278905e-04)
        |> muladd(x2, -1.68282697438203e-03)
        |> muladd(x2, -7.37332916720468e-03)
        |> muladd(x2, -1.42647390514189e-02)

      min(x * alpha / beta, 1.0)
    end
  end

  def erf(:infinity), do: 1
  def erf(:neg_infinity), do: -1
  def erf(:nan), do: :nan

  def erf(%Complex{re: re, im: im}) do
    if im != 0 do
      raise ArithmeticError, "erf not implemented for non-real numbers"
    end

    Complex.new(erf(re))
  end

  @doc ~S"""
  Calculates $erfc(z)$ of the argument, as defined by:

  $$erfc(z) = 1 - erf(z)$$

  ### Examples

      iex> x = Complex.erfc(0.5)
      iex> Float.round(x, 5)
      0.47950

      iex> z = Complex.erfc(Complex.new(-0.5))
      iex> z.im
      0.0
      iex> Float.round(z.re, 5)
      1.52050

      iex> Complex.erfc(Complex.new(1, 1))
      ** (ArithmeticError) erfc not implemented for non-real numbers

  """
  @spec erfc(t | number | non_finite_number) :: t | number | non_finite_number
  def erfc(z)

  if math_fun_supported?.(:erfc, 1) do
    def erfc(z) when is_number(z), do: :math.erfc(z)
  end

  def erfc(z) do
    if is_struct(z, Complex) and z.im != 0 do
      raise ArithmeticError, "erfc not implemented for non-real numbers"
    end

    subtract(1, erf(z))
  end

  @doc ~S"""
  Calculates $erf^-1(z)$ of the argument, as defined by:

  $$erf(erf^-1(z)) = z$$

  ### Examples

      iex> Complex.erf_inv(0.5204998778130465)
      0.5000000069276399

      iex> Complex.erf_inv(Complex.new(-0.5204998778130465))
      %Complex{im: 0.0, re: -0.5000000069276399}

      iex> Complex.erf_inv(Complex.new(1, 1))
      ** (ArithmeticError) erf_inv not implemented for non-real numbers

  """
  @spec erf_inv(t | number | non_finite_number) :: t | number | non_finite_number
  def erf_inv(z) when is_number(z) do
    cond do
      z == 1 ->
        :infinity

      z == -1 ->
        :neg_infinity

      z == 0 ->
        0

      :otherwise ->
        w = -:math.log((1 - z) * (1 + z))
        erf_inv_p(w) * z
    end
  end

  def erf_inv(n) when is_non_finite_number(n), do: :nan

  def erf_inv(%Complex{re: re, im: im}) do
    if im != 0 do
      raise ArithmeticError, "erf_inv not implemented for non-real numbers"
    end

    Complex.new(erf_inv(re))
  end

  defp erf_inv_p(w) when w < 5 do
    w = w - 2.5

    2.81022636e-08
    |> muladd(w, 3.43273939e-07)
    |> muladd(w, -3.5233877e-06)
    |> muladd(w, -4.39150654e-06)
    |> muladd(w, 0.00021858087)
    |> muladd(w, -0.00125372503)
    |> muladd(w, -0.00417768164)
    |> muladd(w, 0.246640727)
    |> muladd(w, 1.50140941)
  end

  defp erf_inv_p(w) do
    w = :math.sqrt(w) - 3

    -0.000200214257
    |> muladd(w, 0.000100950558)
    |> muladd(w, 0.00134934322)
    |> muladd(w, -0.00367342844)
    |> muladd(w, 0.00573950773)
    |> muladd(w, -0.0076224613)
    |> muladd(w, 0.00943887047)
    |> muladd(w, 1.00167406)
    |> muladd(w, 2.83297682)
  end

  defp muladd(acc, t, n) do
    acc * t + n
  end

  defp as_complex(%Complex{} = x), do: x
  defp as_complex(x) when is_number(x), do: new(x)
  defp as_complex(x) when x in @non_finite_numbers, do: new(x)

  defp as_float(:infinity), do: :infinity
  defp as_float(:neg_infinity), do: :neg_infinity
  defp as_float(:nan), do: :nan
  defp as_float(n), do: 1.0 * n
end
