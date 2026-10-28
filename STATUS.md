# Status

**Status:** active, 2026-10-28

Localize 1.4.3 is on hex, released on 2026-10-27: the third patch of 1.4.0, which was released on 2026-10-23 on CLDR 49, the version the `cldr-49` branch merged into `main` was waiting for. Nothing blocks the next release. The work planned is in `TODO.md`: the `localize_mf1` sibling library for ICU MessageFormat 1 and the string form of a date or time skeleton it needs, reading CLDR's JSON in place of its XML wherever the JSON carries the data, and the Indian calendar's era in `und` and `en`. Calendrical, Tempo and the other Localize libraries publish against it.
