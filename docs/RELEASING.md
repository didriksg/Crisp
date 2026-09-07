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

`release.sh` compiles `crispctl` universal from the same source list as the `crispctl` target in `project.yml` and puts it at `Crisp.app/Contents/MacOS/crispctl`, signed inside-out before the app like Sparkle's nested code. Settings links it into `/usr/local/bin`; the cask needs the same link once. Right after the first release that ships it, send homebrew/cask one PR by hand with the version bump, the new sha256 and `binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"` under the `app` stanza (`brew bump-cask-pr crisp --version X.Y.Z` builds the bump; add the line to the same commit). Do not wait for autobump: it only moves the version, and a `binary` line against a release whose bundle has no crispctl breaks `brew install`.

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
Homebrew/homebrew-cask#283611). Homebrew's autobump job runs every three
hours, sees the new GitHub release through livecheck, and opens and merges
the version bump itself. Nothing to do per release. If a release is still
missing from `brew info --cask crisp` after a day, open the bump by hand:
`brew bump-cask-pr crisp --version X.Y.Z`. `auto_updates true` is in the
cask, so `brew upgrade` reconciles against the on-disk version instead of
reinstalling over an app that updated itself.

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
