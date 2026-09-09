# Releasing Sotto

`VERSION` is the macOS marketing version, currently **0.1.0**. Tags use `v0.1.0`. The app's build number is 1; increment it for a replacement build and never overwrite a published tag. Update VERSION and RELEASE_NOTES.md before each release. The iOS prototype retains its separate Xcode project version and is not shipped by this workflow.

## Personal-use CI downloads

Every successful architecture job uploads `Sotto-app-ARM64` or `Sotto-app-X64` after tests, resource checks, and artwork validation. Each artifact contains an ad-hoc-signed native app ZIP and its SHA-256 checksum. Packaging re-extracts the ZIP and verifies the app signature, required resources, and CLI launch before upload. These downloads need no Apple Developer account or CI signing secrets; GitHub sign-in is needed to download artifacts.

These are explicitly unnotarized development builds. They do not use the signed release workflow below, do not create version tags or GitHub Releases, and are subject to Actions artifact retention. macOS may require an explicit first-launch approval and renewed permissions after updates.

## Signing

Local builds use free ad-hoc signing. Public macOS distribution uses a **Developer ID Application** certificate from an Apple Developer Program membership and Apple's notarization service. Apple lists membership at US$99/year (or local currency). This workflow does not publish an unsigned fallback.

Create a Developer ID Application certificate in your Apple developer account, install it with its private key, then export the identity as a password-protected `.p12` from Keychain Access. Do not commit certificates, passwords, or keys.

Configure these GitHub Actions repository secrets:

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 encoding of the exported certificate **and private key** |
| `CERTIFICATE_PASSWORD` | Nonempty password used to export the `.p12` |
| `SOTTO_SIGNING_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Developer team ID |
| `APPLE_APP_PASSWORD` | Apple app-specific password for notarization |

The workflow imports the identity into a temporary runner Keychain and deletes it and the `.p12` afterward. Signing uses the hardened runtime, a timestamp, and the microphone entitlement. Missing credentials, failed tests, failed signing/notarization, or failed Gatekeeper assessment stop publication.

## Checks

```sh
swift test
python3 scripts/test-release.py
SOTTO_APP_PATH="$PWD/.build/ci/Sotto.app" SOTTO_UNIVERSAL=1 scripts/build.sh
python3 scripts/check-bundle.py .build/ci/Sotto.app --universal
python3 design/icon/source/rebuild.py --check
```

These offline tests never require a real Groq key or microphone access. CI runs on Apple Silicon and Intel macOS runners. Packaged-app checks cover version, identity, required artwork, signatures, CLI launch, and (for releases) both architectures. Manual microphone, shortcut, auto-paste, permission, and signed-download tests remain necessary; unit tests do not certify them.

## Publish

After credentials are configured and changes are committed and pushed:

```sh
git tag -a v0.1.0 -m 'Sotto v0.1.0'
git push origin v0.1.0
```

The tag triggers tests, builds a universal app, signs it, submits it to Apple, staples the notarization ticket, and checks Gatekeeper. Only then does it create a public GitHub release with `Sotto-0.1.0-macOS-universal.zip` and `SHA256SUMS`. The tag must match VERSION. No app-store submission or automatic in-app updater is included.

For a local signed dry run, set the same identity and Apple notarization variables and run `scripts/release.sh`; this creates files under `.build/distribution` but does not publish them. The identity must already exist in your local Keychain. Notarization uploads the app to Apple. Inspect `.build/distribution/notarization.json` for submission status; a failed submission must be diagnosed before rerunning.

Sources: [Apple membership](https://developer.apple.com/programs/enroll/), [Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).
