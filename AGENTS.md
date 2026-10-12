# AGENTS.md

Notes for coding agents working on emvnc, a native macOS VNC viewer. Building, testing and the project layout
are in `README.md`; changes to the vendored RoyalVNCKit are in `Packages/RoyalVNCKit/PATCHES.md`.

## Ground rules

- The repository (`github.com/elvisdragonmao/emvnc`) is **public**. Pushing to `main`, pushing tags and publishing
  releases are visible to everyone: do them only when the maintainer asks, and never force-push `main`.
- Never put credentials, IP addresses, usernames or other details of test machines in commits, release notes or
  workflow logs. Use placeholders such as `10.0.0.5` in examples.
- The product name is **emvnc**, all lowercase, in user-facing text. Swift module and type names keep Swift casing
  (`EmVNCCore`, `EmVNCUI`, `EmVNCApp`).

## How builds and releases work

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/ci.yml` | push to `main`, pull requests | `scripts/test.sh`; `scripts/build-app.sh release` (SwiftPM); `scripts/build-xcode.sh` (universal Release); uploads the app as an artifact |
| `.github/workflows/release.yml` | push of a tag matching `v*` | `scripts/test.sh`; `scripts/build-xcode.sh` with `VERSION` = tag without `v` and `BUILD_NUMBER` = workflow run number; checks architectures, version and signature; publishes a GitHub release with `emvnc-<version>.zip` and `emvnc-<version>.zip.sha256` |

- Both run on `macos-26` with the image's default Xcode (Xcode 26.6 / Swift 6.3 at the time of 1.0.0). Code must
  also compile with that Swift, not only with the newest toolchain installed locally.
- Release notes come from `docs/releases/<tag>.md` when that file exists; otherwise GitHub generates them.
- Tags containing a hyphen (`v1.1.0-beta.1`) are published as pre-releases.
- The Docker integration tests (`scripts/integration-test.sh`) cannot run on GitHub's macOS runners; run them
  locally before a release.
- Actions are pinned to commit SHAs with the version in a comment (`uses: actions/checkout@<sha> # v7.0.1`). To
  update one, resolve the tag yourself (`git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.1*'`),
  replace the SHA and the comment, and run `actionlint`.

## Releasing a new version

Versions follow semantic versioning: `vMAJOR.MINOR.PATCH`, and `vMAJOR.MINOR.PATCH-beta.N` for pre-releases.
The examples use `1.1.0`.

1. **Start from a clean, current `main`.**

   ```sh
   git switch main && git pull --ff-only && git status --short   # must print nothing
   ```

2. **Run the checks CI cannot run, plus the unit tests.**

   ```sh
   scripts/test.sh
   scripts/integration-test.sh      # needs Docker running
   scripts/build-xcode.sh           # needs Xcode; builds build/Release/emvnc.app (universal)
   ```

3. **Bump the version in the source**, so local builds report the same version as the release. It appears in
   three files:
   - `project.yml`: `MARKETING_VERSION`
   - `emvnc.xcodeproj/project.pbxproj`: `MARKETING_VERSION`, twice (Debug and Release). Regenerate the project with
     `xcodegen generate`, or edit both lines.
   - `scripts/build-app.sh`: the default in `VERSION="${VERSION:-…}"`

   Leave `CURRENT_PROJECT_VERSION` alone; the release workflow sets the build number.

4. **Write the release notes** in `docs/releases/v1.1.0.md`. Follow `docs/releases/v1.0.0.md`:
   - no top-level heading (the workflow sets the release title to `emvnc 1.1.0`)
   - what changed
   - install steps using the versioned zip name
   - the Gatekeeper note (see *Signing* below)
   - what was and was not tested
   - known limitations

5. **Commit and push, then wait for CI to pass on that commit.**

   ```sh
   git add project.yml emvnc.xcodeproj scripts/build-app.sh docs/releases/v1.1.0.md
   git commit -m "Release 1.1.0"
   git push origin main
   gh run list --workflow ci.yml --branch main --limit 1          # note the run id
   gh run watch <run-id> --exit-status
   ```

   Do not tag a commit whose CI run failed.

6. **Tag the commit CI verified and push the tag.** This starts the release.

   ```sh
   git tag -a v1.1.0 -m "emvnc 1.1.0"
   git push origin v1.1.0
   gh run list --workflow release.yml --limit 1
   gh run watch <run-id> --exit-status
   ```

7. **Verify what was published.**

   ```sh
   dir="$(mktemp -d)"
   gh release download v1.1.0 --repo elvisdragonmao/emvnc --dir "$dir"
   cd "$dir"
   shasum -a 256 -c emvnc-1.1.0.zip.sha256
   ditto -x -k emvnc-1.1.0.zip .
   lipo -archs emvnc.app/Contents/MacOS/emvnc                                   # x86_64 arm64
   codesign --verify --strict emvnc.app
   plutil -extract CFBundleShortVersionString raw emvnc.app/Contents/Info.plist   # 1.1.0
   ```

   To launch it without touching the maintainer's saved connections, run
   `EMVNC_DATA_DIR="$dir/data" emvnc.app/Contents/MacOS/emvnc`. Do not launch the x86_64 slice with
   `arch -x86_64` on the maintainer's Mac without asking: since macOS 26.4 that shows a Rosetta end-of-support alert.

## When a release goes wrong

- **The workflow failed before the "Publish the release" step** (no release exists yet):
  - If the failure was transient, rerun it with `gh run rerun <run-id> --failed`.
  - If the code needed a fix, push the fix to `main`, wait for CI, and move the tag. This is the only case where
    moving a tag is acceptable, because nobody can have downloaded anything yet:

    ```sh
    git tag -d v1.1.0 && git push origin :refs/tags/v1.1.0
    git tag -a v1.1.0 -m "emvnc 1.1.0" && git push origin v1.1.0
    ```

- **A published release is broken:** do not move or delete its tag. Fix it on `main` and release a new patch
  version (`v1.1.1`). Delete or edit a published release only when the maintainer asks.
- **The release notes need a correction:** edit `docs/releases/<tag>.md` on `main`, then run
  `gh release edit <tag> --notes-file docs/releases/<tag>.md`.

## Signing and notarization

Releases are signed ad hoc and are **not notarized**, so users must allow the first launch in *System Settings ▸
Privacy & Security ▸ Open Anyway*. Every release note must say so until this changes.

Distributing without that prompt needs an Apple Developer ID, which the project does not have set up. Do not add
signing or notarization to the release workflow until the maintainer provides the credentials as repository
secrets. Those would be:
- a *Developer ID Application* certificate (`.p12`, base64) and its password
- an App Store Connect API key or app-specific password for `notarytool`

The workflow would then:
1. Import the certificate into a temporary keychain.
2. Sign with `codesign --options runtime --timestamp`.
3. Submit with `xcrun notarytool submit --wait`.
4. Staple the ticket with `xcrun stapler staple`.
5. Zip the app.
