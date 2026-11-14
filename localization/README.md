# English and Simplified Chinese

`Shared/Resources/Localizable.xcstrings` ships the same English and `zh-Hans` app-owned strings in the app and share extension. Each target has its own `Resources/InfoPlist.xcstrings` for permission explanations. The app follows the iOS app-language setting; English remains the fallback.

Wire enum values, API paths/keys, SF Symbols, identifiers, user content and server messages keep their original values. Computed display strings use `String(localized:)`; direct SwiftUI literals use compiler extraction. Count helpers use complete phrases rather than English suffixes. The numeric photo/video phrases include English singular/plural catalog variants.

After a simulator build, collect actual compiler keys and validate shipped coverage:

```sh
python3 scripts/collect-localizations.py --output /private/tmp/imora-localization-keys.json
python3 scripts/check-localizations.py --keys /private/tmp/imora-localization-keys.json
```

The scripts accept a different DerivedData path (`collect-localizations.py --derived-data`). `scripts/localization-inventory.swift` is an additional audit tool using SwiftSyntax bundled with the Xcode toolchain; it distinguishes string literals and their call/property contexts. The reviewed translation authoring map is `zh-Hans.json`. To regenerate the catalog after reviewing new keys and translations:

```sh
python3 scripts/build-localization-catalog.py --keys /private/tmp/imora-localization-keys.json
```

Regeneration preserves English source text, checks complete translation coverage, and assigns plural variants to the central numeric photo/video keys. Validate the resulting catalog, build both targets, and inspect actual English/Chinese UI. The validator permits an explicit small set of unchanged brands, formats, symbols and URL/slug examples; additions need review.

Tests require the dedicated local Immich fixture for server/UI integration. No production server or personal photo is needed. Missing fixture/device capabilities are skipped explicitly. See `tests/integration/README.md` and `docs/validation/` for the recorded scope and remaining physical-device gates.
