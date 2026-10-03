# EachPath Health AR Dataset Collector: Implementation Handoff

Prepared: 2026-10-01

Storage decision, updated 2026-10-01: all durable dataset content, including image bytes, belongs in Neon Postgres. Do not persist frames, photos, annotations, or dataset archives on the iPhone. Temporary RAM buffers are necessary for capture, inference, upload, and display. This supersedes any earlier suggestion of offline SQLite storage or R2/S3 image storage.

## Objective

Build a standalone, single-screen iOS dataset collector using EachPath Health's existing five-class object detector. Capture new photographs, generate draft labels and bounding boxes with the current model, allow human correction, and export a verified dataset for later offline retraining.

The collector reduces annotation effort. Model confidence and repeated detections do not establish ground truth. New training samples must be reviewed. Improvement is an outcome to measure, not a guarantee.

Assumption: new photographs can be collected, but a larger external dataset is unavailable. This workflow does increase the dataset. If the constraint prohibits any new images, revisit the approach before implementation.

## Workspace and Existing Work

- New workspace: `/Users/ishraklatif/Documents/IE26/EachPathHealth-AR-Collector`.
- Reference repository: `/Users/ishraklatif/Documents/IE26/EachPathHealth-scrum`.
- Branch observed during planning: `AC5.2`.
- Proposed implementation branch: `feature/ar-dataset-collector`.
- No collector implementation, model training, or build was performed during planning.

The reference repository had uncommitted changes and untracked files, including iOS project changes, model candidates, scripts, and planning documents. Recheck its state before starting. Do not reset, clean, stash, commit, or overwrite the user's work automatically.

Implement inside the new workspace. Prefer an independent local repository copy/clone for isolation, then transfer only required, inspected uncommitted changes and locally available assets. A clone includes committed content only: compare the source working tree before deciding what must be brought over. Keep this handoff file intact when initializing the workspace; do not attempt to clone into a nonempty directory without arranging the destination appropriately. Record the source commit and transferred changes. Do not copy credentials, caches, node_modules, build products, or whole training environments.

Preserve relevant source-repository instructions. If IBWD is available, use it first for supported navigation and read the local ibwd-navigation skill. Confirm which repository its index serves before relying on results in the new workspace. If unavailable or outside scope, state that and use ordinary source search. Do not run paid model jobs, benchmarks, or model downloads as part of implementation. Focused deterministic checks and physical-device functional verification are appropriate.

## Current Feature: Verified Code Findings

Paths below are relative to the reference repository. Recheck them because this is a snapshot of the code inspected during planning.

| Area | Existing implementation |
| --- | --- |
| App shell | `apps/mobile/App.tsx`; `apps/mobile/index.js` wraps it in SafeAreaProvider |
| AR screen | `apps/mobile/src/screens/ARCameraScreen.tsx` |
| Camera | `apps/mobile/src/components/CameraViewport.tsx`, using rear-camera VisionCamera frame output |
| Inference | `apps/mobile/src/ml/useKitDetectionInference.ts` |
| Model | `apps/mobile/assets/model/yolo11n-trained-v1.tflite` |
| Model loading | `apps/mobile/src/ml/modelLoader.ts`; default CPU delegate |
| Decoder | `apps/mobile/src/ml/decodeYoloDetections.ts` |
| Preprocessing | `apps/mobile/src/ml/letterboxPadding.ts` |
| Checklist orchestration | `apps/mobile/src/hooks/useKitScanner.ts` |
| Checklist rules | `apps/mobile/src/ar/componentScan.ts`, `scanController.ts` |
| Training/export tools | `services/ml-kit-detection/scripts/` |
| Training context | `docs/mobile/yolo11n-dataset-v3-training-handoff.md` |
| Device/export evidence | `docs/mobile/ar-acceptance-evidence.md` |
| Field failure context | `EachPathHealth_AR_Detection_Failure_Log.md` |

The runtime uses a fine-tuned YOLO11n TFLite detector with float32 input `[1,320,320,3]` and output `[1,9,2100]`. Camera frames are resized to 320 x 320 RGB using contain scaling; padding is corrected to gray 114/255. Inference runs every tenth camera frame in a worklet.

The decoder uses a 0.50 confidence floor and same-class NMS at IoU 0.45. It reads bounding boxes internally but returns only class ID, class name, and confidence. Preserve boxes in the collector's detection representation.

The current checklist uses per-class thresholds currently all set to 0.68, five qualifying consecutive observations within two seconds, and a 30-inference attempt cap. It saves kit-check progress, not images or training annotations. These rules are product checklist behavior, not annotation-quality guarantees. Build a separate collection controller while reusing appropriate low-level inference code.

The installed camera package exposes photo capture and saving APIs, and Nitro Image exposes image conversion and pixel access. Verify exact installed signatures before implementing. Still-photo inference and coordinate alignment remain to be implemented and tested; live-camera preprocessing cannot be assumed equivalent without checks.

This workflow needs camera-based detection, not ARKit world tracking.

### Fixed Class Mapping

| ID | Class |
| --- | --- |
| 0 | collection_tube |
| 1 | kit_package |
| 2 | reply_paid_envelope |
| 3 | toilet_liner |
| 4 | ziplock_bag |

Keep IDs identical in the decoder, annotations, data.yaml, training checkpoints, and exported model metadata. Do not invent a background class or introduce untrained classes.

## Scope

### Initial Deliverable

A standalone iOS app that launches directly into collection, captures a photograph into memory, runs the model on that photograph, uploads image bytes and draft annotations to Neon through an authenticated backend, supports correcting all annotations, and creates versioned datasets for export to a training computer. Dataset collection and review require connectivity.

Use a distinct display name and bundle identifier so it can coexist with the main app. Reuse existing native configuration where appropriate and verify signing on the actual device.

### Deferred Work

- Automatic capture suggestions, after the manual path passes acceptance checks.
- Actual offline model training and candidate promotion, after an approved dataset exists.
- Multi-user collaboration, public account registration, and on-device training. Authenticated online dataset storage in Neon is required in the initial deliverable.
- Model architecture changes or new target classes.

## Phase 1: Isolate and Simplify the App

1. Inspect source status, instructions, dependencies, required native patches, and model assets.
2. Establish the new workspace and implementation branch; document provenance.
3. Give the collector a separate app identity and configure its backend endpoint. Store only authentication credentials in Keychain; do not add local dataset persistence.
4. Replace the app entry with the collector screen while preserving required providers.
5. Keep permissions, camera lifecycle management, model loading, preprocessing, and decoding.
6. Build successfully before pruning unrelated journey screens, guidance content, animations, assets, and dependencies. Check references and native integration before removing anything.
7. Exclude collected images, exports, local training data, and generated build products from Git.

Acceptance: the isolated app builds and launches on a physical iPhone without altering the original app or repository.

## Phase 2: Single-Screen Collection Experience

Use one main screen with capture, review, and dataset-management states or sheets.

### Capture

- Rear-camera preview and proposed live bounding boxes with class/confidence labels.
- Capture button available even when nothing is detected.
- Session controls, sample counts, pending-review count, and export action.
- Explicit permission, unavailable-camera, model-loading, inference-error, offline, uploading, upload-failed, and server-confirmed states. Disable capture when the backend is unavailable; an availability check does not guarantee an upload will succeed.
- Pause camera/inference appropriately while backgrounded or reviewing a photo.

### Review

- Display the database-backed image and its proposed boxes using a memory-only image-loading path.
- Select a box, change its class, move/resize it, or delete it.
- Add boxes for missed objects, including multiple instances of a class.
- Support undo for annotation edits and zoom/pan for small objects.
- Accept, leave pending, or discard the capture.
- Explicitly confirm an empty-label negative when no target objects are present.

### Dataset Sheet

- Browse pending and approved samples, reopen review, and remove samples deliberately.
- Show both image counts and object-instance counts per class to avoid confusing them.
- Show session grouping, server-confirmed save/review status, and export status. Counts come from Neon; never count an unacknowledged upload as saved.

Use existing UI conventions and lucide-react-native icons where suitable. Controls must remain usable around safe areas, keyboard presentation, and different device dimensions.

## Phase 3: Correct Image and Box Geometry

This is the first technical acceptance gate.

1. Preserve accepted boxes through decoding, alongside class and confidence.
2. Capture into RAM and encode a canonical upright image with known dimensions without writing a file. Upload those exact bytes to Neon through the backend.
3. Run inference on the canonical encoded image decoded in memory, with verified RGB channel order, float normalization, contain geometry, and gray padding. This makes the predicted image match the stored bytes, including JPEG compression effects.
4. Do not associate the most recent live-camera detection with a later photograph. Motion and different capture geometry can make those labels wrong.
5. Reverse model-input padding and scale to map boxes into saved-image pixels. Verify the model's coordinate units from the actual artifact/output rather than assuming them.
6. Clip boxes to image bounds and reject nonfinite or degenerate results.
7. Store annotations in canonical image coordinates. Derive preview and editor coordinates separately, including zoom, pan, display scaling, cropping, orientation, and mirroring where applicable.
8. Store useful-resolution canonical images in Neon, not screenshots with UI overlays or only the padded model input. Define a configurable image-size limit that fits the API/driver deployment and preserves small-object detail; validate before reducing quality.

Acceptance: reopen exported images independently and render exported boxes; boxes align in portrait, landscape, edge-object, small-object, and multi-object examples. Round-trip coordinate checks pass for known geometry. Verify still-image preprocessing against the model contract and do not silently apply EXIF rotation twice.

## Phase 4: Annotation Review and Provenance

Every captured image starts as `pending_review`. High confidence never automatically approves it in the initial version.

Before approving, review every visible target object. Correct wrong classes and inaccurate boundaries, remove false positives, and annotate missed objects. An image with no predictions is not automatically a negative.

Preserve original model predictions separately from final human annotations. Useful per-sample fields include:

- Schema version, sample UUID, session ID, and specimen/group ID.
- Capture timestamp, image filename/hash, canonical width/height, and orientation normalization details.
- Real/proxy specimen designation and optional scene tags.
- Model version/hash, class-map version, preprocessing version, and proposal thresholds.
- Original proposals: class ID, confidence, and box coordinates.
- Final annotations: class ID and corrected box coordinates.
- Review status, review timestamp, and whether an empty annotation set was explicitly approved.

Use `pending_review` and `approved` as explicit durable states. Editing an approved sample should invalidate its approval until accepted again. Export a consistent snapshot even if later edits occur.

## Phase 5: Useful Collection Strategy

Start with manual capture. Build coverage across class, angle, distance, lighting, background, handheld/tabletop presentation, partial occlusion, and multi-object scenes.

Prioritize the field failures already recorded for collection tubes and ziplock bags, including rotated, handheld, and distant views. Include confusing background objects and reviewed negative scenes. Review difficult captures even when the model offers no boxes.

Record capture sessions and specimen identity early. Many adjacent frames of one scene are not independent examples. Exact hashes can detect identical files; similarity checks can flag near-duplicates for review. Avoid automatic irreversible deletion based on heuristic similarity.

Later automatic capture suggestions may combine stable predictions, box consistency, scene changes, blur checks, a cooldown, and bounded queues. Candidate thresholds should be configurable and evaluated, not invented as evidence of correctness. Suggested captures still require review.

## Phase 6: Neon-Only Dataset Storage and Online Collection

### Where Everything Is Stored

Use a dedicated Neon Postgres database, proposed name `ar_collector`, for all durable dataset content. This name is a proposal; no cloud resources have been provisioned by this plan.

| Content | Location |
| --- | --- |
| Canonical captured image bytes | Neon `sample_images.image_bytes`, PostgreSQL `bytea` |
| Optional thumbnails | Neon binary columns, or generated in backend RAM on demand |
| Samples, sessions, specimens, model versions, original predictions | Neon relational tables with JSONB for optional structured details |
| Labels, boxes, review status, annotation revisions | Neon annotation tables |
| Dataset membership, splits, export manifests | Neon versioned dataset tables |
| Live frames, capture upload buffer, displayed review image | Temporary iPhone RAM only; released after use |
| Training files | Downloaded explicitly to the training computer from a streamed export, never saved by the collector on the iPhone |

Do not introduce SQLite, local JSON manifests, file-based upload queues, Photos-library saves, image disk caches, or R2/S3 buckets for this implementation. PostgreSQL supports binary data through `bytea`: https://www.postgresql.org/docs/current/datatype-binary.html.

The device must briefly hold frames and images in RAM to use its camera and display a review image. The requirement is no application-persisted image/frame data on device, not zero transient memory usage. A live frame that is never captured is disposed and is not added to the dataset.

```text
iPhone camera / inference / review (RAM only)
                   |
                   | authenticated HTTPS
                   v
           Collector backend API
                   |
                   | private TLS database connection
                   v
             Neon Postgres
        image bytes + labels + versions
                   |
                   v
        Backend streams versioned ZIP
                   |
                   v
             Training computer
```

### Backend Boundary

Implement an authenticated API between the phone and Neon. Keep `DATABASE_URL` and migration credentials in backend secrets, never in the mobile bundle. Use parameterized SQL, project-level authorization, a limited application role, and a separate migration role. Choose a connection driver and pooling strategy appropriate for the hosting runtime. Neon connection guidance: https://neon.com/docs/get-started/connect-neon.

Prefer existing backend conventions after inspection. Use a supported authentication system with a revocable operator/device session stored in Keychain; do not embed a shared administrator key. Public registration and collaborative editing are unnecessary initially.

Image bytes make this database larger than a metadata-only database. Set configurable per-image byte/dimension limits, bounded concurrent uploads, and query pagination; verify actual API body limits, driver transport limits, database quota, and pricing at implementation time. Keep binary columns in a separate table and do not select them in sample-list/count queries. Use binary parameter binding rather than storing base64 in text columns. Do not switch storage architectures without the user's direction.

### Minimum Schema

| Table | Required fields or purpose |
| --- | --- |
| `projects` / `project_members` | Ownership and authorization |
| `capture_sessions` | Project, device, start/end times, capture-group and scene metadata |
| `specimens` | Identity and real/proxy designation |
| `model_versions` | Hash, class map, preprocessing version, input/output contract |
| `samples` | UUID, project/session/specimen references, capture time, current annotation revision, deletion marker |
| `sample_images` | Sample reference, immutable `image_bytes bytea`, MIME type, SHA-256, width, height, byte count |
| `prediction_runs` | Sample/model references, original boxes/classes/confidences, proposal settings |
| `annotation_revisions` / `annotations` | Immutable revision, reviewer, pending/approved state, explicit-negative flag, class IDs and pixel-space boxes |
| `dataset_versions` / `dataset_version_samples` | Frozen sample IDs, image hashes, annotation revision IDs, capture groups, split assignments |
| `export_jobs` | Dataset version, status, manifest, validation results, error details; no durable ZIP required |

Use client-generated sample UUIDs and idempotency keys to reconcile retries. Enforce uniqueness within a project, foreign keys, the five class IDs, positive image dimensions, and valid box geometry. Each approved negative has an explicitly reviewed revision with zero annotations. Edits create new pending revisions; historical approved revisions remain available to frozen dataset versions.

### Upload, Review, and Failure Behavior

1. Check authenticated backend availability before enabling capture. Hold at most one pending capture initially to bound RAM.
2. Capture, orient, encode, and infer using RAM-only native APIs. Do not use `capturePhotoToFile`, temporary-file helpers, file-backed background transfers, or a capture library path that secretly persists images. Inspect native implementations; add a small native bridge if necessary.
3. Upload encoded image bytes, image metadata, model version, and original proposals in one bounded request. Configure HTTP body parsers to avoid disk spooling. Validate image decoding, dimensions, byte limits, hash, classes, and boxes server-side.
4. Commit image bytes, sample metadata, original proposals, and initial pending annotation revision in a single Neon transaction. Acknowledge saved only after commit; release the capture buffer once it is no longer needed for review.
5. Retry transient failures from the existing RAM buffer while the app remains active, with bounded backoff. If a response is lost after commit, retry/query by the same sample UUID; return the existing sample only when its hash and request identity match, otherwise reject the conflict.
6. Fetch stored images through authorized API endpoints for review. Decode into RAM with disk caching disabled at the networking and image-library layers. Send review changes using expected-revision checks and clearly distinguish an unsaved edit from a server-confirmed revision.
7. If connectivity fails, pause new collection. An uncommitted capture can be retried while its RAM buffer remains available. If the app terminates or releases that buffer before a successful commit, the image is lost and must be recaptured. Persisted Neon samples remain recoverable after relaunch.
8. On relaunch, reload sessions, pending reviews, and counts from Neon. Do not promise offline capture, offline review, or recovery of unacknowledged RAM-only edits.

Requests already sent may commit even if the app closes; reconcile with the backend on next launch. Surface upload failures and do not claim the dataset contains an image based only on a successful camera shutter event.

### No Device Image Persistence: Acceptance Gate

Inspect capture, encoding, upload, rendering, thumbnail generation, error logging, and export paths for implicit disk writes. Use memory-only image/network caches and `Cache-Control: no-store` for image responses, with an ephemeral native networking session where appropriate. Ensure image-fetch errors and telemetry do not log image payloads. Obscure image views on backgrounding to prevent app-generated switcher snapshots showing dataset images. This is an application-level persistence requirement, not a claim to control all operating-system memory behavior.

Verify on a physical iPhone by inspecting the app container before and after capture, review, failure, backgrounding, and relaunch. No captured image, frame, thumbnail, annotation file, or dataset archive should be written in Documents, Library, Caches, or tmp. The bundled model and normal app assets are not captured dataset content.

### Recovery and Dataset Export

Use versioned migrations, separate development/collection environments, and a documented Neon backup/recovery policy that covers both image bytes and annotations. Perform a restore check. Prevent deletion of image/revision rows referenced by retained dataset versions, and define deliberate version deletion separately.

Freeze approved sample membership and exact image hashes/annotation revision IDs in Neon before export. A backend export worker reads images one at a time with bounded memory, verifies checksums, generates YOLO label text, and streams a ZIP to the authenticated training computer. Store the manifest and export status in Neon; regenerate archives deterministically by version instead of persisting ZIPs. Do not stream a large database export inside a long write transaction.

The iPhone can request export creation and display its status or share an authenticated download-page link. The training computer downloads the archive. Do not invoke an iOS file-share flow that downloads or materializes dataset images/ZIPs on the phone. Expiring access tokens must not grant broader database access.

Strip unnecessary location metadata before encoding canonical images. Do not embed EXIF orientation that conflicts with canonical pixel orientation.

The first export should be an approved, unsplit collection bundle. A desktop preparation step creates training splits after grouping and duplicate review. This prevents the phone from randomly splitting adjacent captures.

Suggested collection bundle:

```text
collector-export-<version>/
  images/<sample-id>.jpg
  labels/<sample-id>.txt
  manifest.json
  data.yaml
  README.md
```

Label rows use normalized YOLO detection format:

```text
class_id center_x/image_width center_y/image_height box_width/image_width box_height/image_height
```

Write an empty label file for each approved negative. Include no confidence column in standard YOLO labels; keep confidence in the manifest. Configure data.yaml consistently with the bundle's unsplit status, and clearly require split preparation before training. Do not point validation and test at the training images to make the configuration appear complete.

Export checks must validate class IDs, finite coordinates, positive sizes, bounds, image dimensions, hashes, image/label pairing, review status, and schema versions. Export only approved records. Verify on the training computer that the streamed archive can be extracted and inspected with an independent reader.

## Phase 7: Dataset Preparation and Evaluation Design

The earlier audit documented 314 images, including 80 intended negatives. Existing training handoff notes describe annotation and split-independence concerns; later evidence mentions corrections in some contexts. Inspect the exact dataset version and manifests before assuming which corrections were applied.

1. Retain authoritative originals and version all corrections.
2. Combine approved new training samples with reviewed original training data.
3. Assign related captures to groups before splitting: session, scene, specimen, and near-duplicate relationships may all matter.
4. Keep related frames in a single split; do not randomly split individual video-like captures.
5. Reserve independent, manually reviewed evaluation sessions. Where independence is unavailable, explicitly document that limitation.
6. Use validation data for model selection and threshold tuning; keep final test data out of those decisions.
7. Generate a split manifest with sample hashes, groups, and assignments, plus a complete training data.yaml.

Measure per-class precision, recall, mAP50/mAP50-95, false detections on negatives, and difficult scenario performance. Review class-level regressions even when aggregate accuracy rises. A small original test set is not strong evidence of generalization by itself.

## Phase 8: Offline Training and Model Promotion

Training is a later, separately initiated stage, not an automatic action when implementing this app.

Freeze the teacher model during each collection round. Fine-tune a trainable `.pt` checkpoint using the versioned approved dataset; the bundled TFLite file is for inference. Record the checkpoint, dataset hashes, split manifest, configuration, seed, and software versions.

Use the existing working export route as the starting point: trainable checkpoint to static ONNX to TFLite. Check exact scripts and model contracts before execution. If input resolution or output shape changes, update preprocessing and decoding explicitly.

Before promotion:

- Compare current and candidate models on identical independent evaluation data.
- Check class-specific regressions and negative-scene false positives.
- Verify tensor shapes, class mapping, and output parity after conversion.
- Perform focused physical-iPhone checks for correct boxes, inference failures, responsiveness, and extended-session resource behavior.
- Keep the previous model and metadata available for rollback.

Choose promotion criteria before inspecting final test outcomes. Do not claim improvement based only on training loss, confidence scores, or the number of accepted captures.

## Verification Plan

Add focused automated checks where correctness materially affects labels or data integrity:

- Decoder retains the right boxes through filtering and same-class NMS.
- Coordinate transforms, clipping, orientation, and export normalization preserve known boxes.
- Missed-object additions, wrong-class corrections, multiple instances, and approved negatives export correctly.
- Only approved samples export; editing invalidates approval as designed.
- Interrupted uploads, lost acknowledgments, transaction rollbacks, stale annotation writes, and interrupted exports do not create incomplete or duplicate samples.
- Archive round-trip validation checks image/label pairing and manifest consistency.
- Neon stores real image bytes, not only paths or URLs; images and annotations survive app reinstall and can be retrieved through authorized requests.
- Capture/review/networking paths do not write dataset images, annotations, thumbnails, or exports into the iPhone app container.
- Offline/backend-unavailable states pause collection; termination before commit is accurately reported as unrecoverable unless reconciliation finds a committed sample.
- Project authorization is enforced, binary data is omitted from list queries, and database credentials are absent from the app bundle.
- Database restore recovers matching images, annotations, and frozen dataset versions.

Use physical-device functional checks for camera permissions, capture, background/foreground behavior, repeated captures, review gestures, loading server data after relaunch, rotation, export-link sharing, no image disk writes, and coexistence with the original app. Simulator rendering or mocked tests alone cannot establish camera/model correctness.

## Milestones and Completion Gates

1. **Isolated shell:** collector builds and launches with its own app identity.
2. **Vertical slice:** one real photo captured in RAM produces draft boxes, is committed with its image bytes to Neon, can be reviewed, exports to the training computer, and passes independent image/label alignment and no-device-file checks.
3. **Usable collector:** pending review, corrections, multiple objects, negatives, sessions, authenticated Neon-only dataset persistence, interruption/retry handling, and versioned streamed export work end to end.
4. **Collection readiness:** duplicate review and dataset validators work; targeted capture coverage is defined.
5. **Later model cycle:** dataset preparation, offline training, evaluation, conversion, device checks, and measured promotion.

Complete milestone 2 before investing in automatic capture or bulk collection. The priority is correctly labeled, useful images rather than raw frame count.

## Suggested Prompt for the New Session

> Read `AR_DATASET_COLLECTOR_PLAN.md` in this workspace and implement milestones 1-3. Use `/Users/ishraklatif/Documents/IE26/EachPathHealth-scrum` as the reference implementation. Inspect its current state and instructions; preserve existing work and keep implementation in this new folder. Establish the isolated repository and branch, reuse the five-class model and appropriate camera/inference code, and build the single-screen iOS collector. Store all durable dataset content, including image bytes as bytea, in Neon Postgres through an authenticated backend. Keep captured frames/photos and review images in RAM only on the iPhone: no files, disk caches, SQLite dataset, temporary image files, or device ZIP exports. Require connectivity and clearly handle upload failures and uncommitted buffer loss. Prioritize exact image/box alignment, human review, atomic/idempotent database writes, and versioned YOLO ZIP streams downloaded by the training computer. Implement migrations/configuration templates and report missing credentials or resources without claiming cloud verification. Run focused checks and build for iOS. Report what was verified on a physical device and any remaining blockers. Do not start model training or paid jobs.

## Technical References

- Pseudo-label bias in semi-supervised detection: https://arxiv.org/abs/2102.09480
- YOLO detection dataset format: https://docs.ultralytics.com/datasets/detect/
- PostgreSQL binary image storage (`bytea`): https://www.postgresql.org/docs/current/datatype-binary.html
- Neon database connection guidance: https://neon.com/docs/get-started/connect-neon

Use exact installed package source and current official documentation when implementing APIs. Historical comments and planning documents can be stale; executable code and reproducible checks take precedence.
