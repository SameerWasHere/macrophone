# Is "Macrophone" a safe name?

Checked October 12, 2026. Not legal advice; a trademark attorney's clearance search is the
real answer if the product grows.

## Verdict

**Usable, with moderate risk. Launch as Macrophone, follow Apple's "Mac" rules to the letter,
don't try to register it as a trademark, and keep a fallback name ready.** Nobody else is using
the name, but it contains Apple's "Mac" mark fused into a coined word, which Apple's
guidelines tolerate only under conditions and which Apple can object to at any time. If App
Review or Apple pushes back, rename to **Wiremic** (first choice below).

## 1. Apple's rules on "Mac" in a product name

Apple's *Guidelines for Using Apple Trademarks and Copyrights* (third parties):

- General rule: you may not use or register an Apple trademark "in whole or in part" as or as
  part of a company, product or service name, "except as specifically noted in these
  guidelines." Item 4 of the proper-use rules adds: "Do not make up names that contain Apple
  trademarks."
- **"The Mac Trademark" section is the specific exception.** A third party may use "Mac" in a
  product name only if *all* of these hold:
  | Condition | Macrophone |
  | --- | --- |
  | Not a computer, computer system or OS | Pass — an app |
  | Mac-compatible / associated with Mac computers | Pass — the companion is a Mac app |
  | "Mac" combined with another non-generic, non-geographic word | **Grey** — "Macrophone" is a single coined word; "-rophone" isn't a word on its own. It reads as "Mac" + "microphone" |
  | "Mac" not more prominent than the rest (size, colour, typeface) | Pass if the wordmark is set in one style (it is: one serif word, no capital-M emphasis beyond the first letter) |
  | No false association with Apple | Pass with care — the site says it's independent and not endorsed |
  | Not confusingly similar to an Apple mark | Pass — no Apple product of that name |
  | Acknowledge Apple's ownership of "Mac" | **Done** — the website footer now carries the attribution line |
- "Mac" may never be used alone except for Apple's Macintosh line, and Apple marks must not
  be used as a second-level domain name (so no `mac-something.com` built on the mark itself;
  `sameer.us/macrophone` is fine).

App Store specifics:

- **App Review Guideline 5.2.1** — don't use protected third-party material, including
  trademarks, "without permission"; **5.2.4** — don't imply Apple endorsement; **5.2.5** — don't
  look confusingly similar to an Apple product. There's no rule that names "Mac" in an app name
  specifically, and many apps use "Mac" compounds, but a reviewer *can* cite 5.2.1.
- **App Store marketing guidelines** — refer to Apple products in a referential phrase ("App
  name for iPhone"), never "iPhone App name"; don't suggest an association with Apple. The
  listing and site already follow this ("Macrophone for Mac", "the iPhone app").

Reading: the name is defensible under the Mac exception, but it's the weakest kind (fused,
not "Mac" + a real word), so it depends on Apple's tolerance. Apple has historically
tolerated Mac compounds from independent developers (MacPaw, MacUpdate and many others) and
enforces mostly against confusing or Apple-looking uses. The realistic downside is a review
rejection or a request to rename, not a lawsuit.

## 2. Is "Macrophone" taken?

| Where | Finding |
| --- | --- |
| App Store (US + UK, iPhone and Mac) | No app named Macrophone. Search returns only generic "Microphone" apps. |
| Web / products | No product, company or brand using the name. |
| USPTO | One record: **MACROPHONE, serial 78106793**, filed Feb 4, 2002 (Class 9: microphones, audio recorders, voice-recognition software) by Audiophoric Inc. — **abandoned** July 15, 2003 (no statement of use). No live filing found. A fresh search in the USPTO's Trademark Search tool is still worth doing before launch. |
| macrophone.com | Registered since Jan 13, 2004 (Dynadot); responds 403, no product. Not available. |
| macrophone.app | Registered Jun 24, 2026 — check whether that was Sameer; if not, it's taken. |
| macrophone.co | Unregistered (DOMAIN NOT FOUND). |
| Our URL | sameer.us/macrophone — fine, and what the apps already point to. |

Registering "Macrophone" as a trademark ourselves is not recommended: an application
containing "Mac" invites an Apple opposition, and the abandoned 2002 filing shows the word
has been tried for the same class before.

## 3. Alternatives, if it becomes a problem

Checked against the App Store search API (no app with that name) and RDAP for the `.app`
domain. All avoid Apple marks entirely.

| Name | Why it fits | App Store | Domain |
| --- | --- | --- | --- |
| **Wiremic** (first choice) | Says what it is: a wireless mic for your computer. Short, ownable, easy to say | No match | wiremic.app unregistered; wiremic.com taken |
| **Relaymic** | Your voice relayed to the Mac; works for agents too | No match | relaymic.app unregistered; .com taken |
| **Talkwire** | Talk in, text out over the wire; friendlier tone | No match | talkwire.app unregistered; .com taken |
| **Pocketmic** | The mic you already carry | No match | pocketmic.app unregistered |
| **Voicewire** | Clear, slightly more formal | No match | voicewire.app taken |

Renaming is cheap now: `Product.name` / `Product.website` in
`Packages/MacrophoneKit/Sources/MacrophoneKit/Core/Product.swift`, the bundle display names,
the site path (`public/macrophone` + two rewrites in `vercel.json`), and the listing in
`APP_STORE.md`. Bundle ids (`com.sameer.macrophone`) can stay as they are; users never see them.

## Sources

- Apple, *Guidelines for Using Apple Trademarks and Copyrights* (third parties), incl. "The Mac Trademark" — https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html
- Apple, *App Review Guidelines* §5.2 Intellectual Property — https://developer.apple.com/app-store/review/guidelines/#intellectual-property
- Apple, *App Store Marketing Guidelines* (product names, referential use) — https://developer.apple.com/app-store/marketing/guidelines/
- USPTO record via Justia: MACROPHONE, serial 78106793 (abandoned 2003) — https://trademarks.justia.com/781/06/macrophone-78106793.html
- App Store search API, `term=macrophone` (US, GB; software and macSoftware) — https://itunes.apple.com/search?term=macrophone&entity=software
- WHOIS / RDAP lookups for macrophone.com, .app, .co, and the alternatives (rdap.org), run Oct 12 2026
