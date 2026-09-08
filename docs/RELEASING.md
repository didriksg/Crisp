# Releasing

Normal flow is unchanged: `./scripts/release.sh vX.Y.Z notes.md --publish`
(see the script header for setup). The Sparkle auto-update chain adds the
steps below.

## Every release

After `--publish` finishes, commit and push `docs/appcast.xml` together with
the `project.yml` version bump. In-app updates go live only when GitHub Pages
serves the new appcast; until then installed apps simply keep waiting (they
never break, they just see no update).

## crispctl

`release.sh` compiles `crispctl` universal from the same source list as the `crispctl` target in `project.yml` and puts it at `Crisp.app/Contents/MacOS/crispctl`, signed inside-out before the app like Sparkle's nested code. Settings links it into `/usr/local/bin`; the cask needs the same link once, through a `binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"` line under the `app` stanza. That line has to land *after* a version bump that ships crispctl, never before: Homebrew raises `CaskError, "It seems the binary source ... is not there"` (`cask/artifact/symlinked.rb`) when the target is missing, so a `binary` line against a cask still pinned to a release without crispctl fails every `brew install`. Since the version bump belongs to the bot (see Homebrew below), the order is: wait for the autobump PR to merge, then send one PR adding the single `binary` line. Done once, for 1.6.0; later releases need nothing here.

## Signing and notarization

`release.sh` signs, notarizes and staples two separate artifacts: the app,
and the DMG around it. Both are needed, and a stapled ticket on its own is
not enough. Measured on a quarantined DMG with `spctl -a -t open --context
context:primary-signature`:

| DMG state | verdict |
| --- | --- |
| unsigned, no ticket | `rejected: no usable signature` |
| unsigned, ticket stapled | `rejected: no usable signature` |
| signed, no ticket | `rejected: Unnotarized Developer ID` |
| signed, notarized, stapled | `accepted: Notarized Developer ID` |

The second row is the trap: `stapler validate` reports "The validate action
worked!" while Gatekeeper still refuses the disk image, because there is no
signature for the ticket to attach to. Trust `spctl`, not `stapler`.

Two submissions are unavoidable. Apple issues tickets per artifact hash, so
one submission cannot staple both the app and the DMG. Stapling only the DMG
would also work for most people, but the app dragged out of it would then
need an online check with Apple on first launch.

Both `codesign` and `stapler staple` rewrite the DMG, so they run before the
DMG is hashed and uploaded; the Homebrew cask pins the `sha256` of the
uploaded file. The `spctl` call at the end of that block is a gate rather
than a log: under `set -e`, a DMG Gatekeeper would reject aborts the release
instead of shipping.

## Homebrew

The cask lives in homebrew/cask (`Casks/c/crisp.rb`, added in
Homebrew/homebrew-cask#283611), and there is nothing to do per release.

Every cask in the official repo is autobumped unless it says otherwise, so
BrewTestBot owns the version and sha256. It checks every three hours and opens
the bump PR itself. Bumping by hand is not an option and not just discouraged:
`brew bump-cask-pr crisp --version X.Y.Z` refuses with "has its version update
pull requests automatically opened by BrewTestBot", there is no `--force`, and
`brew livecheck --cask crisp` answers "Skipping crisp as it is autobumped".
Only a cask carrying `no_autobump!`, a `livecheck` block with `skip`, or an
active `deprecate!`/`disable!` is bumped by hand. Anything that is not a
version bump, the `binary` line above for instance, is still an ordinary PR.

How the bot finds a release: the cask has no `livecheck` block, so livecheck
picks the `GithubLatest` strategy off the download URL and turns it into
`https://api.github.com/repos/didriksg/Crisp/releases/latest`, reading the
version off the tag with `v?(\d+(?:\.\d+)+)`. That endpoint ignores drafts
and prereleases, so marking a release as a prerelease hides it from Homebrew
entirely.

`auto_updates true` does not mean brew stops upgrading Crisp. With it,
`brew upgrade` compares the *installed app bundle's* CFBundleShortVersionString
against the cask version (`Cask#outdated_version`, gated on
`HOMEBREW_UPGRADE_AUTO_UPDATES_CASKS`, which defaults to true) instead of
trusting its own install receipt. So a user still on the old build gets the
new one from a plain `brew upgrade`, with no `--greedy`, while a user whose app
already updated itself through Sparkle is skipped rather than having a running
app quit and replaced by the same version. `--greedy` only matters for
`version :latest` casks or when `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS` is set.

One consequence for crispctl: the `binary` symlink is created by a cask
install, so it appears for new installs and for anyone whose `brew upgrade`
actually reinstalls. Someone who moves version through Sparkle keeps the tool
inside the bundle and uses the Command Line Tool switch in Settings.

The old tap (`didriksg/homebrew-tap`) only carries a `tap_migrations.json`
entry now; installs from it move to the main cask on their next
`brew upgrade`.

## The signing key

Updates are EdDSA-signed. The private key lives in the maintainer's login
Keychain (created once with `./vendor/Sparkle/bin/generate_keys`); the public
half is pinned in `scripts/release.sh` as `SUPublicEDKey`. A backup of the
private key is stored in Bitwarden.

- Lost key: no future updates can be signed. Restore from Bitwarden with
  `generate_keys -f <file>`.
- Leaked key: treat like a leaked Developer ID key; an attacker who also
  gains GitHub access could ship signed updates. Rotation is painful (old
  installs pin the old public key), so custody beats rotation.
- Never commit or log the private key. `generate_appcast`/`sign_update` read
  it from the Keychain automatically at publish time.

## Testing an update locally (no publish)

Build the "old" and "new" versions with two dry runs, serve a signed feed
from localhost, and let the old build update itself:

1. `./scripts/release.sh v9.9.8`, copy `build/Crisp.app` somewhere writable,
   point its `SUFeedURL` at `http://localhost:8765/appcast.xml` with
   PlistBuddy and re-sign ad hoc.
2. `./scripts/release.sh v9.9.9`, put `Crisp.dmg` in a feed dir, run
   `./vendor/Sparkle/bin/generate_appcast --download-url-prefix
   http://localhost:8765/ -o <feeddir>/appcast.xml <feeddir>`, then
   `python3 -m http.server 8765` in the feed dir.
3. Quit the installed Crisp first (single-instance lock), launch the test
   copy, and use the panel's Update row. Delete the `SU*` keys from
   `defaults read com.crisp.app` afterwards.
