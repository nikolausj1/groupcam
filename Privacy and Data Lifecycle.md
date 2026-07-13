# groupCam Privacy and Data Lifecycle

Status: implementation contract for the prototype and public v1.

## 1. Non-negotiable rules

- No backend, account, analytics, advertising, remote configuration, or runtime generative service.
- groupCam never uploads images for processing. Capture and compositing stay on-device.
- Photos or metadata leave only through a user-selected destination such as Apple Photos/iCloud, Share, or the debug-only consented corpus export.
- No persistent face embedding, identity label, or reusable biometric template.
- StoreKit, PhotoKit/iCloud, and Share destinations are Apple/user-directed boundaries, not groupCam processing services.

## 2. Consent and permissions

### Ordinary use

- Before capture, the operator confirms that everyone agrees to be photographed.
- Camera permission is requested only after **Start a group photo**.
- Location is optional, requested separately in context, and denial never blocks capture.
- Photos `.addOnly` permission is requested only on the first Save.
- A joining-photographer tap, when needed, is a normalized point retained only for the active session.

### Benchmark corpus

Written consent is required from every adult before capture. A parent or guardian must authorize every minor. The form must name:

- technical prototype and benchmark purpose;
- transfer to Justin's encrypted local Mac;
- access by Justin, the implementation agent running locally, and two named reviewers;
- no model training, public use, repository use, or unrelated reuse;
- withdrawal process and deletion deadline.

A non-consenting person may not appear in frame. Withdrawal before aggregate publication deletes that participant's sessions and replaces any affected gated session without inspecting its outcome.

## 3. Storage and deletion

| Data | Storage | Retention/deletion |
|---|---|---|
| Full-resolution source frames | App-private, complete file protection, excluded from backup | Delete after confirmed save, Cancel, or Start Over |
| Composite and preview | App-private, protected, excluded from backup | Delete after confirmed save/cancel; unsaved result expires after 2 hours |
| Location | Active-session metadata only | Delete with session; export only when authorized |
| Vision masks, observations, poses | Memory or transient protected files | Release after processing; never retain after session |
| Joining-person tap | Session record | Delete with session |
| Share export | Protected temporary file | Delete on completion/cancel; cold-launch cleanup after 2 hours |
| Selected Photos assets | Apple Photos | User-controlled; groupCam never silently deletes them |
| Recent thumbnail, only if approved | 512-1024 px, Application Support, excluded from backup | At most 50 items or 50 MB; remove oldest first |
| PhotoKit local identifier | Device-local cache, excluded from backup | Delete when its Recent record is removed |
| Free-save count | Keychain | Persists locally across an ordinary reinstall |
| StoreKit entitlement | StoreKit/Apple | Apple-managed |
| Public diagnostics | Failure enum and current-session timings only | Delete with session |
| Ordinary debug logs | Image-free | At most 7 days or 50 sessions |
| Benchmark corpus | Encrypted local Mac storage outside Dropbox/iCloud/repository | Delete 90 days after final gate decision and no later than 180 days after capture |

On every cold launch, delete abandoned full-resolution sessions, orphaned proxies, and share exports older than two hours. Deletion means removing app-managed files and confirming their paths no longer exist; do not claim secure physical overwrite on flash storage.

## 4. Corpus export boundary

The approved corpus root for this Mac is `$HOME/GroupCamPrivateCorpus`. FileVault was verified on at project kickoff, the root and its `incoming`, `development`, `evaluation`, `consent`, and `aggregate` subfolders are owner-only (`0700`), and the path is outside Dropbox and iCloud. Re-verify those properties before the first participant session and after any storage migration.

The public app has no source-image debug export. A debug build may expose **Corpus Export** only after the operator explicitly confirms that the written benchmark consent requirements are satisfied. It streams the source HEIFs, monotonic AVFoundation events, 60 Hz Core Motion samples, and capture metadata into one uncompressed ZIP package so a session cannot be split accidentally. The operator must use the system share sheet to move that package to the approved encrypted non-cloud Mac location, verify it, and remove any local staging copy. Never send it through Dropbox, iCloud Drive, `_inbox`, the repository, OpenAI, Gemini, or another cloud AI service.

Ordinary debug diagnostics remain image-free and are a separate action.

## 5. Export metadata allowlist

- Selected originals retain their own timestamp, authorized location, orientation, color profile, and valid source camera metadata.
- The composite may contain creation date, authorized side-one location, normalized orientation, output color profile, camera make/model, and `Software = groupCam`.
- Strip MakerNote, depth, portrait matte, gain map, burst identifiers, and stale capture-only metadata from the composite.

## 6. Network test

Run connected privacy cases for clean launch, permission denials, complete 1x/0.5x processing, save, cancellation, and cold-launch cleanup. Run airplane-mode processing for each lens and a cached free/Pro entitlement. Test StoreKit purchase, cancel, restore, and offline-unavailable separately.

The gate is zero app-originated image/metadata network requests and zero app-controlled upload bytes containing a photo, thumbnail, EXIF, location, person output, or session identifier. User-directed Share, Apple Photos/iCloud behavior, and Apple-managed StoreKit traffic are excluded from that assertion.

Before release, statically audit for unauthorized URLSession/socket/WebView/telemetry paths, inventory dependencies and privacy manifests, and ensure App Privacy answers match observed behavior. Any new SDK, network capability, broad Photos access, persistent identity analysis, or cloud feature requires Justin's approval and a revised privacy review.
