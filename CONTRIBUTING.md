🇬🇧 English | 🇫🇷 [Français](CONTRIBUTING.fr.md)

# Contributing to Toolbox

Thanks for your interest! Toolbox is a macOS app written in Swift / SwiftUI, under the GPL-3.0 license. Every
contribution (code, idea, bug report, translation, degree curriculum…) is published under that same license.

## Building

Requirements: macOS 13 or later and Apple's command line tools (`xcode-select --install`).
Full Xcode is not needed.

```bash
./build.sh               # builds, runs the tests, installs into ~/Applications and relaunches the app
./build.sh --no-install  # builds and tests only (output in ./build)
swift run Toolbox        # run without creating the .app
```

## Tests

`build.sh` runs `Toolbox --selftest` after each build. The tests live in
`Sources/Toolbox/SelfTest.swift`: add a `check("…", condition)` for any calculation or text parsing you
change (averages, schedule, LaTeX, archives…). A PR must keep every test green.

## Code layout

```
Sources/PDFCore/   UI-free engine (PDF, OCR, LaTeX, Annalyse, archives…): shared with pdftool
Sources/Toolbox/   the SwiftUI app: one view and a small ObservableObject per tool
Sources/pdftool/   the terminal command
```

A few project rules:
- **No `@State`** in views (the macro is missing from the Command Line Tools on recent SDKs): state lives in an
  `ObservableObject` (often `static let shared`).
- **100% local**: no user data leaves the computer. The only network connections allowed are
  explicit and optional (weather, GitHub, downloading tools).
- **Language**: the interface is in French for now (short sentences, informal “tu”). New strings should be in
  French until the app is localized; if you'd like to work on localization, open an issue first. Code comments are
  mostly French; English is fine for new code.
- A feature tied to specific hardware or a specific situation must be **optional**: hidden through
  `AppProfile` (`Profile.swift`) when the user doesn't need it.

## Recipes

- **Add a tool**: a function in `PDFCore`, a case in the `Tool` enum (`ToolboxApp.swift`: title, icon,
  colour, section, view), and optionally a subcommand in `pdftool/main.swift`.
- **Add a widget**: a case in `HomeWidget` (`HomeWidgets.swift`) and its view in `HomeView.widget(_:)`.
- **Add headphones**: `Headphone.swift` reads Nothing headphones (RFCOMM channel). For another brand, keep the
  same interface (`HeadphoneStore.Reading`: name, percentage, charging, left / right / case) and identify the
  device by its Bluetooth name.
- **Add a degree curriculum**: follow `GradesStore.l1InfoAvignon()` (teaching units, subjects, codes,
  credits = coefficients), then add an entry to the *Year* menu.
- **Show a spot in the guided tour**: `.tourTarget("id")` on the view, then a step in
  `TourStore.buildSteps()` or `TourStore.miniSteps(_:)` (`Tour.swift`).

## Submitting a change

1. Fork the repo, then create a branch (`git checkout -b my-feature`).
2. Build with `./build.sh`: the tests must pass.
3. Update `README.md` (and `README.fr.md` if you can) if your change is visible in the app.
4. Open a Pull Request explaining what changes and how to test it (a screenshot helps a lot).
