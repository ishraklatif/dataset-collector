# Implementation and verification

Updated 2026-10-02. No commit, push, model training, model download, or paid job was performed.

## Workspace

The user's final scope is a fresh standalone single-page collector. The temporary clone, Git metadata, React Native app, unrelated screens/services, and copied reference documentation were removed. Only the detector asset was carried into the new native app. The original repository was never edited.

Model source: `/Users/ishraklatif/Documents/IE26/EachPathHealth-scrum/apps/mobile/assets/model/yolo11n-trained-v1.tflite`, source commit `50e467a5d11ca8062394f0379429fb1b093c1bdc`. SHA-256: `455888c9b0bc769b0a6307c324ed59879b706cab6283742d9f5aaf7097bf4937`. Its checksum, actual float32 input `[1,320,320,3]`, output `[1,9,2100]`, and input-pixel box units are checked by the native implementation and exercised in the simulator. Historical export/parity reports refer to a different hash and are not presented as validation of this asset's accuracy or checkpoint lineage. The original five-class mapping is preserved.

## Passed checks

- Standalone iOS simulator build and launch with its own bundle ID/display name and the SDK-required scene lifecycle.
- ARM64 physical-iPhone compilation and a signed development build using the existing signing team.
- Five native tests: exact model loading/CPU inference, decoder box retention and same-class NMS, portrait/landscape geometry round trips and clipping, RGB channel order/top-left rows/gray padding, and canonical JPEG orientation/dimensions.
- Fourteen backend tests against an isolated real local PostgreSQL 15 database: image and box validation; atomic bytea upload; lost-ack and concurrent idempotent retries; conflict rejection; injected transaction rollback; project authorization and session revocation; explicit negatives and stale review checks; editing invalidates approval; deterministic frozen exports survive later edits/discard; empty negative labels; immutable images/revisions/annotation history; interrupted export status; login/expiring capabilities; and logical database restore.
- An independent ZIP reader reopens images, verifies hashes/dimensions/image-label pairing, checks normalized YOLO coordinates against the manifest, and renders labeled previews.
- Shared export links return a text-only download page; ZIP transfer requires a separate deliberate download request, preventing ordinary share-link previews from fetching dataset images or archives.
- A real `pg_dump`/`pg_restore` into a disposable database recovers matching image bytes, approved revisions, frozen membership, and a byte-identical regenerated export.
- Source audit finds no captured-image, annotation, thumbnail, or dataset-archive write path in the iOS application. The only `Data(contentsOf:)` reads the bundled model. Networking uses ephemeral data tasks and no URLCache. Keychain stores credentials; UserDefaults stores only the nonsecret backend endpoint. Background privacy covers are synchronous and scene-based.

Test evidence is in `/private/tmp/eachpath-collector-final-tests.xcresult` and `/private/tmp/eachpath-collector-final-tests.log`; build logs are in `/private/tmp/eachpath-collector-build.log`, `/private/tmp/eachpath-collector-device.log`, and `/private/tmp/eachpath-collector-generic-signed.log`. These are generated artifacts outside the project, not dataset exports on an iPhone.

## Remaining external setup and acceptance gates

1. **Dedicated Neon resource and hosting:** identify or create a dedicated collection database, choose an HTTPS Python backend host, configure a limited runtime role separately from migration credentials, run migrations, create the operator account, and set the final HTTPS endpoint in the app. Enter secrets in backend environment settings or a private ignored local environment, never in the app or chat. No Neon resource or deployment was available to verify during this work. See `services/collector/README.md` and `.env.example`.
2. **Stable physical-device connection:** keep the iPhone connected, unlocked, trusted, and in Developer Mode. It appeared briefly as connected, then became unavailable before installation. The app has not been installed or launched on that physical phone in this run. Allow camera access and trust the development profile if prompted.
3. **Real end-to-end slice:** capture a real photo; confirm draft boxes came from that exact canonical JPEG; verify Neon holds its bytes; review/correct/approve it; freeze and download on the training computer; independently render exported boxes. Check portrait/landscape scenes, edge and small objects, several objects of the same class, false positives, missed objects, and an explicitly approved negative.
4. **Physical no-persistence check:** inspect Documents, Library, Caches, and tmp before/after capture, review, retry/failure, backgrounding, and relaunch. Verify no dataset image/frame/thumbnail/annotation/ZIP files appear and switcher snapshots obscure displayed images. Simulator and source checks do not establish this physical acceptance gate.
5. **Cloud operational checks:** confirm host body/header limits and no disk request spooling, TLS/pooling, quota/cost limits, and a chosen Neon backup retention policy. Perform a restore into an isolated Neon target and compare hashes/revisions/versions before real collection. The local restore test does not verify Neon recovery.

The implementation is available for review and local testing. Milestones 1–3 cannot be claimed fully accepted until physical-device and deployed Neon/API checks pass. Dataset preparation, actual offline training, and model promotion remain later work.
