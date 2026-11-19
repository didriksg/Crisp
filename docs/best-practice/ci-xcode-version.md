# Xcode version in CI

Date: 2026-11-19. Applies to Crisp (Swift 6, deployment target macOS 14, CI needs at least the macOS 26 SDK for `NSGlassEffectView`, releases built on Didrik's Mac with Xcode 27.0 build 27A266a). Serves the open item "move CI to an Xcode 27 runner" (the #236 fix sits behind `#if compiler(>=6.4)`, so CI never compiles it). Check it again after 2027-05-19, or earlier when GitHub changes the image list.

## Short answer

GitHub now hosts an Xcode 27 image, and it is generally available. It is a separate label, `xcode-27`, not `macos-27`: no `macos-27` label exists. The image runs macOS 27.0.1 on Apple Silicon only. It has Xcode 27.0 (27A266a, at `/Applications/Xcode_27.app`), 27.1 (default) and 27.2. So the Xcode that Didrik releases with is installed, and CI can compile the `#if compiler(>=6.4)` code.

## Recommendation and what Crisp does

Crisp builds on `xcode-27` only, with the image's default Xcode (`/Applications/Xcode.app`, which the Makefile already uses), in both jobs. This deviates on purpose from the common practice below of a two-entry matrix (Didrik, 2026-11-19). Releases are built with Xcode 27, so the shipped code is the code CI should compile, and only `xcode-27` compiles the code behind `#if compiler(>=6.4)`. A `macos-26` entry would only guard builds by contributors who are still on Xcode 26: users never get such a build, few people build Crisp, a contributor who hits an error says so in their PR, and that entry failed a pull request on 2026-11-19 over code that Xcode 27 accepts (a method reference passed as a `Binding` setter). The `#else` branches for the older compiler are no longer compiled in CI; delete them once nobody needs Xcode 26.

CI follows the image's default Xcode (27.1 today) and does not pin 27.0, the version on Didrik's Mac: a pinned path disappears when GitHub replaces a patch version, and a minor version apart is close enough for a build check.

## Runner labels

From the runner-images repository and the GitHub docs: the arm64 macOS labels are `macos-latest`, `macos-26` and `macos-26-xlarge` (macOS 26.7.2, default Xcode 26.6), `macos-15` and `macos-15-xlarge`, and `xcode-27` and `xcode-27-xlarge` (macOS 27.0.1). Intel labels are `macos-26-intel`, `macos-26-large`, `macos-15-intel`, `macos-15-large`. `macos-14` is deprecated and the images retired on 2026-11-02. `macos-latest` still points at macOS 26. The `xcode-27` image was a public preview from 2026-07-16, moved from macOS 26 to macOS 27 on 2026-09-10, and became generally available on 2026-10-15 (a second post has the same title on 2026-10-16, so the exact day is slightly unclear). The `-xlarge` suffix is a larger size for GitHub Actions only; the plain `xcode-27` label is enough here. The xcode-27 image is arm64 only.

## Xcode versions per image

The `macos-26` image (20261102.0473.1) has Xcode 26.6 (default, build 17F113), 26.5, 26.4.1, 26.3, 26.2, 26.1.1 and 26.0.1, each at `/Applications/Xcode_<version>.app`, with `/Applications/Xcode.app` linked to the default. The `xcode-27` image (20261104.0337.1) has 27.2 (27B52), 27.1 (27A9275, default) and 27.0 (27A266a), at `/Applications/Xcode_27.2.app`, `Xcode_27.1.app` and `Xcode_27.app`. It carries the macOS 27.0 and 27.2 SDKs and iOS, tvOS, watchOS and visionOS simulator runtimes. The `macos-26` image has no Xcode 27.

## Selecting a non-default Xcode and GitHub's policy

The runner-images README and the GitHub docs page do not document `xcode-select` or `DEVELOPER_DIR` for macOS runners (the fetched pages had no mention). The paths above are the documented fact, and the two selection methods are standard Apple tooling that every runner has. The third-party `maxim-lobanov/setup-xcode` action (`xcode-version: '27.0'`, `latest-stable`, quoted so YAML keeps the trailing `.0`) wraps the same step but adds a dependency; it is not needed when the path is known. Policy as stated in the runner-images repository: each image supports one major Xcode version, all minor versions of that major are kept, a new patch version replaces the previous patch version, beta and RC versions appear as is only on the latest image, and only three major.minor versions of platform tools and simulator runtimes stay. The README does not say how fast new versions arrive. The evidence is that a preview image existed from 2026-07-16 (during the Xcode 27 beta) and the image went generally available on 2026-10-15.

## Known problems

None found. The runner-images pages list no known-issues section for either image, and a search found no open issue for the `xcode-27` image. A third-party guide (IT Knowledge Lab, July 2026) lists general risks for a new Xcode image: arm64-only tooling, dependency drift, stale caches and simulator differences. Of those only caches and dependency installs matter to Crisp, which runs `xcodebuild test` on the macOS destination with no simulator; `brew install swiftlint xcodegen` runs on arm64 on both images. A planned change, the default OpenSSL moving from 3 to 4 on `macos-26` and `xcode-27`, does not touch the build.

## Common practice

Official and community guidance both say to run the new image next to the stable one while it is validated, with `fail-fast: false`, and to make it required only after it passes (the IT Knowledge Lab guide suggests `continue-on-error` for the new entry at first). For an app that ships on the newest Xcode and also builds for contributors on the previous one, a two-entry matrix is the usual shape: the old entry guards the compatibility floor, the new one guards the shipping toolchain. Crisp's case is stronger than usual because the code behind `#if compiler(>=6.4)` exists only in one of the two. Since Xcode 27 on `xcode-27` is generally available, the new entry can be required from the start.

## Not confirmed

Whether the `xcode-27` image's macOS 27 host changes any Crisp test result was not tested; run the matrix once on a branch. Queue times for `xcode-27` were not measured; the GitHub docs warn that macOS jobs can wait in busy periods. The GitHub docs list the same CPU and memory size for `xcode-27` and `macos-26`. The exact GA date and how quickly past Xcode releases were added were not confirmed.

## Sources (accessed 2026-11-19)

- GitHub, actions/runner-images (image and label table, Xcode support policy): https://github.com/actions/runner-images
- macOS 26 arm64 image readme: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md
- Xcode 27 arm64 image readme: https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
- GitHub docs, GitHub-hosted runners reference: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- GitHub changelog, Xcode 27 runner image now in public preview (2026-07-16): https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview
- GitHub changelog, Xcode 27 runner image now runs on macOS 27 (2026-09-10): https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27
- GitHub changelog, Xcode 27 runner image generally available (2026-10-15 and 2026-10-16): https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available and https://github.blog/changelog/2026-10-16-xcode-27-runner-image-generally-available/
- maxim-lobanov/setup-xcode: https://github.com/maxim-lobanov/setup-xcode
- IT Knowledge Lab, Xcode 27 GitHub Actions guide (third party): https://itknowledgelab.com/blog/xcode-27-github-actions-guide-2026
