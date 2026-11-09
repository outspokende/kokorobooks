# KokoroBooks Store Release

## Current target

KokoroBooks currently contains an iOS app, generated from `ios/project.yml` with XcodeGen. There is no Android project in this repository, so this pipeline builds and uploads only the iOS app.

## CI and TestFlight

- Pull requests and pushes to `main` build the generated iOS Simulator target without signing.
- A tag `koko-vMAJOR.MINOR` or `koko-vMAJOR.MINOR.PATCH` builds a signed IPA and uploads it to TestFlight.
- The workflow uses GitHub OIDC to join the private Tailnet and fetch secrets from Infisical. It does not publish a release to the public App Store.

## GitHub repository variables

The shared Infisical and Tailscale variables are maintained centrally and are already configured for this repository. Add these app-specific variables before a TestFlight run:

- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- Optional `IOS_BUNDLE_ID` (default `com.henningjaeger.kokorobooks`)

## Infisical secrets

`shared-store`:

- `APP_STORE_CONNECT_KEY_P8`
- `IOS_DIST_CERT_P12_BASE64`
- `IOS_DIST_CERT_PASSWORD`

`kokoro-books`:

- `IOS_PROVISIONING_PROFILE_BASE64` for the bundle ID and Apple team above

Create the App Store Connect app record and matching Apple signing profile first. Enter values only in Infisical from their original sources; never put them in Git or chat. A production review submission remains a separate App Store Connect action after the build has passed TestFlight review.

## Related documentation

- [Repository README](../README.md)
- [iOS client setup](../ios/README.md)
