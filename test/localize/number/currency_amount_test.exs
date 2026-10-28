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

    # ex_money read "($-127.54)" as 127.54 dollars, where others read it as
    # -127.54: it is refused.
    test "accounting parentheses negate the amount inside them" do
      assert {:USD, "-127.54"} = amount("($127.54)")
      assert %Localize.InvalidAmountError{amount: "(-127.54)"} = amount("($-127.54)")
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

      assert {"BTC", "100"} = amount("100 BTC", caller_currency: token)
      assert {"BTC", "100"} = amount("100 Bitcoin", caller_currency: token)
      assert {"BTC", "100"} = amount("BTC 100", caller_currency: token)
      assert {"BTC", "100"} = amount("Bitcoin 100", caller_currency: token)

      assert %Localize.UnknownCurrencyError{currency: "Dogecoin"} =
               amount("100 Dogecoin", caller_currency: token)
    end

    test "text that names a CLDR currency and a different one of the caller's is refused" do
      caller = fn text ->
        case text do
          "₮" -> {:ok, "USDT"}
          "MNT" -> {:ok, :MNT}
          _other -> :error
        end
      end

      assert {:MNT, "5"} = amount("₮5")

      assert %Localize.ParseError{reason: :unexpected_input, detail: detail} =
               amount("₮5", caller_currency: caller)

      assert detail =~ "two currencies"
      assert {:MNT, "5"} = amount("MNT 5", caller_currency: caller)
      assert {:USD, "5"} = amount("5 USD", caller_currency: caller)
    end

    # A caller's currency has no separators in CLDR, so its amount is read
    # with the locale's and the root locale's, the form ex_money writes a
    # token amount in, and refused where the two differ.
    test "a caller's currency is read with the locale's separators and the root's" do
      token = fn text ->
        if text in ["BTC", "₿"] do
          {:ok, "BTC"}
        else
          :error
        end
      end

      for {string, locale, value} <- [
            {"₿1.234", :en, "1.234"},
            {"₿1.234", :fr, "1.234"},
            {"₿1234.56", :de, "1234.56"},
            {"₿0.00012345", :de, "0.00012345"},
            {"1,5 BTC", :de, "1.5"},
            {"1,234.56 BTC", :de, "1234.56"},
            {"₿.5", :de, "0.5"}
          ] do
        assert {"BTC", ^value} = amount(string, locale: locale, caller_currency: token),
               "#{locale} #{inspect(string)}"
      end

      for string <- ["₿1.234", "1,234 BTC"] do
        assert %Localize.InvalidAmountError{cause: %Localize.ParseError{detail: detail}} =
                 amount(string, locale: :de, caller_currency: token)

        assert detail =~ "ambiguous"
      end
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

    test "a decimal mark that opens or closes the number" do
      assert {:USD, "0.5"} = amount(".5 USD")
      assert {:USD, "0.5"} = amount("USD .5")
      assert {:USD, "-0.5"} = amount("-.5 USD")
      assert {:USD, "5"} = amount("5. USD")
      assert {:USD, "5"} = amount("5.USD")
      assert {:USD, "5"} = amount("USD 5.")
      assert {:EUR, "0.5"} = amount("€ ,5", locale: :de)
    end

    test "a grouping separator that opens or closes the number is refused" do
      assert %Localize.InvalidAmountError{amount: ".5"} = amount("€ .5", locale: :de)
      assert %Localize.InvalidAmountError{amount: "5."} = amount("5. €", locale: :de)
      assert %Localize.InvalidAmountError{amount: ",5"} = amount(",5 USD")
    end

    # A mark between the currency and the digits is the currency's when CLDR
    # writes the currency with it, the number's when it is the decimal mark,
    # and refused otherwise. Before this "$.50" read as fifty dollars.
    test "a mark CLDR writes with the currency stays with it" do
      assert {:CHF, "5"} = amount("Fr.5", locale: :"de-CH")
      assert {:DKK, "5"} = amount("kr.5", locale: :da)
    end

    test "a decimal mark touching the currency belongs to the number" do
      assert {:USD, "0.50"} = amount("$.50")
      assert {:USD, "0.50"} = amount("USD.50")
      assert {:USD, "-0.50"} = amount("($.50)")
      assert {:EUR, "0.5"} = amount("€,5", locale: :de)
      assert {:BRL, "0.5"} = amount("R$,5", locale: :"pt-BR")
    end

    test "any other mark touching the currency is ambiguous and refused" do
      for {string, locale} <- [{"kr.5", :nb}, {"€.5", :de}, {"R$.5", :"pt-BR"}] do
        assert %Localize.ParseError{reason: :unexpected_input} = amount(string, locale: locale),
               "#{locale} #{inspect(string)}"
      end
    end

    test "a zero fraction written as a dash" do
      for locale <- [:"de-CH", :"fr-CH", :"it-CH"],
          {string, expected} <- [
            {"CHF 5.-", "5"},
            {"CHF 5.–", "5"},
            {"5.– CHF", "5"},
            {"Fr. 5.-", "5"},
            {"Fr. 5.--", "5"},
            {"CHF 1'234.–", "1234"},
            {"CHF -5.-", "-5"},
            {"(CHF 5.-)", "-5"}
          ] do
        assert {:CHF, ^expected} = amount(string, locale: locale), "#{locale} #{inspect(string)}"
      end

      assert {:CHF, "5"} = amount("Fr. 5.—", locale: :"de-CH")
      assert {:EUR, "5"} = amount("€ 5,-", locale: :nl)
      assert {:EUR, "-5"} = amount("-€ 5,-", locale: :nl)
      assert {:EUR, "-127.54"} = amount("€ 127,54-", locale: :nl)
    end

    # An amount that could be two amounts is refused, never guessed.
    test "a group the locale does not write is refused" do
      assert %Localize.InvalidAmountError{amount: "1.23"} = amount("1.23 EUR", locale: :de)
      assert %Localize.InvalidAmountError{amount: "1,23"} = amount("1,23 USD")
      assert {:INR, "1234567"} = amount("1,234,567 INR", locale: :"en-IN")
      assert {:INR, "1234567"} = amount("₹12,34,567", locale: :"en-IN")
    end

    test "de-AT and fr-CH amounts read with either set of separators" do
      assert {:EUR, "1234.56"} = amount("€ 1.234,56", locale: :"de-AT")
      assert {:EUR, "1234.56"} = amount("1\u00A0234,56 EUR", locale: :"de-AT")
      assert {:CHF, "1234.56"} = amount("1'234,56 CHF", locale: :"fr-CH")
      assert {:CHF, "1234.56"} = amount("1'234.56 CHF", locale: :"fr-CH")
      assert {:CHF, "100.00"} = amount("100,00 CHF", locale: :"fr-CH")
      assert {:CHF, "0.5"} = amount("CHF,5", locale: :"fr-CH")
    end

    # Both of `de-AT`'s sets mark the fraction with a comma, so a period is
    # the euro's group, or a decimal point only where it can be no group.
    test "a period is de-AT's currency group where it can be one" do
      assert {:EUR, "1234"} = amount("1.234 EUR", locale: :"de-AT")
      assert {:EUR, "100.00"} = amount("100.00 EUR", locale: :"de-AT")
    end

    test "a period that is neither of the locale's separators" do
      assert {:EUR, "100.00"} = amount("100.00 €", locale: :fr)
      assert {:EUR, "1.5"} = amount("€ 1.5", locale: :fr)
      assert {:SEK, "-0.50"} = amount("-0.50 kr", locale: :sv)

      for {string, locale} <- [
            {"1.234 €", :fr},
            {"1.234 kr", :sv},
            {"1.234 zł", :pl},
            {"€ 1.000.000", :fr}
          ] do
        assert %Localize.InvalidAmountError{} = amount(string, locale: locale),
               "#{locale} #{inspect(string)}"
      end
    end

    test "a sentence's closing period after the currency" do
      assert {:USD, "100"} = amount("100 USD.")
    end
  end

  describe "errors" do
    test "no currency and no default" do
      assert %Localize.ParseError{reason: :missing_currency, input: "100"} = amount("100")
    end

    test "a currency whose number cannot be read" do
      assert %Localize.InvalidAmountError{
               currency: :USD,
               amount: "30\u00A0000,00",
               cause: %Localize.InvalidValueError{}
             } = amount("US$30\u00A0000,00", locale: :"en-ZA", separators: :us)

      assert Exception.message(
               Localize.InvalidAmountError.exception(currency: :USD, amount: "1,2,3")
             ) ==
               ~s(The amount "1,2,3" of currency :USD is not a number.)
    end

    test "text that is not one currency amount" do
      for string <- ["USD 100 with trailing text", "USD 100 EUR", "5 USD 6", "USD", "", "   "] do
        assert %Localize.ParseError{reason: :unexpected_input} = amount(string),
               inspect(string)
      end
    end

    # The number, signs and parentheses included, is read by `parse/2`.
    test "a currency whose signs or parentheses are malformed" do
      for string <- ["--5 USD", "-+5 USD", "(5 USD", "5 USD)", ")5 USD(", "((5 USD))"] do
        assert %Localize.InvalidAmountError{currency: :USD} = amount(string), inspect(string)
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
      assert {:error, _} = Parser.parse_currency_amount("100 BTC", caller_currency: :nope)
    end

    test "an over-long string" do
      string = "USD " <> String.duplicate("1", Parser.max_number_bytes())

      assert {:error, %Localize.ParseError{reason: :input_too_large}} =
               Parser.parse_currency_amount(string)
    end
  end
end
