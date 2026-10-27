defmodule Localize.Number.Formatter.Short do
  @moduledoc false

  # Formats a number according to locale-specific short/long formats.
  #
  # Short formats produce compact representations like "1.2K" or
  # "1.2 thousand". They use CLDR's compact decimal format rules
  # which define format patterns at each power of 10 with plural
  # variants.

  alias Localize.Number.Format
  alias Localize.Number.Format.Options
  alias Localize.Number.Formatter
  alias Localize.Utils.Math

  @one_thousand Decimal.new(1000)

  # # to_string/3
  # Formats a number using short/long format style.
  #
  # ### Arguments
  # * `number` is an integer, float, or Decimal.
  # * `style` is `:decimal_short`, `:decimal_long`,
  #   `:currency_short`, or `:currency_long`.
  # * `options` is a `Localize.Number.Format.Options.t()`.
  #
  # ### Returns
  # * `{:ok, formatted_string}` or `{:error, exception}`.
  @spec to_string(number() | Decimal.t(), atom(), Options.t()) ::
          {:ok, String.t()} | {:error, Exception.t()}
  def to_string(number, _style, _options) when is_binary(number) do
    {:error,
     Localize.InvalidValueError.exception(
       value: number,
       expected: "a number (not a string)",
       context: "Short formats only support number or Decimal arguments"
     )}
  end

  def to_string(number, style, options) do
    with {:ok, normalized_number, format, options} <- resolve_short_format(number, style, options) do
      Formatter.Decimal.to_string(normalized_number, format, options)
    end
  end

  # Formats a compact number into typed parts per ECMA-402
  # `formatToParts`. The compact affix is carried by the pattern's
  # literal tokens, so the decimal formatter's `:literal` parts are
  # retagged `:compact` — everything else in a compact pattern is
  # digits and separators.
  @spec to_parts(number() | Decimal.t(), atom(), Options.t()) ::
          {:ok, [%{type: atom(), value: String.t()}]} | {:error, Exception.t()}
  def to_parts(number, style, options) do
    with {:ok, normalized_number, format, options} <- resolve_short_format(number, style, options),
         {:ok, parts} <- Formatter.Decimal.to_parts(normalized_number, format, options) do
      {:ok,
       Enum.map(parts, fn
         %{type: :literal} = part -> %{part | type: :compact}
         part -> part
       end)}
    end
  end

  defp resolve_short_format(number, style, options) do
    # `options.number_system` is the resolved name, which `formats_for/2`
    # resolves against the locale itself; resolving it first here read the
    # locale once more (#67).
    with {:ok, formats} <- Format.formats_for(options.locale, options.number_system) do
      format_rules = Map.get(formats, style)

      if is_nil(format_rules) do
        {:error,
         Localize.InvalidValueError.exception(
           value: style,
           expected: "a format style with data for this locale",
           context: "Localize.Number.Formatter.Short"
         )}
      else
        # The compact rules, and the standard (or currency) pattern a value
        # no rule applies to is written with: a number below 1000, NaN,
        # infinity, or a rule whose pattern is a bare "0". Read once here;
        # the selection read the formats again for each of those (#67).
        rules = %{
          compact: format_rules,
          standard: Map.get(formats, standard_or_currency(options))
        }

        {normalized_number, format} =
          number
          |> choose_short_format(rules)
          |> promote_magnitude_on_carry(number, rules, options)
          |> pluralize_format(options)

        options =
          options
          |> maybe_set_fractional_digits(normalized_number)
          |> maybe_set_minimum_grouping()
          |> Map.put(:format, format)

        {:ok, normalized_number, format, options}
      end
    end
  end

  # The compact rule is chosen from the value's magnitude, then the mantissa
  # is rounded — and the rounding can carry into the next magnitude, leaving
  # the value formatted against a rule it has outgrown. `999.9` matches no
  # compact rule at all (it is below 1000), rounds to 1000 and renders
  # "1,000"; `999999.9` takes the thousands rule and renders "1000K". TR35's
  # steps choose the pattern by the number, "the pattern element with
  # greatest type less than or equal to N", and say nothing of a mantissa
  # that rounds up into the next type; taken to the letter they write those.
  # CLDR's own test data (`common/testData/decimal`) has "1K" and "1M".
  #
  # So the carry is checked again (user, 2026-10-06, `plans/tr35-audit.md`):
  # the rounded mantissa is scaled back into the original units and the rule
  # chosen again. Re-selecting
  # unconditionally is both simpler and safer than testing for the carry —
  # the test has to know how the rule divided, and locales whose compact
  # pattern is a bare "0" (German's thousands, among others) do not divide at
  # all, so a mantissa-magnitude test silently skips exactly the cases that
  # need it. One pass suffices: rounding carries by at most one magnitude,
  # and where nothing carried the same rule is chosen again.
  defp promote_magnitude_on_carry({mantissa, _format} = chosen, number, rules, options) do
    if rescalable?(mantissa) do
      number
      |> scale_back(mantissa, round_mantissa(mantissa, options))
      |> choose_short_format(rules)
    else
      chosen
    end
  end

  # A zero mantissa gives no divisor to scale back by, and cannot carry;
  # NaN and ±Infinity have no magnitude to carry. A `Decimal` zero is a
  # struct, so `== 0` does not catch it.
  defp rescalable?(%Decimal{coef: coef}) when coef in [:NaN, :inf] do
    false
  end

  defp rescalable?(%Decimal{} = mantissa) do
    not Decimal.eq?(mantissa, 0)
  end

  defp rescalable?(mantissa) when is_number(mantissa) do
    mantissa != 0
  end

  # The mantissa rounded as it will be written: the compact default when
  # the caller gave no digit options, then the decimal formatter's own
  # choice between significant and fraction digits under the rounding
  # priority (ECMA-402's `roundingPriority`), so the carry is checked at the
  # precision the mantissa is written to.
  defp round_mantissa(mantissa, options) do
    resolved =
      options
      |> maybe_set_fractional_digits(mantissa)
      |> Localize.Number.Formatter.Decimal.resolve_digit_options(mantissa)

    max_fractional_digits = resolved.max_fractional_digits || resolved.fractional_digits

    cond do
      is_integer(resolved.maximum_significant_digits) ->
        Math.round_significant(
          mantissa,
          resolved.maximum_significant_digits,
          options.rounding_mode
        )

      is_integer(max_fractional_digits) ->
        Math.round(mantissa, max_fractional_digits, options.rounding_mode)

      true ->
        mantissa
    end
  end

  # `number / mantissa` is the divisor the rule applied; re-applying it to the
  # rounded mantissa gives the rounded value in the original units.
  defp scale_back(%Decimal{} = number, %Decimal{} = mantissa, rounded) do
    Decimal.mult(rounded, Decimal.div(number, mantissa))
  end

  defp scale_back(number, mantissa, rounded) when is_number(number) and is_number(mantissa) do
    rounded * (number / mantissa)
  end

  # Compact notation groups only where at least two digits precede the
  # separator, the `min2` of ECMA-402's `useGrouping` and of TR35's
  # MessageFormat. That is one rule, and it accounts for two opposite-looking
  # results — German renders a compact 5000 as "5000" where the standard
  # format would give "5.000", while Bengali renders 50000 as "৫০,০০০" where
  # a compact format carrying no grouping at all would give "৫০০০০".
  # Expressed as `minimum_grouping_digits` it is simply 2, which
  # `minimum_group_size/2` then adds to the locale's primary group size.
  #
  # TR35's compact steps say otherwise of a number whose pattern is "0": it
  # takes "the normal formatting for the locale (such as the grouping
  # separators)", which for German's 5000 is "5.000". CLDR's own test data
  # (`common/testData/decimal`) has "5000", and it is followed (user,
  # 2026-10-06, `plans/tr35-audit.md`).
  defp maybe_set_minimum_grouping(%{minimum_grouping_digits: nil} = options) do
    %{options | minimum_grouping_digits: 2}
  end

  defp maybe_set_minimum_grouping(%{minimum_grouping_digits: 0} = options) do
    %{options | minimum_grouping_digits: 2}
  end

  defp maybe_set_minimum_grouping(options), do: options

  # When the caller supplies no fraction-digit options, apply the
  # compact default of ECMA-402, which TR35's own examples show
  # ("1.2 K" for 1200, "12 K" for 12345): at most two significant
  # digits on the mantissa, never clipping its integer digits and never
  # forcing a trailing zero — "1.2M", "12M", "123M" and "1M" (not "1.0M").
  # That reduces to max one fraction digit while the mantissa is a
  # single integer digit, none afterwards.
  # ECMA-402 applies compact rounding only under `:auto` with no digit
  # options. Under `:more_precision` and `:less_precision` both bounds take
  # part, and with a fraction bound given it applies; either way a fraction
  # bound the caller did not give takes compact notation's default of 0..3,
  # for a currency too: a minimum given raises the maximum to it, and a
  # maximum given caps the minimum.
  defp maybe_set_fractional_digits(
         %{
           rounding_priority: priority,
           fractional_digits: nil,
           min_fractional_digits: minimum,
           max_fractional_digits: maximum
         } = options,
         _mantissa
       )
       when priority in [:more_precision, :less_precision] or not is_nil(minimum) or
              not is_nil(maximum) do
    minimum = options.min_fractional_digits || 0
    maximum = options.max_fractional_digits || max(minimum, 3)
    %{options | min_fractional_digits: min(minimum, maximum), max_fractional_digits: maximum}
  end

  # The compact default is only a default: a caller's significant digits
  # replace it, as ECMA-402's compact rounding is replaced by
  # `maximumSignificantDigits` (TR35 does not say how compact numbers round).
  defp maybe_set_fractional_digits(
         %{
           fractional_digits: nil,
           min_fractional_digits: nil,
           max_fractional_digits: nil,
           minimum_significant_digits: nil,
           maximum_significant_digits: nil
         } = options,
         mantissa
       ) do
    %{options | min_fractional_digits: 0, max_fractional_digits: compact_max_fraction(mantissa)}
  end

  defp maybe_set_fractional_digits(options, _mantissa), do: options

  # That precision is an integer of at least two significant digits: round
  # the mantissa to an integer, but never below two significant digits
  # (CLDR's test data has a compact 0.00831765 as "0.0083"). For a
  # mantissa of 1 or more that is what "at most one fraction digit while a
  # single integer digit remains" already gives — 1.2M, 12M, 123M. Below 1 the
  # two diverge, because the significant digits start after the leading zeros:
  # a compact `0.00831765` is "0.0083", where one fraction digit rounds it away
  # to "0" entirely.
  #
  # Expressed in fraction digits, two significant digits need `1 - magnitude`
  # of them, where magnitude is the base-10 exponent — 0 for 1.5 (one fraction
  # digit), -1 for 0.15 (two), -3 for 0.0083 (four) — clamped at zero for
  # anything with two integer digits already.
  defp compact_max_fraction(mantissa) do
    case magnitude(mantissa) do
      nil -> 0
      magnitude -> max(0, 1 - magnitude)
    end
  end

  # NaN and ±Infinity have no magnitude; `Decimal.compare/2` raises on NaN.
  defp magnitude(%Decimal{coef: coef}) when coef in [:NaN, :inf] do
    nil
  end

  defp magnitude(%Decimal{} = mantissa) do
    absolute = Decimal.abs(mantissa)

    cond do
      Decimal.equal?(absolute, 0) -> nil
      # Enough to clamp to zero fraction digits, and avoids converting a
      # large Decimal to a float just to take its logarithm.
      Decimal.compare(absolute, 10) != :lt -> 1
      true -> absolute |> Decimal.to_float() |> float_magnitude()
    end
  end

  defp magnitude(mantissa) when is_number(mantissa) do
    if mantissa == 0, do: nil, else: mantissa |> abs() |> float_magnitude()
  end

  defp float_magnitude(absolute) do
    absolute |> :math.log10() |> Float.floor() |> trunc()
  end

  # ── Format selection ────────────────────────────────────────

  # The selection is the mantissa and either the rule's plural selectors, for
  # a value a compact rule applies to, or the standard pattern it is written
  # with instead. The plural form is chosen last, by `pluralize_format/2`,
  # once the rounding carry has settled which rule applies: choosing it here
  # chose it twice and threw the first away (#67).
  defp choose_short_format(number, rules) when is_number(number) and number < 0 do
    {normalized, selection} = choose_short_format(abs(number), rules)
    {normalized * -1, selection}
  end

  defp choose_short_format(%Decimal{sign: -1} = number, rules) do
    {normalized, selection} = choose_short_format(Decimal.abs(number), rules)
    {Decimal.mult(normalized, -1), selection}
  end

  defp choose_short_format(number, rules) do
    case get_short_format_rule(number, rules) do
      [range, plural_selectors] ->
        {normalise_number(number, range, plural_selectors.other), plural_selectors}

      {number, format} ->
        {number, format}
    end
  end

  # The plural form is chosen from the mantissa's absolute value, as it was
  # when the selection ran on the absolute value and the sign was restored
  # after; the category is the same either way, and the compact selectors
  # carry no exact negative keys.
  defp pluralize_format({mantissa, %{} = plural_selectors}, options) do
    plural_key = pluralization_key(absolute(mantissa), options)

    [format, _number_of_zeros] =
      Localize.Number.PluralRule.Cardinal.pluralize(
        plural_key,
        options.locale,
        plural_selectors
      )

    {mantissa, format}
  end

  defp pluralize_format({mantissa, format}, _options) do
    {mantissa, format}
  end

  # `Decimal.abs/1` rounds to the context precision on the way; the sign
  # alone is wanted.
  defp absolute(%Decimal{} = mantissa) do
    %{mantissa | sign: 1}
  end

  defp absolute(mantissa) do
    abs(mantissa)
  end

  defp get_short_format_rule(number, rules) when is_number(number) and number < 1000 do
    {number, rules.standard}
  end

  defp get_short_format_rule(number, rules) when is_number(number) do
    rules.compact
    |> Enum.filter(fn [range, _rules] -> range <= number end)
    |> Enum.reverse()
    |> hd()
    |> maybe_get_default_format(number, rules)
  end

  # NaN and ±Infinity have no magnitude to compact. TR35 does not say how
  # to compact them; ICU and ECMA-402 write the standard (or currency)
  # format, as for a number below 1000.
  defp get_short_format_rule(%Decimal{coef: coef} = number, rules) when coef in [:NaN, :inf] do
    {number, rules.standard}
  end

  defp get_short_format_rule(%Decimal{} = number, rules) do
    rule =
      number
      |> Decimal.round(0, :floor)
      |> Decimal.to_integer()
      |> get_short_format_rule(rules)

    case rule do
      {_ignore, format} -> {number, format}
      rule -> rule
    end
  end

  defp maybe_get_default_format([_range, %{other: ["0", _]}], number, rules) do
    {number, rules.standard}
  end

  defp maybe_get_default_format(rule, _number, _rules), do: rule

  defp standard_or_currency(options) do
    if options.currency, do: :currency, else: :standard
  end

  # ── Number normalisation ────────────────────────────────────

  defp normalise_number(%Decimal{} = number, range, number_of_zeros) do
    if Decimal.compare(number, @one_thousand) == :lt do
      number
    else
      Decimal.div(number, Decimal.new(adjustment(range, number_of_zeros)))
    end
  end

  defp normalise_number(number, _range, _number_of_zeros) when number < 1000, do: number

  defp normalise_number(number, _range, ["0", _number_of_zeros]), do: number

  defp normalise_number(number, range, [_format, number_of_zeros]) do
    number / adjustment(range, number_of_zeros)
  end

  defp adjustment(range, number_of_zeros) when is_integer(number_of_zeros) do
    trunc(range / Math.power(10, number_of_zeros - 1))
  end

  defp adjustment(range, [_, number_of_zeros]) when is_integer(number_of_zeros) do
    adjustment(range, number_of_zeros)
  end

  # ── Pluralization key ──────────────────────────────────────

  # Per TR35 (Compact Number Formats, step 8) the plural category is
  # determined from the mantissa *as it will be displayed* — after the
  # numeric precision settings are applied. Selecting on the unrounded
  # mantissa while rendering the rounded one produced grammatically
  # impossible output such as es "1 millones" for 1_050_000.
  defp pluralization_key(number, options) do
    round_to_display(number, effective_max_fraction(number, options))
  end

  defp effective_max_fraction(mantissa, options) do
    max_fraction =
      options.fractional_digits || options.max_fractional_digits ||
        compact_max_fraction(mantissa)

    # A caller-supplied negative value must not reach Float.round/2
    # (it raises); the formatter itself treats negatives as zero.
    max(max_fraction, 0)
  end

  # The rounded value must also carry the *visible fraction digits*
  # operand (v) of the displayed form: with a minimum of zero fraction
  # digits an integral mantissa displays as "2" (v = 0), so it is
  # returned as an integer / normalized Decimal, never a float `2.0`
  # whose fraction would leak into plural selection.
  defp round_to_display(%Decimal{} = number, max_fraction) do
    number
    |> Decimal.round(max_fraction, :half_even)
    |> Decimal.normalize()
  end

  defp round_to_display(number, max_fraction) when is_float(number) do
    rounded = Float.round(number, max_fraction)
    truncated = trunc(rounded)

    if truncated == rounded do
      truncated
    else
      Decimal.from_float(rounded)
    end
  end

  defp round_to_display(number, _max_fraction) when is_integer(number) do
    number
  end
end
