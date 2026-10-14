READY e5bb4d5 FEATURES.md first pass (docs/tools-based), TESTING.md, scripts/qa/* (privacy-scan, verify-export, verify-package, drive-input.swift)

# qa status

## Done (verified)
- docs/FEATURES.md first pass: ~110 rows across 10 areas, tagged [docs]/[technical]/[assumption]. Verified how: reviewed against guide section list (screen.studio/guide) and installed-app file inventory.
- docs/TESTING.md Definition of Done; docs/reference/motion-and-export.md.
- scripts/qa: privacy-scan.sh (run: clean), verify-export.sh, verify-package.sh, drive-input.swift (typechecks; not yet run against a live recording).

## In progress
- M2 refinement of FEATURES.md values (preset lists, defaults).

## Next
- Run verify-package.sh / drive-input against first integrated capture build.

## Blockers
- Reverse-engineering/observation of the installed Screen Studio was denied by the permission classifier (bundle string search and `rea analyze_javascript_application`). So no [observed] rows and no exact option values/defaults. Needs user decision: allow REA/observation of /Applications/Screen Studio.app. Workaround used: guide pages, asset inventory, own assumptions (marked).
- Bundle strings are obfuscated anyway; REA/observation is the only practical route.

## Requests (to Lead)
- None yet.
