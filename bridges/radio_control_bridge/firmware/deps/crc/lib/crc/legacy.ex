defmodule CRC.Legacy do
    @moduledoc false

    # Legacy CRC functions, these may be depraced in a future release and removed in v1.0 - RN
    defmacro __using__(_) do
        quote do
            @doc """
            Calculates a 8-bit CRC with polynomial x^8+x^6+x^3+x^2+1, 0x14D.
            Chosen based on Koopman, et al. (0xA6 in his notation = 0x14D >> 1):
            http://www.ece.cmu.edu/~koopman/roses/dsn04/koopman04_crc_poly_embedded.pdf

            seed defaults to 0xFF if one is not given
            """
            @spec crc_8(binary, number) :: number
            defdelegate crc_8(input, seed \\ 0xFF), to: :crc

            @doc """
            Calculates a 16-bit ANSI CRC checksum for the provided binary
            """
            @spec crc_16(binary) :: number
            def crc_16(input), do: :crc_fast.calc(:crc_16, input)

            @doc """
            Calculates a 16-bit CCITT CRC with the given seed,
            seed defaults to 0xFFFF if one is not given.

            This CCIT method uses a 0x1021 polynomial.
            """
            @spec ccitt_16(binary) :: number
            def ccitt_16(input), do: :crc_fast.calc(:crc_16_ccitt_false, input)

            @spec ccitt_16(binary, number) :: number
            def ccitt_16(input, seed) do
                extend_model_seed(:crc_16_ccitt_false, seed)
                |> :crc_fast.calc(input)
            end

            @doc """
            Calculates a 16-bit CCITT Kermit CRC

            This CCIT method uses a 0x8408 polynomial.
            """
            @spec ccitt_16_kermit(binary) :: number
            def ccitt_16_kermit(input), do: :crc_fast.calc(:crc_16_kermit, input)
            @spec ccitt_16_kermit(binary, number) :: number
            def ccitt_16_kermit(input, seed) do
                extend_model_seed(:crc_16_kermit, seed)
                |> :crc_fast.calc(input)
            end

            @doc """
            Calculates a 16-bit CCITT XMODEM CRC

            This CCIT method uses a 0x1021 polynomial.
            """
            @spec ccitt_16_xmodem(binary) :: number
            def ccitt_16_xmodem(input), do: :crc_fast.calc(:xmodem, input)

            @doc """
            Calculates a 16-bit CCITT 0x1D0F CRC

            This CCIT method uses a 0x1021 polynomial.
            """
            @spec ccitt_16_1D0F(binary) :: number
            def ccitt_16_1D0F(input) do
                extend_model_seed(:crc_16_ccitt_false, 0x1D0F)
                |> :crc_fast.calc(input)
            end

            @doc """
            Calculates a 16-bit modbus CRC
            """
            @spec crc_16_modbus(binary) :: number
            def crc_16_modbus(input), do: :crc_fast.calc(:crc_16_modbus, input)

            @doc """
            Calculates a 16-bit Sick CRC
            """
            @spec crc_16_sick(binary) :: number
            def crc_16_sick(input), do: :crc_fast.calc(:crc_16_sick, input)

            @doc """
            Calculates a 16-bit DNP CRC
            """
            @spec crc_16_dnp(binary) :: number
            def crc_16_dnp(input), do: :crc_fast.calc(:crc_16_dnp, input)

            @doc """
            Calculates a 32-bit CRC
            """
            @spec crc_32(binary) :: number
            def crc_32(input), do: :crc_fast.calc(:crc_32, input)

            @doc """
            Calculates an XOR checksum for the given binary
            """
            @spec checksum_xor(binary) :: number
            defdelegate checksum_xor(input), to: :crc

            defp extend_model_seed(model, seed), do: %{extend: model, init: seed}
        end
    end
end