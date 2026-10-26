defmodule Localize.Number.RoundingPriorityIntlTest do
  @moduledoc """
  Significant and fraction digits under each rounding priority, in the
  standard, percent, currency and compact formats, against ECMA-402's
  `Intl.NumberFormat`.

  TR35 does not say how significant and fraction digit bounds combine, so
  ECMA-402 is followed: under `:auto` a significant-digit bound wins
  outright; under `:more_precision` and `:less_precision` both bounds take
  part, a bound not given taking its style's default, and the more or less
  precise one applies. Expected strings come from `Intl.NumberFormat` in
  Node 24, for every combination in the fixture's two grids
  (https://github.com/elixir-localize/localize/issues/66).

  """

  use ExUnit.Case, async: true

  @fixture Path.expand("../../support/data/number_rounding_priority_intl_expected.tsv", __DIR__)
  @external_resource @fixture

  @rows @fixture
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&String.split(&1, "\t"))

  @priorities %{
    "auto" => :auto,
    "morePrecision" => :more_precision,
    "lessPrecision" => :less_precision
  }

  @rounding_modes %{"halfExpand" => :half_up, "halfEven" => :half_even}

  test "the fixture has both grids" do
    assert Enum.count(@rows) == 11_392
  end

  test "every combination formats as Intl.NumberFormat does" do
    mismatches =
      for [value, notation, style, max_sd, min_sd, max_fd, min_fd, priority, mode, expected] <-
            @rows,
          expected = unescape(expected),
          # Localize writes a negative number that rounds to zero without its
          # sign under `:auto` sign display ("0", not "-0"), by decision; see
          # `Localize.Number.Formatter.Decimal`.
          not negative_zero?(expected),
          options =
            format_options(notation, style) ++
              [rounding_priority: @priorities[priority], rounding_mode: @rounding_modes[mode]] ++
              digit_option(:maximum_significant_digits, max_sd) ++
              digit_option(:minimum_significant_digits, min_sd) ++
              digit_option(:max_fractional_digits, max_fd) ++
              digit_option(:min_fractional_digits, min_fd),
          result = Localize.Number.to_string(Decimal.new(value), options),
          result != {:ok, expected} do
        {value, options, result, expected}
      end

    assert Enum.take(mismatches, 20) == [],
           "#{length(mismatches)} combinations differ from Intl.NumberFormat"
  end

  defp format_options("standard", "decimal"), do: [format: :standard]
  defp format_options("standard", "percent"), do: [format: :percent]
  defp format_options("standard", "currency"), do: [format: :currency, currency: :USD]
  defp format_options("compact", "decimal"), do: [format: :short]
  defp format_options("compact", "currency"), do: [format: :short, currency: :USD]

  defp digit_option(_option, ""), do: []
  defp digit_option(option, digits), do: [{option, String.to_integer(digits)}]

  defp negative_zero?(string) do
    String.starts_with?(string, "-") and String.trim_leading(string, "-") in ["0", "$0"]
  end

  defp unescape(string) do
    Regex.replace(~r/\\u\{([0-9A-F]+)\}/, string, fn _match, hex ->
      <<String.to_integer(hex, 16)::utf8>>
    end)
  end
end
