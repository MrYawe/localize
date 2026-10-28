# Status

**Status:** active, 2026-10-28

Localize 1.4.3 is on hex, released on 2026-10-27, and 1.5.0 is prepared for release: currency amount parsing (`parse_currency_amount/2`), which ex_money 6.3.0 needs, with the parser's lenient reading and its refusal of ambiguous amounts. Nothing else blocks it. The `localize_mf1` sibling library for ICU MessageFormat 1 is complete and not yet released. The work planned after it is in `TODO.md`: the string form of a date or time skeleton, which `localize_mf1` needs to format ICU's `{d, date, ::yMMMd}`, reading CLDR's JSON in place of its XML wherever the JSON carries the data, and the Indian calendar's era in `und` and `en`. Calendrical, Tempo and the other Localize libraries publish against it.
