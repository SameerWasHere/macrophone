# Releasing Macrophone for Mac

The Mac app ships outside the App Store as a Developer ID–signed, notarized DMG from
sameer.us/macrophone, and updates itself with Sparkle. One script does the whole release:
`Mac/scripts/release.sh <version> <build>`.

(The iPhone app ships through App Store Connect — see `docs/APP_STORE.md`.)

## One-time setup

Do these once per Mac you release from.

1. **Developer ID Application certificate** (set up Oct 14 2026). Apple lets only the Account
   Holder create one, and only on developer.apple.com, so it's done in two halves:
   - **On this Mac:** the private key was made here and imported into the login keychain (it shows
     as "Imported Private Key"; codesign may use it without asking). Its certificate request is
     the file uploaded to Apple. **Back the key up** with the certificate once it's paired:
     Keychain Access › My Certificates › "Developer ID Application: …" › Export (.p12).
   - **On developer.apple.com** (Certificates › + › Developer ID Application › G2 Sub-CA ›
     upload the request) — SameerOS hands this to Muse.
   Then pull the certificate into the keychain with the App Store Connect API (any team key can
   read it) and check it pairs:

   ```sh
   Mac/scripts/install-developer-id.sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   `release.sh` stops at the first step and says so until this exists.

2. **Notarization credentials** (set up Oct 14 2026): the `macrophone-notary` keychain profile uses
   the App Store Connect API key (no app-specific password):

   ```sh
   xcrun notarytool store-credentials macrophone-notary \
     --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER>
   xcrun notarytool history --keychain-profile macrophone-notary   # "No submission history" = working
   ```

3. **The Sparkle signing key — back it up now.** Every update is signed with an EdDSA key.
   The private key lives **only in your login keychain** (item "Private key for signing
   Sparkle updates", account `macrophone`); its public half is `SUPublicEDKey` in
   `Mac/Resources/Info.plist`:

   ```
   IxzbNL1yRnBdye3uORtW/JZ1eZJAT3Of9K2PDzeDvQM=
   ```

   If the private key is lost, installed copies can never accept another update — people
   would have to download the app again by hand. Export it and keep it somewhere safe and
   offline (a password manager's secure note is fine):

   ```sh
   cd Mac && xcodegen generate && xcodebuild -resolvePackageDependencies -project Macrophone.xcodeproj -scheme Macrophone -derivedDataPath build/release
   # (if no build has fetched Sparkle yet: xcodebuild -resolvePackageDependencies -project Macrophone.xcodeproj -scheme Macrophone -derivedDataPath /tmp/mp-sparkle)
   /tmp/mp-sparkle/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account macrophone -x ~/Desktop/macrophone-sparkle-key.txt
   # store the file's contents in your password manager, then:
   rm -P ~/Desktop/macrophone-sparkle-key.txt
   ```

   To restore on a new Mac: `generate_keys --account macrophone -f <that file>`.
   Never generate a new key for Macrophone — `release.sh` refuses to publish if the keychain
   key and `SUPublicEDKey` differ.

4. **Tools:** Xcode 27, `brew install xcodegen`.

5. **The DMG's window layout** needs nothing: `scripts/dmg/dsstore.py` writes the window's
   `.DS_Store` (icon view, size, icon positions, the background) straight onto the volume, so
   Finder isn't scripted and no Automation permission is asked for. Eject any mounted
   "Macrophone" volume before a release (the script stops if one is in the way).

## Each release

1. **Pick the numbers.** Version is what people see (`1.0.1`); build is a whole number that
   only ever goes up (`2`). Sparkle compares the build.

2. **Write the release notes** at `Mac/release-notes/<version>.html` (copy the last one).
   Plain words, a few bullets. They show in the update window.

3. **Run the release:**

   ```sh
   cd ~/claude-projects/Macrophone
   Mac/scripts/release.sh 1.0.1 2
   ```

   It archives Release, exports it signed with Developer ID (hardened runtime, timestamped),
   checks the signatures (the app, Sparkle, and the `macrophone` command-line tool inside
   `Contents/Helpers/`), notarizes and staples the app, builds the DMG (app + Applications
   alias over `scripts/render-dmg-background.swift`'s background, laid out by
   `scripts/dmg/dsstore.py`, with the app's icon on the volume), signs, notarizes and
   staples the DMG, signs it for Sparkle, and writes into
   `~/claude-projects/_web/sameer-gpt/public/macrophone/`:

   | File | Served at |
   | --- | --- |
   | `releases/Macrophone-<version>.dmg` | the version history |
   | `releases/Macrophone-latest.dmg` | the stable download link |
   | `releases/notes-<version>.html` | Sparkle's release notes |
   | `releases/appcast.xml` | the appcast (all versions, newest first) |
   | `appcast.xml` | the same appcast at the feed URL in Info.plist (`SUFeedURL`) |

   Notarization usually takes 2–10 minutes per submission (there are two: the app, then the DMG).

4. **Publish.** In `~/claude-projects/_web/sameer-gpt`, commit `public/macrophone/` and push
   to `main`; Vercel deploys it.

5. **Check it.**
   - Download `https://sameer.us/macrophone/releases/Macrophone-latest.dmg`, open it, drag to
     Applications, launch — no Gatekeeper warning.
   - `spctl --assess --type execute -vv /Applications/Macrophone.app` → `accepted`,
     `source=Notarized Developer ID`.
   - In an older installed copy: menu bar › Check for Updates… offers the new version.

## A rehearsal without publishing

```sh
Mac/scripts/release.sh 1.0.0 1 --dry-run
```

Builds Release signed with your Apple Development certificate, skips notarization, and writes
everything — DMG, Sparkle signature, appcast, notes — into `Mac/dist/<version>/` (the website
repo isn't touched). Use it to check a change to the pipeline.

## If something goes wrong

- **"No Developer ID Application certificate"** — step 1 of the one-time setup.
- **Notarization "Invalid"** — the script saves Apple's log next to the DMG in
  `Mac/dist/<version>/notary-log-*.json`; it names the file and the problem (usually a
  binary without hardened runtime or a missing timestamp).
- **"The Sparkle key in the keychain doesn't match SUPublicEDKey"** — you're on a Mac
  without the backed-up key. Restore it (one-time setup, step 3). Don't change the plist.
- **A bad release is out** — ship a fixed one with a higher build number. To stop new
  downloads first, point `Macrophone-latest.dmg` back at the previous DMG and remove the bad
  `<item>` from both appcast files, then push.
