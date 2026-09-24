# Building without Xcode

**TL;DR:** run `./dev.sh`, which compiles, swaps the binary into the installed
`/Applications/Crisp.app`, syncs the version from `project.yml`, re-signs, and
relaunches. The rest of this doc explains what it does.

You can build the full .app in Xcode (`xcodegen generate`, then archive), or a
full DMG with `./scripts/release.sh vX.Y.Z` (no Xcode needed). But for the fast
dev loop, the binary alone compiles with just the Command Line Tools:

```sh
./scripts/fetch-sparkle.sh   # once: vendors the Sparkle updater framework
swiftc -O -swift-version 6 -parse-as-library \
  -target arm64-apple-macos14.0 \
  -import-objc-header Crisp/Crisp-Bridging-Header.h \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
  -F vendor/Sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
  Crisp/Views/*.swift Crisp/Utilities/*.swift \
  -o Crisp-bin
```

To run it, swap the binary into an existing Crisp.app install and re-sign ad
hoc (the install must contain `Contents/Frameworks/Sparkle.framework`; installs
of a pre-Sparkle release don't, so use `./dev.sh`, which copies it in):

```sh
pkill -x Crisp
cp Crisp-bin /Applications/Crisp.app/Contents/MacOS/Crisp
xattr -cr /Applications/Crisp.app
codesign --force -s - --entitlements Crisp/Crisp.entitlements /Applications/Crisp.app
open /Applications/Crisp.app
```

This is the fast dev loop: edit, compile, swap, relaunch, no Xcode involved.

## crispctl

`dev.sh` swaps only the app binary. To build the command line tool on its own (the same sources `scripts/release.sh` uses):

```sh
swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
  Sources/crispctl/*.swift Crisp/Models/CrispControlModel.swift Crisp/Models/BrightnessKeySteps.swift \
  -o crispctl
```

With full Xcode, `xcodegen generate && xcodebuild -scheme crispctl -configuration Release` does the same.

## Before opening a PR

Run `make check`: it runs SwiftLint (strict), the unit tests, the x86_64
typecheck, and the localization key check, the same checks CI enforces, so
failures surface locally instead of on the PR. It needs full Xcode plus
`swiftlint` and `xcodegen` (`brew install swiftlint xcodegen`). To run it
automatically on every push, opt in once:

```sh
git config core.hooksPath .githooks
```

The app icon is generated from vector code: `scripts/generate-icon.swift`.
