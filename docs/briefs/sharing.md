# Brief: sharing (architecture only)

Status: design. Nothing in this brief is implemented. No hosting service, account, payment or
recurring cost may be set up for it without a separate decision by the user. Yapcam stays fully
local by default.

## Goal

Later on, a finished export should be able to become a link that someone else can open, the way
Loom does it. The local app must not depend on this: recording, editing and exporting keep working
offline, and sharing stays an optional step after an export.

## Shape

```
Editor / quick export ──► Exporter (YapcamRender) ──► local file (as today)
                                                   │
                                                   ▼
                                     ShareCoordinator (new, YapcamUI)
                                                   │ ShareRequest(file, title, transcript?, poster frame?)
                                                   ▼
                                 ShareProvider protocol (new module YapcamShare)
                ┌───────────────────────┬──────────────────────────┬────────────────────────┐
                ▼                       ▼                          ▼
     LocalFolderProvider       UserBucketProvider          (future providers)
     copy + sidecar page       user's own S3-compatible   only with a user decision
     into a chosen folder      storage, user credentials   and documented costs
```

- **ShareProvider** (protocol, Swift): `id`, `displayName`, `isConfigured`,
  `func share(_ request: ShareRequest, progress: …) async throws -> ShareResult`,
  `func revoke(_ result: ShareResult) async throws`. Providers never see the project package,
  only the exported file plus optional metadata the user chose to include.
- **ShareResult**: provider id, URL or file location, created time, a revoke token. Stored in the
  project package under `shares.json` (additive in FORMATS.md when built) so the editor can list and
  revoke earlier shares.
- **ShareCoordinator** runs after a successful export (never on a partial file), shows progress and
  errors in the existing export UI, and is cancellable.

## Providers that fit the rules

1. **LocalFolderProvider**: copies the export and a small static HTML page (video tag, title,
   optional transcript) into a folder the user picks, for example a synced folder they already use.
   No network code in Yapcam. This is the first one to build.
2. **UserBucketProvider**: uploads to storage the user owns (S3-compatible endpoint, bucket, key).
   Credentials live in the user's Keychain, are entered by the user in Settings, are never logged or
   written to the package, and the provider shows exactly which file goes where before uploading.

A hosted Yapcam service (accounts, comments, view counts) is out of scope: it needs hosting and
ongoing costs.

## Privacy

- Sharing is always an explicit action per export. There is no background upload and no telemetry.
- What leaves the Mac is shown before it leaves: file, size, and whether a transcript or poster frame
  is included (both off by default).
- Revoking deletes the remote object or the local copy and removes the entry from `shares.json`.

## Order of work, when the user approves

1. Module skeleton, `ShareProvider` protocol, `shares.json` format, coordinator in the export UI.
2. LocalFolderProvider with tests (atomic copy, page generation, revoke).
3. UserBucketProvider behind its own decision (it is network code, so it gets a threat model first).
