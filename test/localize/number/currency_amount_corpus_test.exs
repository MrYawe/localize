defmodule Localize.Number.CurrencyAmountCorpusTest do
  @moduledoc """
  Runs every row of `test/support/data/currency_amount_corpus.tsv` through
  `Localize.Number.Parser.parse_currency_amount/2`.

  A row that reads a different amount from the one expected always fails,
  as does an expected refusal that reads. A row marked "gap" must still be
  refused, so the marker is removed once the parser reads it.

  """

  use ExUnit.Case, async: true

  alias Localize.Number.Parser

  @corpus Path.expand("../../support/data/currency_amount_corpus.tsv", __DIR__)
  @external_resource @corpus

  @rows @corpus
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&String.split(&1, "\t"))

  defp unescape(text) do
    Regex.replace(~r/\\u\{([0-9A-Fa-f]{4,6})\}/, text, fn _match, hex ->
      <<String.to_integer(hex, 16)::utf8>>
    end)
  end

  defp expected("refuse") do
    :refuse
  end

  defp expected(text) do
    [currency, amount] = String.split(text, " ", parts: 2)
    {currency, Decimal.new(amount)}
  end

  defp read(locale, input, given_currency) do
    case Parser.parse_currency_amount(unescape(input), read_options(locale, given_currency)) do
      {:ok, {currency, amount}} -> {Atom.to_string(currency), amount}
      {:error, _reason} -> :refuse
    end
  end

  defp read_options(locale, "") do
    [locale: locale]
  end

  defp read_options(locale, given_currency) do
    [locale: locale, default_currency: given_currency]
  end

  defp same?(:refuse, :refuse) do
    true
  end

  defp same?({currency, this}, {currency, that}) do
    Decimal.equal?(this, that)
  end

  defp same?(_this, _that) do
    false
  end

  for [locale, input, expected, status, source | rest] <- @rows do
    given_currency = Enum.at(rest, 2, "")

    test "#{locale} #{inspect(input)} #{given_currency} (#{source})" do
      expected = expected(unquote(expected))
      result = read(unquote(locale), unquote(input), unquote(given_currency))

      if unquote(status) == "gap" do
        assert result == :refuse,
               "now reads #{inspect(result)}, expected #{inspect(expected)}: drop the gap marker"
      else
        assert same?(result, expected), "read #{inspect(result)}, expected #{inspect(expected)}"
      end
    end
  end
end
