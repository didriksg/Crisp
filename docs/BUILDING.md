# Building without Xcode

The full .app bundle requires Xcode (`xcodegen generate`, then archive, or
`./build.sh` for a DMG). But the binary itself compiles with just the Command
Line Tools:

```sh
swiftc -O -swift-version 5 -strict-concurrency=minimal -parse-as-library \
  -import-objc-header Crisp/Crisp-Bridging-Header.h \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
  Crisp/Views/*.swift Crisp/Utilities/*.swift \
  -o Crisp-bin
```

To run it, swap the binary into an existing Crisp.app install and re-sign ad
hoc:

```sh
pkill -x Crisp
cp Crisp-bin /Applications/Crisp.app/Contents/MacOS/Crisp
xattr -cr /Applications/Crisp.app
codesign --force -s - --entitlements Crisp/Crisp.entitlements /Applications/Crisp.app
open /Applications/Crisp.app
```

This is the fast dev loop: edit, compile, swap, relaunch, no Xcode involved.

The app icon is generated from vector code: `scripts/generate-icon.swift`.
