defmodule Localize.Number.Parser do
  @moduledoc """
  Functions for parsing numbers and currencies from strings
  in a locale-aware manner.

  The parser handles locale-specific digit transliteration,
  grouping separators, and decimal separators to convert
  localized number strings back into Elixir numeric values.

  """

  alias Localize.Number.{Symbol, System}

  @type per :: :percent | :permille

  # Unicode's Bidi_Control characters: ALM, LRM, RLM, the embeddings and
  # overrides, and the isolates. CLDR writes them into the signs and currency
  # formats of the right-to-left locales, so `ar-EG` puts an RLM between a
  # minus and its digits. The scanner takes any run of them before a number,
  # or between its sign and digits, as part of the number, which `parse/2`
  # then drops with the other format characters. Elsewhere they stay in the
  # text as written. Not all of `\p{Cf}`: that includes the zero-width joiner
  # that emoji sequences in the surrounding text are built with.
  @bidi_controls "[\\x{061C}\\x{200E}\\x{200F}\\x{202A}-\\x{202E}\\x{2066}-\\x{2069}]*"

  @number_format @bidi_controls <>
                   "([-+]" <>
                   @bidi_controls <>
                   ")?[0-9]([0-9_]|[,](?=[0-9]))*(\\.ZERO_FRACTION|\\.?[0-9_]+([eE][-+]?[0-9]+)?)?"

  # A zero fraction written as a dash, "5.–", for a lenient scan: one or two of
  # the dashes `@zero_fraction_dashes` reads, with no digit after them. A
  # strict scan puts a pattern in its place that never matches.
  @zero_fraction "[\\-\\x{2010}-\\x{2015}\\x{2212}\\x{FE58}\\x{FE63}\\x{FF0D}][\\-\\x{2010}-\\x{2015}\\x{2212}\\x{FE58}\\x{FE63}\\x{FF0D}]?(?![0-9])"

  # TR35's loose matching for lenient parsing says to "ignore all characters in
  # [:Zs:] unless they occur between letters", and separately to normalize to
  # NFKC, "thus no-break space will map to space". Both make the whole space
  # category equivalent here, so a number typed with an ordinary keyboard space
  # parses under a locale that groups with U+202F, and one copied out of
  # formatted output — carrying U+00A0, U+2009 or U+202F — parses in any locale
  # that groups with a space.
  #
  # One departure: where the locale does not group with a space, a space
  # between digits is not ignored. There it parts two numbers, as `scan/2`
  # reads them, so `en` "1 2" is refused rather than read as 12 (user,
  # 2026-10-28; `plans/tr35-audit.md`, "Departs from TR35's sentence by the
  # user's decision"). A space at either end of a number, or beside its sign,
  # is ignored as TR35 says.
  #
  # `[:Zs:]` rather than a full NFKC fold: NFKC also maps superscripts onto
  # digits, so it would silently read "5²" as 52.
  @spaces ~r/\p{Zs}/u

  # The same passage says to ignore all format characters, "in particular, ...
  # any RLM, LRM or ALM used to control BIDI formatting". This is not a
  # hypothetical: CLDR embeds those marks in the number symbols of 19 locales —
  # `ar` writes `minusSign` as LRM followed by "-", and even `root` does — so a
  # negative number copied out of Arabic, Hebrew or Persian text carries one.
  #
  # Safe to strip wholesale here because no locale puts a format character in
  # its `group` or `decimal` symbol, which are the only symbols this function
  # matches on. The percent and per-mille signs do carry them, but those are
  # matched by `resolve_per/2` against the raw string, not through here.
  @format_characters ~r/\p{Cf}/u

  # `{Rs}` and friends in CLDR's general lenient sets name a script's currency
  # sign rather than a character, so there is nothing to fold them to.
  @compound_pattern ~r/\{.*?\}/u

  @digits_only ~r/^[0-9]+$/

  @single_space ~r/^\p{Zs}$/u

  # Spaces at either end of a number, or beside its sign once folded: "_" is
  # the minus family's sample.
  @edge_spaces ~r/\A\p{Zs}+|\p{Zs}+\z|(?<=[_+])\p{Zs}+|\p{Zs}+(?=[_+])/u

  # A run of the Bidi_Control characters in `@bidi_controls`, at the start or
  # the end of a string.
  @leading_bidi_controls ~r/\A[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]+/u
  @trailing_bidi_controls ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]+\z/u
  @any_bidi_controls ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  # The number in a currency amount: digits, with any separator a locale or
  # currency writes between them. Which separator groups and which marks the
  # decimal is left to `parse/2` once the currency is known. A separator
  # counts only between digits, so the period of `da` "kr.5" stays with the
  # currency, or before a zero fraction written as a dash, "5.–", which
  # `parse/2` reads as a whole amount.
  @amount_number ~r/\p{Nd}(?:\p{Nd}|[\p{Zs}\p{Po}\p{Pf}](?=\p{Nd}))*(?:[\p{Po}\p{Pf}][\-\x{2010}-\x{2015}\x{2212}\x{FE58}\x{FE63}\x{FF0D}]{1,2}(?!\p{Nd}))?/u

  @any_digit ~r/\p{Nd}/u
  @ends_in_digit ~r/\p{Nd}\z/u

  # The dashes that stand for a zero fraction, one or two of them, after
  # folding: "_" is CLDR's minus family, which has neither the hyphen U+2010
  # nor the en dash U+2013 that Swiss text writes most.
  @zero_fraction_dashes for dash <- ["_", "\u2010", "\u2013", "\u2014", "\u2015", "\uFE58"],
                            count <- [2, 1],
                            do: String.duplicate(dash, count)

  # The three places in `@number_format` that `localize_format_string/3` fills
  # in with the locale: the sign class, the grouping separator and the decimal.
  @format_placeholders ~r/-\+|,|\\\./

  # Smallest group a lenient parse will accept after a separator: two, the
  # floor that keeps "3 4 5" three numbers (see "Grouping shape" below).
  @lenient_group_floor 2

  # {primary, secondary} for a locale whose pattern carries no grouping.
  @default_grouping_sizes {3, 3}

  # Maximum byte length accepted by `parse/2`. A 1 KB cap fits even
  # very long localised group/decimal-separated representations of a
  # value with hundreds of digits. Override with
  # `config :localize, :max_number_bytes, n`.
  @default_max_number_bytes 1_024

  # Maximum absolute value of a parsed Decimal exponent. CLDR-shipped
  # number formats never produce exponents this large; capping here
  # prevents downstream operations (multiplication, formatting) from
  # materialising mantissa-sized work for an attacker-controlled
  # `"1e9999999999"`. Override with
  # `config :localize, :max_decimal_exponent, n`.
  @default_max_decimal_exponent 100

  # A match distance below this is a good fit (`match_distance/2`): the
  # same language in another territory is 3 to 5, a related language 12
  # and an unrelated one 84.
  @good_fit_distance 10

  @doc """
  Scans a string in a locale-aware manner and returns a list
  of strings and numbers.

  In a locale that groups with a space, a space between digits is
  read as a grouping separator, which is what lets `"1 234,5"` be
  found as one number under `fr`. The consequence is that adjacent
  numbers separated by a space can be read as a single number when
  each run is two digits or more — a list of room numbers or the
  parts of a phone number among them. Pass `lenient: false` to
  require exact grouping sizes, which reads those as separate
  numbers again:

      iex> Localize.Number.Parser.scan("chambres 12 14 16", locale: "fr")
      ["chambres ", 121416]

      iex> Localize.Number.Parser.scan("chambres 12 14 16", locale: "fr", lenient: false)
      ["chambres ", 12, " ", 14, " ", 16]

  ### Arguments

  * `string` is any string.

  * `options` is a keyword list of options.

  ### Options

  * `:number` is one of `:integer`, `:float`, `:decimal`, or
    `nil`. The default is `nil` (auto-detect).

  * `:locale` is a locale identifier. The default is `:en`.

  * `:number_system` is a number system name or type.

  * `:lenient` governs how strictly grouping separators must be
    positioned. `true`, the default, requires each group to be at
    least two digits, which is what keeps `"3 4 5"` three numbers
    rather than one. `false` requires each
    group to be exactly the locale's grouping size, so `fr` takes
    `"1 234 567"` and refuses `"1 23"`.

  * `:currency` is a currency code or a `t:Localize.Currency.t/0`. When set,
    the string is read as an amount of that currency, with the separators
    `Localize.Number.to_string/2` formats it with. Some locales separate a
    currency amount differently from a plain number: `de-AT` formats
    `€ 1.234,56` with a dot for grouping but writes `1 234,56` plain, so
    `"1.234"` is a different number with and without this option. The default
    is `nil`, a plain number.

  * `:separators` names the set of decimal and grouping separators to read
    with, for a locale that has more than one. `en-ZA` writes `1 234,56` with
    its `:standard` set and `1,234.56` with its `:us` set. A locale without
    the named set reads with its standard one. The default is `:standard`.

  ### Returns

  * A list of strings and numbers.

  ### Examples

      iex> Localize.Number.Parser.scan("The prize is 23")
      ["The prize is ", 23]

      iex> Localize.Number.Parser.scan("1kg")
      [1, "kg"]

  """
  @spec scan(String.t(), Keyword.t()) ::
          list(String.t() | integer() | float() | Decimal.t())
          | {:error, Exception.t()}
  def scan(string, options \\ []) do
    with :ok <- validate_arguments(string, :string, options),
         locale = Keyword.get(options, :locale, Localize.get_locale()),
         {:ok, language_tag} <- Localize.validate_locale(locale),
         {:ok, _number_type} <- number_type(Keyword.get(options, :number)),
         {:ok, number_system} <- digits_number_system_from(language_tag, string, options),
         {:ok, symbol} <- number_symbols(language_tag, number_system, options) do
      lenient? = Keyword.get(options, :lenient, true)

      scanner =
        @number_format
        |> localize_format_string(symbol, language_tag)
        |> group_lookahead(language_tag, number_system, symbol, lenient?)
        |> zero_fraction(lenient?)
        |> Regex.compile!([:unicode])

      normalized_string = transliterate_digits(string, number_system)

      # The pieces carry Latin digits now, so `parse/2` is told the number
      # system the scan chose rather than choosing again from those digits.
      element_options = Keyword.put(options, :number_system, number_system)

      scanner
      |> Regex.split(normalized_string, include_captures: true, trim: true)
      |> Enum.map(&parse_element(&1, element_options))
    end
  end

  # Arguments of the wrong type are answered with an error rather than
  # raised on: options that are not a keyword list, or input that is not the
  # string or list the function reads.
  defp validate_arguments(value, type, options) do
    cond do
      not Keyword.keyword?(options) ->
        {:error,
         Localize.InvalidValueError.exception(
           value: options,
           expected: "a keyword list of options"
         )}

      type == :string and not is_binary(value) ->
        {:error, Localize.InvalidValueError.exception(value: value, expected: "a string")}

      # A binary that is not UTF-8 is no string, and the scanner's Unicode
      # regular expression raises on it rather than fail to match.
      type == :string and not String.valid?(value) ->
        {:error, Localize.InvalidValueError.exception(value: value, expected: "a UTF-8 string")}

      type == :list and not is_list(value) ->
        {:error,
         Localize.InvalidValueError.exception(
           value: value,
           expected: "a list of strings and numbers"
         )}

      true ->
        :ok
    end
  end

  # `:number` names the type to parse to; `nil` detects it.
  defp number_type(type) when type in [nil, :integer, :float, :decimal], do: {:ok, type}

  defp number_type(type) do
    {:error,
     Localize.InvalidValueError.exception(
       value: type,
       expected: :number_type,
       allowed_values: [:integer, :float, :decimal]
     )}
  end

  @doc """
  Parses a string in a locale-aware manner and returns a number.

  ### Arguments

  * `string` is any string.

  * `options` is a keyword list of options.

  ### Options

  * `:number` is one of `:integer`, `:float`, `:decimal`, or
    `nil`. The default is `nil` (auto-detect).

  * `:locale` is a locale identifier. The default is `:en`.

  * `:number_system` is a number system name or type.

  * `:lenient` governs how strictly grouping separators must be
    positioned. `true`, the default, requires each group to be at
    least two digits, which is what keeps `"3 4 5"` three numbers
    rather than one. `false` requires each
    group to be exactly the locale's grouping size, so `fr` takes
    `"1 234 567"` and refuses `"1 23"`.

  * `:currency` is a currency code or a `t:Localize.Currency.t/0`. When set,
    the string is read as an amount of that currency, with the separators
    `Localize.Number.to_string/2` formats it with. Some locales separate a
    currency amount differently from a plain number: `de-AT` formats
    `€ 1.234,56` with a dot for grouping but writes `1 234,56` plain, so
    `"1.234"` is a different number with and without this option. The default
    is `nil`, a plain number.

  * `:separators` names the set of decimal and grouping separators to read
    with, for a locale that has more than one. `en-ZA` writes `1 234,56` with
    its `:standard` set and `1,234.56` with its `:us` set. A locale without
    the named set reads with its standard one. The default is `:standard`.

  ### Returns

  * `{:ok, number}` on success.

  * `{:error, exception}` if parsing fails.

  ### Examples

      iex> Localize.Number.Parser.parse("-1_000_000.34")
      {:ok, -1000000.34}

  """
  @spec parse(String.t(), Keyword.t()) ::
          {:ok, integer() | float() | Decimal.t()}
          | {:error, Exception.t()}
  def parse(string, options \\ []) do
    with :ok <- validate_arguments(string, :string, options) do
      cap = max_number_bytes()

      if byte_size(string) > cap do
        {:error,
         Localize.ParseError.exception(
           reason: :input_too_large,
           detail: "number string",
           size: byte_size(string),
           limit: cap
         )}
      else
        do_parse(string, options)
      end
    end
  end

  @doc false
  def max_number_bytes do
    Application.get_env(:localize, :max_number_bytes, @default_max_number_bytes)
  end

  @doc false
  def max_decimal_exponent do
    Application.get_env(:localize, :max_decimal_exponent, @default_max_decimal_exponent)
  end

  defp do_parse(string, options) do
    locale = Keyword.get(options, :locale, Localize.get_locale())

    with {:ok, language_tag} <- Localize.validate_locale(locale),
         {:ok, number_type} <- number_type(Keyword.get(options, :number)),
         {:ok, number_system} <- digits_number_system_from(language_tag, string, options),
         {:ok, symbol} <- number_symbols(language_tag, number_system, options) do
      lenient? = Keyword.get(options, :lenient, true)

      read_number(string, number_type, number_system, symbol, language_tag, lenient?)
    end
  end

  # Text that is not a number of this locale is a parse error naming the
  # text, not whichever step of the reading first refused it.
  defp read_number(string, number_type, number_system, symbol, language_tag, lenient?) do
    case normalized_value(string, number_type, number_system, symbol, language_tag, lenient?) do
      {:ok, _value} = success -> bound_decimal_exponent(success, string)
      _unreadable -> {:error, parse_error(string)}
    end
  end

  defp normalized_value(string, number_type, number_system, symbol, language_tag, lenient?) do
    with {:ok, normalized} <-
           string
           |> transliterate_digits(number_system)
           |> normalize_number_string(symbol, language_tag, number_system, lenient?) do
      normalized |> String.trim() |> parse_number(number_type)
    end
  end

  # If the parsed value is a `Decimal` with an exponent magnitude that
  # would make downstream operations expensive, reject the parse
  # rather than return a value that will misbehave under multiplication
  # or formatting. Integers and floats are bounded by their own range
  # checks and do not need this guard.
  defp bound_decimal_exponent({:ok, %Decimal{exp: exp}} = ok, _string)
       when is_integer(exp) do
    if abs(exp) > max_decimal_exponent() do
      {:error, parse_error("Decimal exponent #{exp} exceeds limit of ±#{max_decimal_exponent()}")}
    else
      ok
    end
  end

  defp bound_decimal_exponent(other, _string), do: other

  @doc """
  Resolves currencies from strings within a list.

  ### Arguments

  * `list` is a list of strings and numbers.

  * `options` is a keyword list of options.

  ### Options

  * `:locale` is a locale identifier. The default is `:en`.

  * `:only` is a filter for currencies to include.

  * `:except` is a filter for currencies to exclude.

  * `:fuzzy` is a float for fuzzy matching via `String.jaro_distance/2`.
    Of equally close currency strings, the alphabetically first is taken.

  ### Returns

  * A list with currency strings replaced by currency code atoms.

  ### Examples

      iex> Localize.Number.Parser.scan("100 US dollars")
      ...> |> Localize.Number.Parser.resolve_currencies()
      [100, :USD]

  """
  @spec resolve_currencies([String.t() | number()], Keyword.t()) ::
          list(atom() | String.t() | number()) | {:error, Exception.t()}
  def resolve_currencies(list, options \\ []) do
    with :ok <- validate_arguments(list, :list, options) do
      resolve(list, &resolve_currency/2, options)
    end
  end

  @doc """
  Resolves a currency from the beginning and/or end of a string.

  A string several of the locale's currencies share names the currency
  of the territory whose CLDR locale is nearest the locale, when that
  locale is a good fit and no other claimant's is as near: "$" is the
  Canadian dollar in `fr`, as in `fr-CA`. Otherwise it stays unknown.

  ### Arguments

  * `string` is a string potentially containing a currency name or symbol.

  * `options` is a keyword list of options.

  ### Options

  * `:locale` is a locale identifier. The default is `:en`.

  * `:only` is a filter for currencies to include.

  * `:except` is a filter for currencies to exclude.

  * `:fuzzy` is a float for fuzzy matching. Of equally close
    currency strings, the alphabetically first is taken.

  ### Returns

  * A list with the currency code and remainder, or
    `{:error, exception}`.

  ### Examples

      iex> Localize.Number.Parser.resolve_currency("US dollars")
      [:USD]

      iex> Localize.Number.Parser.resolve_currency("$100")
      [:USD, "100"]

  """
  @spec resolve_currency(String.t(), Keyword.t()) ::
          list(atom() | String.t()) | {:error, Exception.t()}
  def resolve_currency(string, options \\ []) do
    with :ok <- validate_arguments(string, :string, options) do
      find_currency(string, options)
    end
  end

  @doc """
  Parses a string that holds one currency amount into its currency and
  its amount.

  The currency, a code, symbol or name, may come before or after the
  amount, with or without a space between them. A sign may stand
  before the currency, between the currency and the amount, or after
  the amount, and the parentheses of an accounting format negate it.
  The amount is read with the separators the locale uses for that
  currency, so `fr-CH` "1’234.56 CHF" reads as it is written. Bidi
  controls are ignored. Nothing else may surround the amount.

  ### Arguments

  * `string` is the string to parse.

  * `options` is a keyword list of options.

  ### Options

  * `:locale` is a locale identifier. The default is
    `Localize.get_locale/0`.

  * `:number_system` and `:separators` are as for `parse/2`.

  * `:only`, `:except` and `:fuzzy` are as for `resolve_currency/2`.

  * `:default_currency` is the currency of an amount that names none:
    a currency code, or a name or symbol, resolved as currency text
    in the string would be. Without it, such an amount is an error.

  * `:unknown_currency` is a function of one argument, called with
    currency text that names no currency of the locale. It returns
    `{:ok, currency}` to read the text as `currency`, or anything else
    to leave it unknown. A caller recognises currencies of its own,
    such as digital tokens, with it.

  ### Returns

  * `{:ok, {currency, amount}}` where `currency` is a currency code, or
    what `:unknown_currency` returned, and `amount` is a `t:Decimal.t/0`,
    or

  * `{:error, %Localize.UnknownCurrencyError{currency: text}}` when the
    currency text names no currency, or

  * `{:error, %Localize.ParseError{reason: :missing_currency}}` when the
    string names no currency and there is no `:default_currency`, or

  * `{:error, %Localize.InvalidAmountError{currency: currency, amount: text}}`
    when the string names a currency but its number cannot be read with
    the locale's separators for it, or

  * `{:error, %Localize.ParseError{reason: :unexpected_input}}` when the
    string is not one currency amount, or

  * `{:error, exception}` for an invalid locale or option.

  ### Examples

      iex> Localize.Number.Parser.parse_currency_amount("USD 100", locale: :en)
      {:ok, {:USD, Decimal.new("100")}}

      iex> Localize.Number.Parser.parse_currency_amount("(1 234,56 €)", locale: :fr)
      {:ok, {:EUR, Decimal.new("-1234.56")}}

      iex> Localize.Number.Parser.parse_currency_amount("kr-127,54", locale: :da)
      {:ok, {:DKK, Decimal.new("-127.54")}}

  """
  @spec parse_currency_amount(String.t(), Keyword.t()) ::
          {:ok, {Localize.Currency.currency_code() | term(), Decimal.t()}}
          | {:error, Exception.t()}
  def parse_currency_amount(string, options \\ []) do
    with :ok <- validate_arguments(string, :string, options),
         :ok <- validate_amount_size(string),
         locale = Keyword.get(options, :locale, Localize.get_locale()),
         {:ok, language_tag} <- Localize.validate_locale(locale),
         options = Keyword.put(options, :locale, language_tag),
         {:ok, parts} <- amount_parts(string, language_tag),
         {:ok, currency, separators_of} <- amount_currency(parts, string, options),
         {:ok, number} <- amount_number(parts, currency, separators_of, options) do
      {:ok, {currency, signed_amount(number, parts)}}
    end
  end

  defp find_currency(string, options) do
    locale = Keyword.get(options, :locale, Localize.get_locale())
    only_filter = Keyword.get(options, :only, [:all])
    except_filter = Keyword.get(options, :except, [])
    fuzzy = Keyword.get(options, :fuzzy, nil)

    filters = [only: only_filter, except: except_filter]

    with {:ok, language_tag} <- Localize.validate_locale(locale),
         {:ok, currency_strings} <-
           Localize.Currency.currency_strings(locale_id(language_tag), filters),
         {:ok, currency} <-
           found_currency(currency_strings, string, fuzzy, language_tag, filters) do
      currency
    end
  end

  # Only finding no currency means the currency is unknown. An invalid
  # `:fuzzy` value is reported as itself.
  defp found_currency(currency_strings, string, fuzzy, language_tag, filters) do
    case find_or_resolve_currency(currency_strings, string, fuzzy, language_tag, filters) do
      {:ok, _currency} = found ->
        found

      {:error, %Localize.InvalidValueError{context: "Localize.Number.Parser"}} ->
        {:error, Localize.UnknownCurrencyError.exception(currency: string)}

      {:error, _exception} = error ->
        error
    end
  end

  # A string several of the locale's currencies share ("$" in `fr`) names
  # the currency used where the locale closest to this one is spoken: of
  # the CLDR locales of each claimant's territories, the one
  # `Localize.LanguageTag.match_distance/2` puts nearest, if it is a good
  # fit and no locale of another claimant is as near. So "$" is the
  # Canadian dollar in `fr`, as it is in `fr-CA`, and stays unknown in
  # `es`, which Mexico, the United States and Argentina are as near.
  defp find_or_resolve_currency(currency_strings, string, fuzzy, language_tag, filters) do
    case find_and_replace_currency(currency_strings, string, fuzzy, language_tag) do
      {:ok, _found} = found ->
        found

      {:error, _not_found} = error ->
        resolved_claimants(string, fuzzy, language_tag, filters, error)
    end
  end

  # The error stands where the string is not one the locale's currencies
  # share, or where its claimants cannot be told apart.
  defp resolved_claimants(string, fuzzy, language_tag, filters, error) do
    case Localize.Currency.ambiguous_currency_strings(locale_id(language_tag), filters) do
      {:ok, ambiguous} -> claimants_in(ambiguous, string, fuzzy, language_tag, error)
      {:error, _no_shared_strings} -> error
    end
  end

  defp claimants_in(ambiguous, string, fuzzy, language_tag, error) do
    case find_and_replace_currency(ambiguous, string, fuzzy, language_tag) do
      {:ok, found} when is_list(found) -> nearest_claimants(found, language_tag, error)
      _not_a_shared_string -> error
    end
  end

  defp nearest_claimants(found, language_tag, error) do
    case resolve_claimants(found, language_tag) do
      {:ok, resolved} -> {:ok, resolved}
      :error -> error
    end
  end

  defp resolve_claimants(found, language_tag) do
    Enum.reduce_while(found, {:ok, []}, fn
      codes, {:ok, acc} when is_list(codes) ->
        case closest_currency(codes, language_tag) do
          {:ok, code} -> {:cont, {:ok, acc ++ [code]}}
          :error -> {:halt, :error}
        end

      other, {:ok, acc} ->
        {:cont, {:ok, acc ++ [other]}}
    end)
  end

  defp closest_currency(codes, language_tag) do
    scored =
      for code <- codes,
          locale_id <- home_locale_ids(code),
          distance <- [
            Localize.LanguageTag.match_distance(language_tag, Atom.to_string(locale_id))
          ],
          is_number(distance) and distance < @good_fit_distance,
          do: {distance, code}

    nearest_code(scored)
  end

  # `:error` where nothing is a good fit, and where two codes are equally
  # near: a tie names no currency.
  defp nearest_code([]), do: :error

  defp nearest_code(scored) do
    nearest = scored |> Enum.map(&elem(&1, 0)) |> Enum.min()

    case for({^nearest, code} <- scored, uniq: true, do: code) do
      [code] -> {:ok, code}
      _tied -> :error
    end
  end

  # The CLDR locales of the territories whose current currency `code` is.
  defp home_locale_ids(code) do
    locales_by_territory = locales_by_territory()

    for {territory, locale_ids} <- locales_by_territory,
        Localize.Currency.current_currency_for_territory(territory) == code,
        locale_id <- locale_ids,
        do: locale_id
  end

  # Every CLDR locale by its territory, given or likely (`fr-CA` is
  # Canada's, `fr` France's), built once.
  defp locales_by_territory do
    key = {__MODULE__, :locales_by_territory}

    case :persistent_term.get(key, nil) do
      nil ->
        map =
          Enum.group_by(
            for(
              locale_id <- Localize.all_locale_ids(),
              {:ok, territory} <- [Localize.Territory.territory_from_locale(locale_id)],
              do: {territory, locale_id}
            ),
            &elem(&1, 0),
            &elem(&1, 1)
          )

        Localize.LiteralMemory.cache(key, map)
        map

      map ->
        map
    end
  end

  @doc """
  Resolves percent and permille symbols from strings within a list.

  ### Arguments

  * `list` is a list of strings and numbers.

  * `options` is a keyword list of options.

  ### Options

  * `:locale` is a locale identifier atom, string, or a
    `t:Localize.LanguageTag.t/0`. The default is
    `Localize.get_locale()`.

  * `:number_system` is a number system name or type atom.
    The default is the number system of `:locale`.

  ### Returns

  * A list with percent/permille strings replaced by `:percent`
    or `:permille` atoms.

  ### Examples

      iex> Localize.Number.Parser.scan("100%")
      ...> |> Localize.Number.Parser.resolve_pers()
      [100, :percent]

  """
  @spec resolve_pers([String.t() | number()], Keyword.t()) ::
          list(per() | String.t() | number()) | {:error, Exception.t()}
  def resolve_pers(list, options \\ []) do
    with :ok <- validate_arguments(list, :list, options) do
      resolve(list, &resolve_per/2, options)
    end
  end

  @doc """
  Resolves percent or permille from a string.

  ### Arguments

  * `string` is a string potentially containing percent
    or permille symbols.

  * `options` is a keyword list of options.

  ### Options

  * `:locale` is a locale identifier atom, string, or a
    `t:Localize.LanguageTag.t/0`. The default is
    `Localize.get_locale()`.

  * `:number_system` is a number system name or type atom.
    The default is the number system of `:locale`.

  ### Returns

  * A list with the symbol replaced by `:percent` or `:permille`.

  * `{:error, exception}` if no symbol found.

  ### Examples

      iex> Localize.Number.Parser.resolve_per("11%")
      ["11", :percent]

  """
  @spec resolve_per(String.t(), Keyword.t()) ::
          list(per() | String.t()) | {:error, Exception.t()}
  def resolve_per(string, options \\ []) do
    with :ok <- validate_arguments(string, :string, options),
         locale = Keyword.get(options, :locale, Localize.get_locale()),
         {:ok, language_tag} <- Localize.validate_locale(locale),
         {:ok, number_system} <- digits_number_system_from(language_tag, string, options),
         {:ok, symbol} <- number_symbols(language_tag, number_system, []) do
      per_strings =
        build_per_strings(symbol)

      case find_and_replace(per_strings, string, nil) do
        {:ok, result} -> result
        {:error, _} -> {:error, parse_error("No percent or permille found")}
      end
    end
  end

  @doc """
  Maps a list applying a resolver function to each binary element.

  ### Arguments

  * `list` is a list of terms.

  * `resolver` is a function that takes a string and options.

  * `options` is a keyword list passed to the resolver.

  ### Options

  * The options are passed through unchanged to `resolver` for each
    binary element. See the resolver function (for example
    `resolve_currency/2` or `resolve_per/2`) for the options it
    supports.

  ### Returns

  * The list with binary elements resolved.

  ### Examples

      iex> resolver = &Localize.Number.Parser.resolve_currency/2
      iex> Localize.Number.Parser.resolve(["100", "USD"], resolver, locale: :en)
      ["100", :USD]

  """
  @spec resolve(list(), (String.t(), Keyword.t() -> term()), Keyword.t()) ::
          list() | {:error, Exception.t()}
  def resolve(list, resolver, options) when is_list(list) and is_function(resolver, 2) do
    Enum.map(list, fn
      string when is_binary(string) ->
        case resolver.(string, options) do
          {:error, _} -> string
          other -> other
        end

      other ->
        other
    end)
    |> List.flatten()
  end

  def resolve(list, resolver, _options) when is_list(list),
    do: {:error, Localize.Utils.Helpers.invalid_value(resolver, "a function of arity 2")}

  def resolve(list, _resolver, _options),
    do: {:error, Localize.Utils.Helpers.invalid_value(list, "a list")}

  @doc """
  Finds and replaces substrings from a map at the beginning
  and/or end of a string.

  ### Arguments

  * `string_map` is a map of `%{search_string => replacement}`.

  * `string` is the string to search.

  * `fuzzy` is an optional float for fuzzy matching. Of equally
    close strings, the alphabetically first is taken.

  ### Returns

  * `{:ok, list}` with replacements applied.

  * `{:error, exception}` if no match found.

  ### Examples

      iex> Localize.Number.Parser.find_and_replace(%{"usd" => :USD}, "USD 100")
      {:ok, [:USD, " 100"]}

      iex> Localize.Number.Parser.find_and_replace(%{"%" => :percent}, "11%")
      {:ok, ["11", :percent]}

  """
  @spec find_and_replace(map(), String.t(), float() | nil) ::
          {:ok, list()} | {:error, Exception.t()}
  def find_and_replace(string_map, string, fuzzy \\ nil)

  def find_and_replace(string_map, string, fuzzy) when is_map(string_map) and is_binary(string) do
    replace_strings(string_map, string, fuzzy, MapSet.new())
  end

  def find_and_replace(string_map, _string, _fuzzy) when not is_map(string_map),
    do:
      {:error,
       Localize.Utils.Helpers.invalid_value(string_map, "a map of strings to replacements")}

  def find_and_replace(_string_map, string, _fuzzy),
    do: {:error, Localize.Utils.Helpers.invalid_value(string, "a string")}

  # ── Private helpers ──────────────────────────────────────────

  # ── Currency amounts ─────────────────────────────────────────

  defp validate_amount_size(string) do
    limit = max_number_bytes()

    if byte_size(string) > limit do
      {:error,
       Localize.ParseError.exception(
         reason: :input_too_large,
         detail: "currency amount",
         size: byte_size(string),
         limit: limit
       )}
    else
      :ok
    end
  end

  # Splits an amount into its number, its currency text and its sign. The
  # text either side of the number is its decorations (spaces, signs and
  # parentheses) around at most one currency text.
  defp amount_parts(string, language_tag) do
    text = String.replace(string, @any_bidi_controls, "")

    case Regex.run(@amount_number, text, return: :index) do
      [{start, length}] ->
        before = binary_part(text, 0, start)
        number = binary_part(text, start, length)
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        decorated_parts(before, number, rest, language_tag, string)

      nil ->
        {:error, not_an_amount(string)}
    end
  end

  defp decorated_parts(before, number, rest, language_tag, string) do
    pattern = decoration_pattern(language_tag)
    {leading, prefix, before_number} = decorations(pattern, before)
    {after_number, suffix, trailing} = decorations(pattern, rest)
    opening = leading <> before_number
    closing = after_number <> trailing
    signs = sign_counts(opening <> closing, language_tag)

    if valid_amount?(prefix, suffix, opening, closing, signs) do
      # Parentheses negate whatever sign is inside them, so "($-127.54)" is
      # positive, as ex_money has always read it.
      minus? = signs.minus == 1
      parenthesised? = String.contains?(opening, "(")

      {:ok, %{currency: prefix <> suffix, number: number, negative?: minus? != parenthesised?}}
    else
      {:error, not_an_amount(string)}
    end
  end

  # One currency text at most, on one side; no second number; a sign of one
  # kind at most; and parentheses only as a pair around the whole amount.
  defp valid_amount?(prefix, suffix, opening, closing, signs) do
    (prefix == "" or suffix == "") and
      not String.match?(prefix <> suffix, @any_digit) and
      signs.minus + signs.plus <= 1 and
      parentheses(opening, "(") == parentheses(closing, ")") and
      parentheses(opening, "(") <= 1 and
      parentheses(opening, ")") == 0 and
      parentheses(closing, "(") == 0
  end

  defp parentheses(text, parenthesis) do
    length(:binary.matches(text, parenthesis))
  end

  # `text` as its leading decorations, the text between them and its
  # trailing decorations.
  defp decorations(pattern, text) do
    case Regex.run(pattern, text) do
      [_text, leading, middle, trailing] -> {leading, middle, trailing}
      _no_decorations -> {"", text, ""}
    end
  end

  defp decoration_pattern(language_tag) do
    {minus, plus} = amount_signs(language_tag)
    decoration = "[\\p{Zs}\\t()" <> class_characters(minus ++ plus) <> "]*"
    Regex.compile!("\\A(" <> decoration <> ")(.*?)(" <> decoration <> ")\\z", "us")
  end

  # The minus and plus signs `parse/2` folds, without the minus family's
  # sample "_", which `parse/2` reads as a digit separator.
  defp amount_signs(language_tag) do
    sets = lenient_sets(language_tag)
    {lenient_equivalents("-", sets) -- ["_"], lenient_equivalents("+", sets)}
  end

  defp sign_counts(decorations, language_tag) do
    {minus, plus} = amount_signs(language_tag)
    characters = String.graphemes(decorations)

    %{
      minus: Enum.count(characters, &(&1 in minus)),
      plus: Enum.count(characters, &(&1 in plus))
    }
  end

  # The currency an amount names, and the currency whose separators its
  # number is read with: none for one the caller's `:unknown_currency`
  # function named, which Localize has no separators for.
  defp amount_currency(%{currency: ""}, string, options) do
    default = Keyword.get(options, :default_currency)

    if is_nil(default) do
      {:error, Localize.ParseError.exception(input: string, reason: :missing_currency)}
    else
      default_currency(default, options)
    end
  end

  defp amount_currency(%{currency: text}, _string, options) do
    text_currency(text, options)
  end

  defp default_currency(default, options) when is_atom(default) do
    text_currency(Atom.to_string(default), options)
  end

  defp default_currency(default, options) when is_binary(default) do
    text_currency(default, options)
  end

  defp default_currency(default, _options) do
    {:error, Localize.Utils.Helpers.invalid_value(default, "a currency code or name")}
  end

  # A closing period is tried off as well as on, so "100 USD." is dollars as
  # it is in the text of a sentence.
  defp text_currency(text, options) do
    filters = Keyword.take(options, [:locale, :only, :except, :fuzzy])

    [text, String.trim_trailing(text, ".")]
    |> Enum.uniq()
    |> first_text_currency(text, filters, options)
  end

  defp first_text_currency([candidate | rest], text, filters, options) do
    case resolve_currency(candidate, filters) do
      [currency] when is_atom(currency) ->
        {:ok, currency, currency}

      {:error, %Localize.UnknownCurrencyError{}} ->
        first_text_currency(rest, text, filters, options)

      {:error, _invalid_option} = error ->
        error

      _part_of_the_text ->
        first_text_currency(rest, text, filters, options)
    end
  end

  defp first_text_currency([], text, _filters, options) do
    caller_currency(Keyword.get(options, :unknown_currency), text)
  end

  defp caller_currency(nil, text) do
    {:error, Localize.UnknownCurrencyError.exception(currency: text)}
  end

  defp caller_currency(resolver, text) when is_function(resolver, 1) do
    case resolver.(text) do
      {:ok, currency} -> {:ok, currency, nil}
      _unknown -> caller_currency(nil, text)
    end
  end

  defp caller_currency(resolver, _text) do
    {:error, Localize.Utils.Helpers.invalid_value(resolver, "a function of one argument")}
  end

  defp amount_number(%{number: number}, currency, separators_of, options) do
    parse_options =
      options
      |> Keyword.take([:locale, :number_system, :separators])
      |> Keyword.put(:number, :decimal)
      |> put_separators_currency(separators_of)

    case parse(number, parse_options) do
      {:ok, decimal} -> {:ok, decimal}
      {:error, exception} -> {:error, invalid_amount(currency, number, exception)}
    end
  end

  defp put_separators_currency(options, nil) do
    options
  end

  defp put_separators_currency(options, currency) do
    Keyword.put(options, :currency, currency)
  end

  defp signed_amount(decimal, %{negative?: true}) do
    Decimal.negate(decimal)
  end

  defp signed_amount(decimal, %{negative?: false}) do
    decimal
  end

  defp not_an_amount(string) do
    Localize.ParseError.exception(
      input: string,
      reason: :unexpected_input,
      detail: "not a currency amount"
    )
  end

  defp invalid_amount(currency, number, cause) do
    Localize.InvalidAmountError.exception(currency: currency, amount: number, cause: cause)
  end

  defp find_and_replace_currency(string_map, string, fuzzy, language_tag) do
    replace_strings(string_map, string, fuzzy, period_strings(language_tag))
  end

  defp replace_strings(string_map, string, fuzzy, period_strings) do
    if String.trim(string) == "" do
      {:ok, string}
    else
      do_find_and_replace(string_map, string, fuzzy, period_strings)
    end
  end

  # CLDR writes some currency symbols and names with a closing period, "kr." in
  # `da` and "ج.م.‏" in `ar`, and `Localize.Currency.currency_strings/2` stores
  # them without it, so "kr." matched as "kr" and left the period over as
  # text. These are the stored strings whose CLDR form had one, so the
  # matcher takes a period after them as part of the currency. After any
  # other string a period is left alone: "100 USD." ends a sentence.
  defp period_strings(language_tag) do
    locale = locale_id(language_tag)

    cached({:currency_period_strings, locale}, fn ->
      locale
      |> Localize.Currency.currencies_for_locale()
      |> period_strings_of()
    end)
  end

  defp period_strings_of({:ok, currencies}) do
    for {_code, currency} <- currencies,
        text <- currency_texts(currency),
        text = String.trim_trailing(String.downcase(text), "\u200F"),
        String.ends_with?(text, "."),
        into: MapSet.new(),
        do: String.trim_trailing(text, ".")
  end

  defp period_strings_of({:error, _no_currencies}) do
    MapSet.new()
  end

  defp currency_texts(currency) do
    counts =
      if is_map(currency.count) do
        Map.values(currency.count)
      else
        []
      end

    Enum.filter([currency.name, currency.symbol, currency.narrow_symbol | counts], &is_binary/1)
  end

  defp parse_element(element, options) do
    case parse(element, options) do
      {:ok, number} -> number
      {:error, _} -> element
    end
  end

  defp parse_number(string, nil) do
    with {:error, _} <- parse_number(string, :integer),
         {:error, _} <- parse_number(string, :float) do
      {:error, string}
    end
  end

  defp parse_number(string, :integer) do
    case Integer.parse(string) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, string}
    end
  end

  defp parse_number(string, :float) do
    case Float.parse(string) do
      {float, ""} -> {:ok, float}
      _ -> {:error, string}
    end
  end

  defp parse_number(string, :decimal) do
    case Localize.Utils.Decimal.parse(string) do
      {:error, _} -> {:error, string}
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, string}
    end
  end

  defp normalize_number_string(string, symbols, language_tag, number_system, lenient?) do
    lenient = lenient_replacements(language_tag)

    # TR35 is explicit that loose matching applies "to both the input text and
    # to each of the field elements used in matching". Folding only the input
    # would break the locales whose own separator is one of the characters
    # being folded: `de-CH` groups with an ASCII apostrophe, which the general
    # scope maps onto U+2019, and `ar`'s `arab` decimal separator U+066B is in
    # the comma set. Folding both sides keeps them matching each other.
    group_sep = symbols.group |> extract_separator() |> apply_lenient(lenient)
    decimal_sep = symbols.decimal |> extract_separator() |> apply_lenient(lenient)

    folded =
      string
      # Elixir's own numeric literal separator, dropped before the minus fold
      # below can introduce one of its own.
      |> String.replace("_", "")
      |> String.replace(@format_characters, "")
      |> apply_lenient(lenient)
      |> normalize_spaces(group_sep)
      |> drop_zero_fraction(decimal_sep, lenient?)

    with :ok <-
           validate_grouping(
             folded,
             group_sep,
             decimal_sep,
             language_tag,
             number_system,
             lenient?
           ) do
      {:ok,
       folded
       |> String.replace(group_sep, "")
       |> String.replace(@spaces, "")
       |> String.replace(decimal_sep, ".")
       # CLDR names the minus set by the sample "_", so folding it yields that
       # placeholder rather than a sign. Restoring it last keeps a minus from
       # being mistaken for a separator while the separators are being removed.
       |> String.replace("_", "-")}
    end
  end

  # Swiss "5.–" and Dutch "5,-" write a whole amount with a dash for its
  # fraction. CLDR has no data for the convention (CLDR-3394), so it is read
  # only leniently, after the folds.
  defp drop_zero_fraction(string, decimal_sep, true) when decimal_sep != "" do
    Enum.find_value(@zero_fraction_dashes, string, fn dashes ->
      whole = String.replace_suffix(string, decimal_sep <> dashes, "")

      if whole != string and String.match?(whole, @ends_in_digit) do
        whole
      end
    end)
  end

  defp drop_zero_fraction(string, _decimal_sep, _lenient?) do
    string
  end

  # Where the locale groups with a space, every space folds onto that separator
  # so the grouping check below can see it. Deleting them instead would erase
  # the very characters whose positions are being validated. Elsewhere a space
  # inside the number is refused by `interior_space?/2`.
  defp normalize_spaces(string, group_sep) do
    if String.match?(group_sep, @single_space) do
      String.replace(string, @spaces, group_sep)
    else
      string
    end
  end

  # ── Grouping shape ─────────────────────────────────────────────
  #
  # TR35's heuristics for parsing a number, which "may be helpful", have a
  # grouping separator ignored wherever it stands, and leave it to the
  # implementation "to disambiguate the sets of characters that might serve in
  # more than one position, based on context". A space is such a character: it
  # groups digits in many locales and parts numbers in all of them. So a
  # grouping separator is held to a plausible position, in both modes, which
  # differ only in how strict "plausible" is (user, 2026-10-06,
  # `plans/tr35-audit.md`; ICU holds it so too, with the same floor):
  #
  #   * strict  — every group is exactly the locale's grouping size, so `fr`
  #     takes "1 234 567" and refuses "1 23".
  #
  #   * lenient — every group is at least two digits, so "1 23" is taken but
  #     "3 4" is not, and no longer than the locale's longest group, so `de`
  #     refuses "1234.56" rather than reading it as 123456. The longest
  #     rather than each position's own size, so `en-IN` still takes
  #     "1,234,567" written with Western grouping.
  #
  # The lenient floor of two is what keeps a space usable as a grouping
  # separator without swallowing adjacent small numbers: "3 4 5" is three
  # numbers in any locale, and no mode reads it as 345.

  defp validate_grouping(string, group_sep, decimal_sep, language_tag, number_system, lenient?) do
    [integer_part | fraction] = String.split(string, decimal_sep, parts: 2)
    integer_part = String.replace(integer_part, ["_", "+"], "")

    # Digits after the decimal mark are never grouped, so a grouping
    # separator there means the text is not a number of this locale: `de`
    # "1,234.56" is not 1.23456, nor `fr` "1,5 6" 1.56.
    cond do
      interior_space?(string, group_sep) ->
        {:error, :grouping}

      grouped_fraction?(fraction, group_sep) ->
        {:error, :grouping}

      true ->
        validate_integer_grouping(integer_part, group_sep, language_tag, number_system, lenient?)
    end
  end

  # A number is digits joined by the locale's separators. Where the locale
  # groups with a space, `normalize_spaces/2` has already made every space
  # that separator; anywhere else a space inside the number parts two
  # numbers, as `scan/2` reads them, so `en` "1 2" is not 12. A space before
  # or after the number, or beside its sign, is not inside it.
  defp interior_space?(string, group_sep) do
    if String.match?(group_sep, @single_space) do
      false
    else
      string
      |> String.replace(@edge_spaces, "")
      |> String.match?(@spaces)
    end
  end

  defp grouped_fraction?([fraction], group_sep) when group_sep != "" do
    String.contains?(fraction, group_sep)
  end

  defp grouped_fraction?(_no_fraction, _group_sep) do
    false
  end

  defp validate_integer_grouping(integer_part, group_sep, language_tag, number_system, lenient?) do
    case String.split(integer_part, group_sep) do
      # No grouping separator at all: grouping is optional in input.
      [_ungrouped] -> :ok
      groups -> validate_groups(groups, grouping_sizes(language_tag, number_system), lenient?)
    end
  end

  defp validate_groups(groups, {primary, secondary}, lenient?) do
    [leading | rest] = groups
    {last, middle} = List.pop_at(rest, -1)

    valid? =
      cond do
        # A group that is not all digits is not a group at all.
        Enum.any?(groups, &(&1 == "" or not String.match?(&1, @digits_only))) -> false
        lenient? -> lenient_groups?(leading, rest, max(primary, secondary))
        String.length(last) != primary -> false
        Enum.any?(middle, &(String.length(&1) != secondary)) -> false
        true -> String.length(leading) <= secondary
      end

    if valid?, do: :ok, else: {:error, :grouping}
  end

  defp lenient_groups?(leading, rest, longest) do
    String.length(leading) <= longest and
      Enum.all?(rest, &(String.length(&1) in @lenient_group_floor..longest//1))
  end

  # The primary group is the rightmost run in the locale's standard pattern and
  # the secondary the one before it. They differ in the Indian system —
  # `en-IN` patterns as `#,##,##0.###`, grouping 12,34,567 — and are the same
  # everywhere else, where a single run means the primary repeats.
  defp grouping_sizes(language_tag, number_system) do
    cached({:grouping_sizes, language_tag.cldr_locale_id, number_system}, fn ->
      keys = [:number_formats, number_system, :standard]

      case Localize.Locale.get(language_tag, keys, fallback: true) do
        {:ok, pattern} -> sizes_from_pattern(pattern)
        {:error, _reason} -> @default_grouping_sizes
      end
    end)
  end

  defp sizes_from_pattern(pattern) do
    runs =
      pattern
      |> String.split(".")
      |> hd()
      |> String.split(",")

    case runs do
      [_ungrouped] ->
        @default_grouping_sizes

      runs ->
        primary = runs |> List.last() |> String.length()

        # With a single separator the leading run is the "#" wildcard rather
        # than a group, so the primary size repeats; a second separator is what
        # introduces a distinct secondary size, as in `en-IN`'s `#,##,##0`.
        secondary =
          if match?([_, _, _ | _], runs),
            do: runs |> Enum.at(-2) |> String.length(),
            else: primary

        {primary, secondary}
    end
  end

  # The character folds CLDR's `parseLenients` data prescribes for this locale,
  # as {compiled pattern, replacement} pairs. The number scope covers the
  # minus, plus and comma families; the general scope adds the full stop, the
  # apostrophe and the currency symbols.
  #
  # Compiled once per locale and memoized. Assembling this walks a dozen set
  # strings, which costs an order of magnitude more than the parse it serves,
  # and the compiled patterns then match without rescanning per character.
  defp lenient_replacements(language_tag) do
    cached({:lenient_parse, language_tag.cldr_locale_id}, fn ->
      for {sample, characters} <- lenient_sets(language_tag) do
        {:binary.compile_pattern(characters), sample}
      end
    end)
  end

  # The same folds as {sample, characters} pairs, for building the scanner's
  # character classes.
  defp lenient_sets(language_tag) do
    cached({:lenient_sets, language_tag.cldr_locale_id}, fn ->
      for scope <- [:number, :general],
          {:ok, sets} <-
            [Localize.Locale.get(language_tag, [:lenient_parse, scope], fallback: true)],
          {sample, set} <- sets,
          characters = lenient_characters(set),
          match?([_ | _], characters),
          do: {sample, characters}
    end)
  end

  # Every character that folds onto the same sample as `character`, itself
  # included.
  defp lenient_equivalents("", _sets) do
    []
  end

  defp lenient_equivalents(character, sets) do
    family =
      Enum.find_value(sets, [], fn {sample, characters} ->
        if character == sample or character in characters do
          [sample | characters]
        end
      end)

    Enum.uniq([character | family])
  end

  defp apply_lenient(string, replacements) do
    Enum.reduce(replacements, string, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  @compile {:inline, cached: 2}
  defp cached(key, build_fn) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :__not_loaded__) do
      :__not_loaded__ ->
        value = build_fn.()
        Localize.LiteralMemory.cache(pt_key, value)
        value

      value ->
        value
    end
  end

  # The sets are flat character lists — no ranges, and the one literal hyphen is
  # backslash-escaped precisely so it is not read as one — so they need
  # unwrapping rather than a UnicodeSet parser. The general scope does carry a
  # few `{Rs}`-style compound patterns, which name no single character and are
  # dropped rather than split into their letters.
  defp lenient_characters(set) do
    set
    |> String.replace(@compound_pattern, "")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.replace("\\", "")
    |> String.graphemes()
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp extract_separator(%{standard: value}), do: value
  defp extract_separator(value) when is_binary(value), do: value
  defp extract_separator(_), do: ""

  defp transliterate_digits(string, :latn), do: string

  defp transliterate_digits(string, number_system) do
    case System.number_system_digits(number_system) do
      {:ok, digits} ->
        {:ok, latn_digits} = System.number_system_digits(:latn)
        map = System.generate_transliteration_map(digits, latn_digits)
        Localize.Number.Transliterate.transliterate_digits(string, map)

      _ ->
        string
    end
  end

  defp digits_number_system_from(language_tag, string, options) do
    number_system =
      Keyword.get_lazy(options, :number_system, fn ->
        written_number_system(language_tag, string)
      end)

    case System.number_system_digits(number_system) do
      {:ok, _digits} -> {:ok, number_system}
      {:error, _} = error -> error
    end
  end

  # The locale's number system, unless the text is written in Latin digits
  # alone. `ar-EG` writes `arab` digits with ٬ and ٫, and ٫ folds onto ",", so
  # reading typed "100,00" with those separators made it 100.00 and refused
  # "1,234.56". The locale's Latin separators are the ones such text is
  # written with.
  defp written_number_system(language_tag, string) do
    case System.number_system_from_locale(language_tag) do
      {:ok, system} -> system_for_digits(system, string)
      _no_system -> :latn
    end
  end

  defp system_for_digits(:latn, _string) do
    :latn
  end

  defp system_for_digits(system, string) do
    case System.number_system_digits(system) do
      {:ok, digits} -> native_or_latin(system, digits, string)
      {:error, _not_numeric} -> system
    end
  end

  defp native_or_latin(system, digits, string) do
    if String.contains?(string, String.graphemes(digits)) do
      system
    else
      :latn
    end
  end

  defp number_symbols(language_tag, number_system, options) do
    with {:ok, symbols} <- symbols_for(language_tag, number_system, options[:currency]) do
      separators = Keyword.get(options, :separators, :standard)

      {:ok,
       %{
         symbols
         | decimal: variant(symbols.decimal, separators),
           group: variant(symbols.group, separators)
       }}
    end
  end

  # CLDR gives a few locales a second set of separators, such as the `:us` set
  # of `en-ZA`. A locale without the requested set reads with its standard one.
  defp variant(%{standard: standard} = separators, name), do: Map.get(separators, name, standard)
  defp variant(separator, _name), do: separator

  defp symbols_for(language_tag, number_system, nil) do
    with {:ok, symbols} <- Symbol.number_symbols_for(language_tag) do
      {:ok, Map.get(symbols, number_system) || Map.get(symbols, :latn)}
    end
  end

  # A currency amount is read with the symbols `Localize.Number.to_string/2`
  # formats it with, so what it formats parses back.
  defp symbols_for(language_tag, number_system, currency) do
    with {:ok, symbols} <- Symbol.number_symbols_for(language_tag, number_system),
         {:ok, currency} <- currency_for(currency, language_tag) do
      {:ok, Symbol.for_currency(symbols, currency)}
    end
  end

  defp currency_for(%Localize.Currency{} = currency, _language_tag), do: {:ok, currency}

  # Reading needs only the currency's separators, not its display names, so a
  # currency the locale has no names for reads with its parent's data.
  defp currency_for(code, language_tag),
    do: Localize.Currency.currency_for_code(code, locale: language_tag, fallback: true)

  # `parse/2` folds each piece the scanner hands it with CLDR's `parseLenients`
  # sets, so the scanner must accept every character those folds would accept.
  # Matching only the locale's literal symbols splits a number at a folded
  # variant: `de-CH` text grouped with U+2019 rather than its own ASCII
  # apostrophe, or `sv` text signed with U+2212, came back in pieces.
  #
  # A character that folds onto both separators' families is left to the
  # separator it is literally, so the classes never overlap.
  defp localize_format_string(string, symbols, language_tag) do
    sets = lenient_sets(language_tag)
    group_sep = extract_separator(symbols.group)
    decimal_sep = extract_separator(symbols.decimal)
    group_family = lenient_equivalents(group_sep, sets)
    decimal_family = lenient_equivalents(decimal_sep, sets)

    group = Enum.uniq([group_sep | group_family -- decimal_family])
    decimal = Enum.uniq([decimal_sep | decimal_family -- group_family])

    replacements = %{
      "-+" => sign_class(symbols, sets),
      "," => group_class(group_sep, group),
      "\\." => "[" <> class_characters(decimal) <> "]"
    }

    # One pass, so a replacement's own characters are never replaced again.
    Regex.replace(@format_placeholders, string, &Map.fetch!(replacements, &1))
  end

  # The signs `parse/2` reads: ASCII, the locale's own, and their folds. The
  # minus family's sample "_" is left out, because `parse/2` drops an
  # underscore as a digit separator rather than reading it as a sign. Format
  # characters in a locale's sign are not part of the sign here.
  defp sign_class(symbols, sets) do
    signs =
      for sign <- ["-", "+", symbols.minus_sign, symbols.plus_sign],
          sign = String.replace(extract_separator(sign), @format_characters, ""),
          character <- lenient_equivalents(sign, sets),
          character != "_",
          uniq: true,
          do: character

    class_characters(signs)
  end

  # What counts as a grouping separator inside the scanner's character class.
  # Where the locale groups with a space, the whole space category counts, so a
  # number typed with an ordinary keyboard space is found in text that a locale
  # would format with U+202F. The grouping-shape lookahead below is what keeps
  # that from joining unrelated numbers.
  defp group_class(group_sep, group) do
    if String.match?(group_sep, @single_space) do
      "\\p{Zs}"
    else
      class_characters(group)
    end
  end

  defp class_characters(characters) do
    characters
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(&Regex.escape/1)
  end

  defp zero_fraction(pattern, true) do
    String.replace(pattern, "ZERO_FRACTION", @zero_fraction)
  end

  defp zero_fraction(pattern, _strict) do
    String.replace(pattern, "ZERO_FRACTION", "(?!)")
  end

  # `@number_format` admits a grouping separator whenever a digit follows. That
  # is too permissive once the separator can be a space: it would read "3 4 5"
  # as one number. Requiring a plausible group instead, two digits leniently
  # or an exact group size strictly, is what makes the wider class safe.
  defp group_lookahead(pattern, language_tag, number_system, symbols, lenient?) do
    {primary, secondary} = grouping_sizes(language_tag, number_system)

    lookahead =
      if lenient? do
        "(?=[0-9]{#{@lenient_group_floor}})"
      else
        separator = symbols.group |> extract_separator() |> Regex.escape()
        "(?=[0-9]{#{primary}}(?![0-9])|[0-9]{#{secondary}}#{separator})"
      end

    String.replace(pattern, "(?=[0-9])", lookahead)
  end

  defp build_per_strings(symbols) do
    percent = symbols.percent_sign
    per_mille = symbols.per_mille

    entries =
      if percent, do: [{percent, :percent}], else: []

    entries =
      if per_mille, do: entries ++ [{per_mille, :permille}], else: entries

    # Add common ASCII equivalents
    entries =
      entries ++
        [
          {"%", :percent},
          {"‰", :permille}
        ]

    Map.new(entries)
  end

  defp locale_id(%Localize.LanguageTag{cldr_locale_id: id}) when not is_nil(id), do: id
  defp locale_id(%Localize.LanguageTag{}), do: :en

  defp do_find_and_replace(string_map, string, nil, period_strings) do
    canonical = String.downcase(String.trim(string))

    if code = Map.get(string_map, canonical) do
      {:ok, [code]}
    else
      [starting_code, remainder] = starting_string(string_map, string, period_strings)
      [remainder, ending_code] = ending_string(string_map, remainder, period_strings)

      if starting_code == "" && ending_code == "" do
        {:error, parse_error("No match was found")}
      else
        {:ok, Enum.reject([starting_code, remainder, ending_code], &(&1 == ""))}
      end
    end
  end

  defp do_find_and_replace(string_map, _search, fuzzy, _period_strings)
       when map_size(string_map) == 0 and is_float(fuzzy) and fuzzy > 0.0 and fuzzy <= 1.0 do
    {:error, parse_error("No match was found")}
  end

  defp do_find_and_replace(string_map, search, fuzzy, _period_strings)
       when is_float(fuzzy) and fuzzy > 0.0 and fuzzy <= 1.0 do
    canonical_search = String.downcase(search)

    # Equally distant strings are ranked alphabetically: sorting on the
    # distance alone left a tie to the order the map yielded them in.
    {distance, _string, code} =
      string_map
      |> Enum.map(fn {string, code} ->
        {String.jaro_distance(string, canonical_search), string, code}
      end)
      |> Enum.min_by(fn {distance, string, _code} -> {-distance, string} end)

    if distance >= fuzzy do
      {:ok, [code]}
    else
      {:error, parse_error("No match was found")}
    end
  end

  defp do_find_and_replace(_string_map, _string, fuzzy, _period_strings) do
    {:error,
     Localize.InvalidValueError.exception(
       value: fuzzy,
       expected: "a number > 0.0 and <= 1.0",
       context: "option :fuzzy"
     )}
  end

  # A currency name or code matches only as a whole word: "dolars" ends in
  # "ars", which is not the Argentine peso. A match that begins or ends in a
  # letter must not run on into another letter; a symbol ("$", "€") needs no
  # boundary, and neither does a letter next to a digit ("USD100").
  defp starting_string(string_map, search, period_strings) do
    trimmed = String.downcase(String.trim_leading(search))

    matches =
      Enum.filter(string_map, fn {k, _v} ->
        String.starts_with?(trimmed, k) and
          word_boundary?(last_grapheme(k), String.first(binary_part_after(trimmed, k)))
      end)

    case matches do
      [] ->
        ["", search]

      list ->
        {match_string, code} = longest_match(list)
        match_length = byte_size(match_string)
        # Find the match in the original string (preserving original case/whitespace)
        downcased = String.downcase(search)
        offset = find_offset(downcased, match_string)

        if offset >= 0 do
          skip = offset + match_length
          <<_::binary-size(^skip), remainder::binary>> = search
          [code, drop_closing(remainder, match_string, period_strings)]
        else
          ["", search]
        end
    end
  end

  defp ending_string(string_map, search, period_strings) do
    trimmed = String.downcase(String.trim_trailing(search))
    core = String.replace(trimmed, @trailing_bidi_controls, "")
    closing = byte_size(trimmed) - byte_size(core)

    matches =
      for {key, code} <- string_map,
          consumed <- ending_matches(trimmed, core, closing, key, period_strings),
          do: {consumed, byte_size(key), code}

    case matches do
      [] ->
        [search, ""]

      list ->
        # Of two matches that take as much of the text, the one written out
        # in full wins over one that reaches it through a closing period.
        {consumed, _key_size, code} = Enum.max(list)
        keep = byte_size(String.trim_trailing(search)) - consumed
        <<remainder::binary-size(^keep), _::binary>> = search
        [remainder, code]
    end
  end

  # What follows a currency matched at the start of the text and belongs to
  # it: the closing period its CLDR form was written with, then any bidi
  # controls, which `Localize.Currency.currency_strings/2` also leaves off.
  defp drop_closing(remainder, match_string, period_strings) do
    remainder =
      if MapSet.member?(period_strings, match_string) do
        String.replace_prefix(remainder, ".", "")
      else
        remainder
      end

    String.replace(remainder, @leading_bidi_controls, "")
  end

  # The bytes `key` takes from the end of the text, once for each way it can
  # end it: as written, before a closing run of bidi controls, and before the
  # closing period its CLDR form was written with.
  defp ending_matches(trimmed, core, closing, key, period_strings) do
    candidates = [
      {trimmed, 0},
      {core, closing},
      {period_core(core, key, period_strings), closing + 1}
    ]

    for {text, extra} <- candidates, is_binary(text), ends_with_word?(text, key) do
      byte_size(key) + extra
    end
  end

  defp period_core(core, key, period_strings) do
    if MapSet.member?(period_strings, key) and String.ends_with?(core, ".") do
      binary_part(core, 0, byte_size(core) - 1)
    end
  end

  defp ends_with_word?(text, key) do
    String.ends_with?(text, key) and
      word_boundary?(String.first(key), String.last(binary_part_before(text, key)))
  end

  # Every match is a prefix (or every one a suffix) of the same text, so no
  # two have the same byte size and the longest is unique. Grapheme counts
  # can tie: in te a currency's plural adds a zero-width non-joiner and a
  # suffix that join the last grapheme, so it counts no longer than the
  # singular, and the tie went to whichever the map yielded first.
  defp longest_match(matches) do
    Enum.max_by(matches, fn {match_string, _code} -> byte_size(match_string) end)
  end

  # True when a match whose edge grapheme is `key_edge` may stop where
  # `neighbour` starts: at the end of the string, next to a non-letter, or
  # when the match itself does not stop on a letter.
  defp word_boundary?(_key_edge, nil), do: true

  defp word_boundary?(key_edge, neighbour),
    do: not (letter?(key_edge) and letter?(neighbour))

  defp letter?(grapheme), do: String.match?(grapheme, ~r/\A\p{L}/u)

  defp last_grapheme(string), do: String.last(string)

  defp binary_part_after(string, prefix),
    do: binary_part(string, byte_size(prefix), byte_size(string) - byte_size(prefix))

  defp binary_part_before(string, suffix),
    do: binary_part(string, 0, byte_size(string) - byte_size(suffix))

  defp find_offset(haystack, needle) do
    case :binary.match(haystack, needle) do
      {offset, _length} -> offset
      :nomatch -> -1
    end
  end

  defp parse_error(message) do
    Localize.InvalidValueError.exception(
      value: message,
      expected: "a parseable number string",
      context: "Localize.Number.Parser"
    )
  end
end
