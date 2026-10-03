# Reference repository inspection

**Historical note, 2026-10-02:** The user superseded the proposed clone/branch approach and requested a fresh minimal standalone project. Cloned content and Git metadata were removed. The new project retains only the required model asset from the source; the original repository remains untouched.

Inspected 2026-10-01. Scope: Phase 1, step 1 of AR_DATASET_COLLECTOR_PLAN.md. No source changes, cloning, builds, training, cloud provisioning, or device verification performed.

## Source and existing work

- Repository: `/Users/ishraklatif/Documents/IE26/EachPathHealth-scrum`
- Branch: `AC5.2`, tracking `origin/AC5.2`
- HEAD: `50e467a5d11ca8062394f0379429fb1b093c1bdc`
- Tracked modifications: `.gitignore` and `apps/mobile/ios/EachPathMobile.xcodeproj/project.pbxproj`.
- The ignore changes exclude IBWD/local assistant configuration. The Xcode diff changes font file encodings and removes an empty Resources group path; it is not a collector identity change. Preserve it in the source and assess whether the new checkout needs it.
- Untracked content includes repository instructions, local skills, failure/training handoffs, smoke-test screens/hooks, model candidates, parity-audit scripts/results, model exports, training runs, and unrelated assistant/UI plans. Do not transfer these wholesale.

## Instructions

Read source `AGENTS.md`, `.agents/skills/ibwd-navigation/SKILL.md`, and `CONTRIBUTING.md`. No callable IBWD tools are available in this session, so navigation used ordinary source search; no IBWD index was relied on.

Preserve npm and component-level dependency isolation, lockfiles, no-container conventions, secret handling, and applicable product boundaries. The original app prohibits camera-image transmission; the collector handoff explicitly requires authenticated image uploads to Neon in a separate app. Document this collector-specific exception when establishing its instructions, while keeping inference on device and the reference app untouched.

## Reusable implementation

- `apps/mobile/index.js`: SafeAreaProvider wrapper.
- `src/components/CameraViewport.tsx` and camera permission/lifecycle hooks: rear-camera preview and frame output.
- `src/ml/modelLoader.ts`: TFLite loading with default CPU delegate.
- `src/ml/useKitDetectionInference.ts`: float32 RGB contain resize to `[1,320,320,3]`, output shape check `[1,9,2100]`, every-tenth-frame worklet inference, shared counters, and resource disposal.
- `src/ml/letterboxPadding.ts`: geometry-based gray padding correction, 114/255.
- `src/ml/decodeYoloDetections.ts`: five classes, confidence floor 0.50, same-class NMS IoU 0.45. Returns class and confidence but drops boxes; adapt it to preserve boxes and reject invalid geometry.
- Keep the class order: collection_tube, kit_package, reply_paid_envelope, toilet_liner, ziplock_bag.
- Build a separate collection controller; the existing kit checklist and its inference cap are not annotation review behavior.

## Dependencies and native configuration

Installed package versions match the inspected dependency set: React Native 0.87.1; VisionCamera, camera resizer, and camera worklets 5.2.3; fast-tflite 3.0.1; Nitro Image 0.15.2; Nitro Modules 0.37.1; worklets 0.12.2.

Preserve the worklets Babel plugin, Metro `.tflite` asset registration and generated-directory exclusions, camera permission configuration, native font references if retained, and the Podfile post-install fix raising old pod deployment targets to React Native's minimum. Podfile.lock pins TensorFlowLiteC 2.17.0. No additional required native package patch was identified in this inspection; a fresh install/build is needed to establish reproducibility.

Installed VisionCamera exposes `capturePhoto` separately from `capturePhotoToFile`. Its iOS `getFileData` returns an ArrayBuffer from `AVCapturePhoto.fileDataRepresentation()` without calling the separate save-to-file code. Nitro Image exposes memory decoding, raw pixels, and encoded image data. These are promising building blocks, not proof of the complete no-device-persistence requirement. Canonical orientation, still-image inference, network/image cache behavior, and physical-container checks remain to implement and verify.

## Model provenance issue

The committed mobile asset exists at `apps/mobile/assets/model/yolo11n-trained-v1.tflite`.

- Observed asset SHA-256: `455888c9b0bc769b0a6307c324ed59879b706cab6283742d9f5aaf7097bf4937`
- Training export `verification.json` and untracked `runtime-audit.json` reference SHA-256: `fc6f582bde452964821188b3c8c6ab96d30442995cb65f448a39e59088194a95`

Those reports do not verify the exact bundled bytes. Resolve the artifact history and verify the bundled model's actual tensor/coordinate contract before treating export/parity evidence as applicable. Do not replace it with a candidate or download/train a model automatically.

## Backend and next step

The existing `services/api` uses Flask, Flask-SQLAlchemy, SQLAlchemy, and psycopg2. These provide conventions to inspect further, but this inspection does not establish collector authentication, schema, endpoint readiness, or Neon resource availability. Do not reuse the partner/content data stores implicitly.

Next: establish an isolated checkout in the collector workspace on `feature/ar-dataset-collector`, preserving the handoff and this report. Record the source commit and each selected transfer. Bring across relevant instructions and inspected field/training context; committed camera/model code comes from the checkout. Exclude credentials, caches, node_modules, Pods/build products, training environments, runs, and unnecessary model candidates. Resolve the model provenance discrepancy before implementing inference metadata.
