# Launch runbook: KokoroBooks in the App Store

Everything that can be automated is. What is left needs the Apple Developer
account holder, because Apple does not expose it through any API. The whole
list takes about 20 minutes.

**State of play (13 November 2026)**

| | |
|---|---|
| Release build | Archives and signs. Bundle `de.outspoken.kokorobooks`, team id from `KB_IOS_TEAM_ID`. |
| App ID and App Store profile | Created automatically by Xcode in the developer account. |
| Listing, screenshots, privacy and support pages | Ready, tested, live. |
| Demo library for reviewers | Live: five books, 30 hours, no server needed. |
| App record in App Store Connect | Created. |
| First build | **Uploaded to TestFlight** (13 November 2026). |
| App Store Connect API key | Not on this Mac. |

## 1 · Create the app record (5 min, web)

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → *Apps* → **+** → *New App*.

| Field | Value |
|---|---|
| Platforms | iOS |
| Name | `KokoroBooks` (taken? use `KokoroBooks Audiobooks`) |
| Primary language | English (U.S.) |
| Bundle ID | `de.outspoken.kokorobooks` (already in the list) |
| SKU | `kokorobooks-ios` |
| User access | Full access |

## 2 · Create an API key (3 min, web)

*Users and Access* → *Integrations* → *App Store Connect API* → **Team Keys** →
generate a key with the **App Manager** role. Download the `.p8` once, note the
*Key ID* and the *Issuer ID*, and put them where the scripts read them:

```bash
mkdir -p ~/.config/kokorobooks && chmod 700 ~/.config/kokorobooks
cat > ~/.config/kokorobooks/asc.env <<'EOF'
export APP_STORE_CONNECT_KEY_ID=XXXXXXXXXX
export APP_STORE_CONNECT_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export APP_STORE_CONNECT_KEY_PATH=$HOME/.config/kokorobooks/AuthKey_XXXXXXXXXX.p8
EOF
chmod 600 ~/.config/kokorobooks/asc.env
```

The org already keeps a shared key in Infisical (`shared-store`). Reusing it is
fine; copy its three values instead of creating a new key.

## 3 · Add your phone number (1 min)

Apple wants a number the reviewer can call. Edit `KB_REVIEW_PHONE` in
`~/.config/kokorobooks/ios.env`.

## 4 · Ship the build to TestFlight (one command)

```bash
source ~/.config/kokorobooks/ios.env
ios/release.sh --upload
```

The upload signs with a cloud-managed distribution certificate, so macOS does
not ask for your keychain. The build appears in TestFlight after a few minutes
of processing. Add yourself under *TestFlight → Internal Testing*, install it
with the TestFlight app, and listen for five minutes with the screen locked,
which is the one thing the automated tests cannot check.

> **If the export fails with "Copy failed":** a Homebrew `rsync` earlier on
> `PATH` is the cause (Xcode needs Apple's own). `release.sh` already puts
> `/usr/bin` first; run `xcodebuild` by hand with the same `PATH` if you
> bypass the script.

## 5 · Upload the listing (one command)

```bash
cd ios
source ~/.config/kokorobooks/ios.env && source ~/.config/kokorobooks/asc.env
fastlane ios metadata
```

This sends the description, keywords, URLs, category, review notes, review
contact and the ten screenshots (6.9" iPhone, 13" iPad). The text lives in
[`ios/fastlane/metadata/`](../ios/fastlane/metadata) and is covered by
[`test_store_metadata.py`](../backend/tests/test_store_metadata.py).

## 6 · Answer the questions only the web form asks (5 min)

| Where | Answer |
|---|---|
| *App Privacy* | **Data Not Collected** for every category. See the [privacy page](https://www.mauli.app/kokorobooks/privacy.html). |
| *Pricing and Availability* | Free, all countries. |
| *Age Rating* | None for everything except *Violence*: **Infrequent/Mild**, because the demo books include a war novel and spy thrillers. The app itself has no web browsing or user content. |
| *Content Rights* | The app **does** access third-party content. You **do** have the rights: public domain. |
| *Export Compliance* | Already answered by `ITSAppUsesNonExemptEncryption = false`. |
| *Advertising Identifier* | No. |

## 7 · Submit

```bash
fastlane ios submit      # attaches the latest build and sends it to App Review
```

Or press *Add for Review* in the web UI. Release is **manual**, so the app does
not go live the moment Apple approves it.

## If review comes back with questions

The three the notes already answer, in the order they usually appear:

1. *No server, so nothing to test.* The demo library needs none. See the notes.
2. *Why does ATS allow arbitrary loads?* Users reach their own server over plain
   HTTP on a LAN. Explained in the notes.
3. *Is the content yours?* Public domain, documented per title in
   [`samples/README.md`](../samples/README.md).

## Optional: CI instead of your Mac

Draft pull request #1 adds a tag-driven TestFlight workflow that fetches its
secrets from Infisical over Tailscale. The Tailscale variables are already set
on the repository. Still missing: `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`
and `APP_STORE_CONNECT_ISSUER_ID` as repository variables, the three secrets
in Infisical, and an `IOS_BUNDLE_ID` variable, because that workflow defaults
to a different bundle identifier than the one registered here. Worth doing
once releases become routine; not needed for the first one.
