# Launching Macrophone 1.0

Everything that can be done without your Apple account is done. What's left needs you to be
signed in as yourself. Each part is short.

## 0. Once, for both apps (5 min)

1. **Xcode › Settings › Accounts › +** → sign in with your Apple ID; pick team **8523EX5882**.
2. Confirm `macrophone@sameer.us` actually receives mail (the website and the App Store listing
   both show it as the support address), or tell Claude another address to use.

## 1. The Mac app → downloadable from sameer.us/macrophone (10 min)

1. **Developer ID certificate:** Xcode › Settings › Accounts › your team › **Manage
   Certificates… › + › Developer ID Application**. (Needs the Account Holder role on the team.)
2. **Notarization password:** make an app-specific password at
   [appleid.apple.com](https://appleid.apple.com) › Sign-In and Security › App-Specific
   Passwords, then run this and paste it when asked:

   ```bash
   xcrun notarytool store-credentials macrophone-notary --apple-id sbhutani95@gmail.com --team-id 8523EX5882
   ```
3. **Back up the Sparkle update key** (if it's lost, installed copies can never update again).
   Run these two commands, then move `macrophone-sparkle-key.txt` from your Desktop into your
   password manager and delete it from the Desktop:

   ```bash
   cd ~/claude-projects/Macrophone/Mac && xcodebuild -resolvePackageDependencies -project Macrophone.xcodeproj -scheme Macrophone -derivedDataPath /tmp/mp-sparkle >/dev/null
   ```

   ```bash
   /tmp/mp-sparkle/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account macrophone -x ~/Desktop/macrophone-sparkle-key.txt
   ```
4. Tell Claude **"release the Mac app"**. It runs `Mac/scripts/release.sh 1.0.0 1` (archive,
   Developer ID signature, notarization, the DMG, the update feed), copies the DMG to the website,
   flips the site's `LIVE.mac` switch so the buttons say **Download for Mac**, pushes, and checks the
   live download.

## 2. The iPhone app → App Store (about 30 min, then Apple's review)

The full listing (name, subtitle, description, keywords, privacy answers, review notes,
screenshots) and the step-by-step are in `docs/APP_STORE.md` › "Submit in 10 minutes".
In short:

1. [App Store Connect](https://appstoreconnect.apple.com) › Apps › **+ › New App**: iOS, name
   **Macrophone**, bundle id **com.sameer.macrophone**, SKU `macrophone-ios`.
2. Paste the listing from `docs/APP_STORE.md`; upload the screenshots in
   `iOS/docs/store-screenshots/6.9/` and `/6.5/`; App Privacy → **Data Not Collected**.
3. Xcode: open `iOS/Macrophone.xcodeproj` (run `xcodegen generate` in `iOS/` first) › choose
   **Any iOS Device** › **Product › Archive** › **Distribute App › App Store Connect › Upload**.
4. Back in App Store Connect: pick the build, paste the App Review notes, **Submit for Review**.
5. When it's approved: tell Claude **"the iPhone app is live"** with its App Store link. It puts
   the real app id into the site, flips `LIVE.ios`, and pushes.

## Known decisions to revisit later

- **The name.** "Macrophone" is usable but fuses Apple's "Mac" into a coined word; don't try to
  register it as a trademark. Fallback name: **Wiremic**. Details: `docs/NAME_CHECK.md`.
- **Real-network check.** Pairing and delivery are proven on home Wi-Fi only. Try office Wi-Fi
  that isolates devices and a hotel network once before telling people about it.
