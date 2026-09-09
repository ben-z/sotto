# Releasing Sotto

`VERSION` is the macOS marketing version. Release tags must match it (`v<version>`). Update VERSION and RELEASE_NOTES.md before a new release. Never overwrite a published version; the iOS prototype is not part of this workflow.

## Automatic release assets

Publish a GitHub release using the website or:

```sh
version=$(cat VERSION)
gh release create "v$version" --target main --title "Sotto v$version" --notes-file RELEASE_NOTES.md
```

The **published release** event runs tests and resource checks on Apple Silicon and Intel, then builds a universal app, packages it, re-extracts it, verifies the signature/resources/executable, and attaches `Sotto-<version>-macOS-universal.zip` and `SHA256SUMS` to that release. Assets appear after the workflow succeeds. A bare tag push does not publish a release or start attachment; publishing a draft does. Downloads from public release assets do not require a GitHub account.

By default these are **ad-hoc-signed personal-use builds**, with no Apple account or signing secrets required. They are not Apple-notarized. State that clearly in release notes; macOS may require first-launch approval and renewed permissions after updates. The workflow fails on invalid mode/version, failed tests, packaging, or upload; it does not overwrite existing assets. Publish a new version to replace a released build.

Local equivalent (creates files but does not publish):

```sh
scripts/release.sh --adhoc
```

If GitHub does not deliver the release event, trigger the same CI build for an existing published tag:

```sh
gh workflow run release.yml -f tag=v0.1.5
```

Both testing and packaging check out the requested tag. Existing assets are never overwritten; a failed upload must be investigated before retrying.

## Optional Developer ID signing and notarization

Set the repository Actions variable `SOTTO_NOTARIZE` to exactly `true` to request notarized releases. The default is `false`. An invalid value fails. There is **no fallback** if notarization was requested but credentials are missing or Apple rejects the submission.

Create a **Developer ID Application** certificate through the Apple Developer Program, install it with its private key, and export that identity as a password-protected `.p12`. Configure these Actions secrets:

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 certificate **and private key** export |
| `CERTIFICATE_PASSWORD` | Nonempty export password |
| `SOTTO_SIGNING_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

The workflow uses a temporary runner Keychain, hardened runtime, timestamp, and microphone entitlement. It notarizes, staples, and checks Gatekeeper before attaching files, then removes signing material. Never commit certificates or credentials. The local equivalent is `scripts/release.sh --notarized`, with the identity installed and notarization environment variables set. Running without an explicit mode also requests notarization.

## Development CI artifacts

Every successful CI architecture job also uploads `Sotto-app-ARM64` or `Sotto-app-X64`, containing a native ad-hoc app ZIP and checksum. These are available before a release, require GitHub sign-in, and expire according to artifact retention. They are separate from public release assets.

## Validation

CI checks core behavior, diagnostics, resource budgets, release prerequisites, artwork, and packaged apps. Local release preflight tests: `python3 scripts/test-release.py`. Manual microphone, shortcut, paste, and first-install checks remain necessary; packaging checks do not certify macOS permission grants. Notarization remains unverified until real Apple credentials are configured. Sotto checks for updates and links to release downloads; installation is manual. No Mac App Store submission or automatic installer is included.

Sources: [Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [first-launch approval](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).
