# Versioning

The iOS source has its own version sequence, independent of the Linux/WSL
builder. `master` is the stable source line. Feature work belongs on
development branches such as `johnmama12-ios-app-publishing`; those branches
are not stable releases. Merge reviewed, validated work to `master` before
publishing a release. Versions use Git tags and GitHub Releases in the form
`vMAJOR.MINOR.PATCH[-beta.N]`. Releases are cut from `master`; ordinary commits
and experiments do not get version tags. The builder's source picker lists
published releases by default and offers branches separately for development
builds.

## What to increment

| Change to the iOS source | Version change |
| --- | --- |
| Fix a bug, crash, compatibility issue, or small regression without changing behavior intentionally | Increment `PATCH` after a stable release |
| Add a backwards-compatible app feature or supported capability | Increment `MINOR` after a stable release |
| Change behavior or compatibility in a way that requires users to adapt | Increment `MAJOR` after `1.0.0` |
| Publish another build of the same beta target | Increment `beta.N`, for example `v0.1.0-beta.1` to `v0.1.0-beta.2` |
| Expand the planned beta release enough to start a new release cycle | Increment `MINOR` and reset beta to 1, for example `v0.1.0-beta.2` to `v0.2.0-beta.1` |

Before `1.0.0`, the public app behavior is not considered stable; use a `MINOR`
version for a breaking change and reserve `PATCH` for fixes that do not
intentionally break existing behavior. After `1.0.0`, use `MAJOR` for breaking
changes.

## Beta and stable sequence

The latest published source version is `v0.1.0-beta.1`. The controller
replacement was planned for `v0.2.0-beta.1`; the expanded settings and
performance feature set starts a new planned cycle at `v0.3.0-beta.1`.
Subsequent builds in that cycle increment the beta number, and the stable
`v0.3.0` release follows validation. The app's numeric bundle version is set to
`0.3.0` during development; each distributable build must also receive a new
monotonically increasing `CFBundleVersion`.

For each release:

1. Confirm the source builds and record tested devices, iOS versions, and known
   limitations in the release notes.
2. Update `CFBundleShortVersionString` in `src/ios/app/Info.plist` to the
   numeric release version (for example `0.1.0`).
3. Increase `CFBundleVersion` to a new monotonically increasing integer for
   every published app build, including beta builds.
4. Create an annotated Git tag on the intended `master` commit and publish a
   matching GitHub Release with concise user-facing notes. Do not move or reuse
   a published tag.

The release tag identifies the source selected by the builder. It does not
imply support for untested ROM regions or devices. The generated app package is
local-use-only under the renderer license; do not attach or distribute compiled
binaries.

The builder has its own independent version policy in the builder repository's
`VERSIONING.md`.
