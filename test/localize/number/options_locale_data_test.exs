defmodule Localize.Number.OptionsLocaleDataTest do
  # `Localize.Number.Format.Options.validate_options/2` resolves a locale's
  # number system, symbols, formats and minimum grouping digits once per
  # locale and number system and keeps them in `Localize.FormatCache`
  # (#67). A cached resolution must be the same as a fresh one, and the
  # same as the lookups it replaces.
  use ExUnit.Case, async: true

  alias Localize.FormatCache
  alias Localize.Number.Format
  alias Localize.Number.Format.Options
  alias Localize.Number.Symbol

  defp key(locale_id, system) do
    {:localize, :number_locale_data, locale_id, system}
  end

  describe "the resolved locale data" do
    test "is kept in the format cache after the first resolution" do
      assert {:ok, %Options{}} = Options.validate_options(0, locale: :en)

      assert {:ok, locale_data} = FormatCache.lookup(key(:en, :default))
      assert locale_data.system_name == :latn
      assert locale_data.minimum_grouping_digits == 1
      assert %{standard: "#,##0.###", currency_spacing: %{}} = locale_data.formats
      refute Map.has_key?(locale_data.formats, :decimal_short)
      assert %Symbol{decimal: %{standard: "."}} = locale_data.symbols
    end

    test "is the same resolved from the cache as resolved afresh" do
      FormatCache.clear()
      assert {:ok, fresh} = Options.validate_options(0, locale: :es, currency: :EUR)
      assert {:ok, cached} = Options.validate_options(0, locale: :es, currency: :EUR)
      assert cached == fresh
    end

    test "matches the lookups it replaces" do
      {:ok, language_tag} = Localize.validate_locale(:de)
      assert {:ok, options} = Options.validate_options(0, locale: language_tag)

      assert options.number_system == :latn
      assert {:ok, options.symbols} == Symbol.number_symbols_for(language_tag, :latn)
      assert {:ok, %Format{standard: standard}} = Format.formats_for(language_tag, :latn)
      assert options.format == standard

      assert {:ok, options.locale_minimum_grouping_digits} ==
               Format.minimum_grouping_digits_for(language_tag)
    end

    test "carries the locale's minimum grouping digits apart from the option" do
      assert {:ok, options} = Options.validate_options(0, locale: :es)
      assert options.locale_minimum_grouping_digits == 2
      assert is_nil(options.minimum_grouping_digits)

      assert {:ok, options} = Options.validate_options(0, locale: :es, minimum_grouping_digits: 1)
      assert options.locale_minimum_grouping_digits == 2
      assert options.minimum_grouping_digits == 1
    end
  end

  describe "the cache key" do
    test "is the locale and the number system as asked for" do
      assert {:ok, %Options{number_system: :latn}} = Options.validate_options(0, locale: :ar)
      assert {:ok, %{system_name: :latn}} = FormatCache.lookup(key(:ar, :default))

      assert {:ok, %Options{number_system: :arab}} =
               Options.validate_options(0, locale: :ar, number_system: :native)

      assert {:ok, %{system_name: :arab}} = FormatCache.lookup(key(:ar, :native))

      assert {:ok, %Options{number_system: :arab}} =
               Options.validate_options(0, locale: :ar, number_system: :arab)

      assert {:ok, %{system_name: :arab}} = FormatCache.lookup(key(:ar, :arab))
    end

    test "takes a tag's -u-nu- as the number system" do
      assert {:ok, options} = Options.validate_options(0, locale: "en-u-nu-thai")
      assert options.number_system == :thai
      assert {:ok, %{system_name: :thai}} = FormatCache.lookup(key(:en, :thai))
      assert options.format == "#,##0.###"
      assert Localize.Number.to_string(1234.5, options) == {:ok, "๑,๒๓๔.๕"}
    end

    test "keeps nothing for an unknown number system" do
      assert {:error, %Localize.UnknownNumberSystemError{}} =
               Options.validate_options(0, locale: :en, number_system: :nonesuch)

      assert FormatCache.lookup(key(:en, :nonesuch)) == :miss
    end
  end

  describe "formatting with the cached data" do
    test "writes the same string as before the cache" do
      assert Localize.Number.to_string(1234.5, locale: :en) == {:ok, "1,234.5"}
      assert Localize.Number.to_string(1234.5, locale: :es) == {:ok, "1234,5"}
      assert Localize.Number.to_string(12_345.5, locale: :es) == {:ok, "12.345,5"}

      assert Localize.Number.to_string(1234.5, locale: :de, currency: :EUR) ==
               {:ok, "1.234,50\u00A0€"}

      assert Localize.Number.to_string(1234.5, locale: :ar, number_system: :arab) ==
               {:ok, "١٬٢٣٤٫٥"}

      assert Localize.Number.to_string(1234, locale: :en, format: :short) == {:ok, "1.2K"}

      assert Localize.Number.to_string(1234, locale: :en, number_system: :roman) ==
               {:ok, "MCCXXXIV"}
    end
  end
end
