defmodule Localize.Number.CurrencyAmountTest do
  use ExUnit.Case, async: true

  alias Localize.Number.Parser

  defp amount(string, options \\ []) do
    options = Keyword.put_new(options, :locale, :en)

    case Parser.parse_currency_amount(string, options) do
      {:ok, {currency, decimal}} -> {currency, Decimal.to_string(decimal, :normal)}
      {:error, exception} -> exception
    end
  end

  # Every amount ex_money's own parser reads in its test suite, which
  # `Money.parse/2` moves onto this function in ex_money 6.3.0. These are a
  # compatibility contract: change one only with ex_money in step.
  describe "ex_money's parse cases" do
    test "a currency code before the amount" do
      assert {:USD, "100"} = amount("USD 100")
      assert {:USD, "100"} = amount("USD100")
      assert {:USD, "100"} = amount("USD 100 ")
      assert {:USD, "100"} = amount("USD100 ")
      assert {:USD, "100.00"} = amount("USD 100.00")
      assert {:USD, "1"} = amount("USD 1")
      assert {:USD, "9"} = amount("USD9")
    end

    test "a currency code after the amount" do
      assert {:USD, "100"} = amount("100 USD")
      assert {:USD, "100"} = amount("100USD")
      assert {:USD, "100"} = amount("100 USD ")
      assert {:USD, "100.00"} = amount("100.00USD")
    end

    test "a currency name" do
      assert {:AUD, "12346.45"} = amount("australian dollar 12346.45")
      assert {:AUD, "12346.45"} = amount("12346.45 australian dollars")
      assert {:AUD, "12346.45"} = amount("12346.45 Australian Dollars")
      assert {:AUD, "12346"} = amount("12 346 dollar australien", locale: :fr)
      assert {:FRF, "100"} = amount("100 French francs")
    end

    test "the locale's separators and symbols" do
      assert {:USD, "100.00"} = amount("100,00USD", locale: :de)
      assert {:EUR, "99.99"} = amount("99.99€")
      assert {:EUR, "1127.54"} = amount("1.127,54 €", locale: :de)
      assert {:EUR, "1127.54"} = amount("1 127,54 €", locale: :fr)
      assert {:EUR, "1127.54"} = amount("1 127,54 €", locale: :fr)
      assert {:DKK, "4200.00"} = amount("4.200,00 kr.", locale: :da)
      assert {:MAD, "1234.56"} = amount("‏1.234,56 د.م.‏", locale: :"ar-MA")

      assert {:USD, "30000.00"} =
               amount("US$30 000,00", locale: :"en-ZA", separators: :standard)
    end

    test "a sign before, between or after" do
      assert {:EUR, "-127.54"} = amount("-127,54 €", locale: :fr)
      assert {:EUR, "-127.54"} = amount("-127,54€", locale: :fr)
      assert {:EUR, "-127.54"} = amount("€ 127,54-", locale: :nl)
      assert {:EUR, "-127.54"} = amount("€127,54-", locale: :nl)
      assert {:CHF, "-127.54"} = amount("CHF -127.54", locale: :"de-CH")
      assert {:CHF, "-127.54"} = amount("-127.54 CHF", locale: :"de-CH")
      assert {:DKK, "-127.54"} = amount("kr-127,54", locale: :da)
      assert {:DKK, "-127.54"} = amount("kr -127,54", locale: :da)
    end

    test "accounting parentheses negate the amount inside them" do
      assert {:USD, "-127.54"} = amount("($127.54)")
      assert {:USD, "127.54"} = amount("($-127.54)")
    end

    test "currency filters and fuzzy matching" do
      assert %Localize.UnknownCurrencyError{currency: "French francs"} =
               amount("100 French francs", only: [:current])

      assert {:EUR, "100"} = amount("100 eurosports", fuzzy: 0.8)

      assert %Localize.UnknownCurrencyError{currency: "eurosports"} =
               amount("100 eurosports", fuzzy: 0.9)
    end

    test "a default currency" do
      assert {:USD, "100"} = amount("100", default_currency: :USD)
      assert {:USD, "100"} = amount("100", default_currency: "USD")
      assert {:AUD, "100"} = amount("100", default_currency: "australian dollars")
      assert {:EUR, "100"} = amount("EUR 100", default_currency: :USD)
    end

    test "a caller's own currencies" do
      token = fn text ->
        if String.downcase(text) in ["btc", "bitcoin"] do
          {:ok, "BTC"}
        else
          :error
        end
      end

      assert {"BTC", "100"} = amount("100 BTC", unknown_currency: token)
      assert {"BTC", "100"} = amount("100 Bitcoin", unknown_currency: token)
      assert {"BTC", "100"} = amount("BTC 100", unknown_currency: token)
      assert {"BTC", "100"} = amount("Bitcoin 100", unknown_currency: token)

      assert %Localize.UnknownCurrencyError{currency: "Dogecoin"} =
               amount("100 Dogecoin", unknown_currency: token)
    end
  end

  describe "what Localize formats" do
    test "a currency's own separators" do
      assert {:CHF, "1234.56"} = amount("1’234.56 CHF", locale: :"fr-CH")
      assert {:CHF, "1234.56"} = amount("1'234.56 CHF", locale: :"fr-CH")
      assert {:EUR, "1234.56"} = amount("€ 1.234,56", locale: :"de-AT")
    end

    test "signs and bidi controls" do
      assert {:CHF, "-1234.56"} = amount("-CHF 1,234.56")
      assert {:USD, "-127.54"} = amount("-$127.54")
      assert {:SEK, "-1234.56"} = amount("−1 234,56 kr", locale: :sv)
      assert {:EGP, "-1234.56"} = amount("(؜1,234.56 ج.م.‏)", locale: :ar)

      assert {:EGP, "-1234.56"} =
               amount("؜-‏١٬٢٣٤٫٥٦ ج.م.‏", locale: :"ar-EG")
    end

    test "round trips" do
      for locale <- [:en, :de, :fr, :"de-CH", :"fr-CH", :sv, :da, :nl, :ar, :"ar-EG", :hi],
          amount <- ["1234.56", "-1234.56"],
          format <- [:currency, :accounting] do
        {:ok, currency} = Localize.Currency.currency_from_locale(locale)
        decimal = Decimal.new(amount)

        {:ok, string} =
          Localize.Number.to_string(decimal, locale: locale, currency: currency, format: format)

        assert {:ok, {^currency, parsed}} = Parser.parse_currency_amount(string, locale: locale)
        assert Decimal.equal?(parsed, decimal), "#{locale} #{format} #{inspect(string)}"
      end
    end

    test "a zero fraction written as a dash" do
      assert {:CHF, "5"} = amount("CHF 5.–", locale: :"de-CH")
      assert {:CHF, "5"} = amount("Fr. 5.—", locale: :"de-CH")
      assert {:EUR, "5"} = amount("€ 5,-", locale: :nl)
      assert {:EUR, "-5"} = amount("-€ 5,-", locale: :nl)
      assert {:EUR, "-127.54"} = amount("€ 127,54-", locale: :nl)
    end

    test "a sentence's closing period after the currency" do
      assert {:USD, "100"} = amount("100 USD.")
    end
  end

  describe "errors" do
    test "no currency and no default" do
      assert %Localize.ParseError{reason: :missing_currency, input: "100"} = amount("100")
    end

    test "text that is not one currency amount" do
      for string <- [
            "USD 100 with trailing text",
            "USD 100 EUR",
            "--5 USD",
            "-+5 USD",
            "(5 USD",
            "5 USD)",
            ")5 USD(",
            "((5 USD))",
            "5 USD 6",
            "USD",
            "",
            "   "
          ] do
        assert %Localize.ParseError{reason: :unexpected_input} = amount(string),
               inspect(string)
      end
    end

    test "invalid arguments and options" do
      assert {:error, _} = Parser.parse_currency_amount(nil)
      assert {:error, _} = Parser.parse_currency_amount(:"")
      assert {:error, _} = Parser.parse_currency_amount(100)
      assert {:error, _} = Parser.parse_currency_amount("USD 100", :not_a_list)
      assert {:error, _} = Parser.parse_currency_amount("USD 100", locale: "xx-invalid-!!")
      assert {:error, _} = Parser.parse_currency_amount("100 eurosports", fuzzy: 2.0)
      assert {:error, _} = Parser.parse_currency_amount("100", default_currency: 12)
      assert {:error, _} = Parser.parse_currency_amount("100 BTC", unknown_currency: :nope)
    end

    test "an over-long string" do
      string = "USD " <> String.duplicate("1", Parser.max_number_bytes())

      assert {:error, %Localize.ParseError{reason: :input_too_large}} =
               Parser.parse_currency_amount(string)
    end
  end
end
