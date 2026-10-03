# EachPath AR Dataset Collector

A standalone, single-page native iOS collector for the existing five-class detector. The main app and its unrelated services have been removed from this workspace. No Git repository, commits, or pushes were created for this final standalone project. The original reference repository is untouched.

Open `ios/Collector.xcworkspace` in Xcode. Build the `Collector` scheme. The app identity is `com.eachpathhealth.arcollector`, display name **EachPath Collector**; it can coexist with the main app. The signing team was copied from the inspected source configuration and can be changed in Xcode's Signing & Capabilities. The only third-party native dependency is TensorFlowLiteC 2.17.0, pinned by `ios/Podfile.lock`.

```sh
cd ios
pod install
xcodebuild -workspace Collector.xcworkspace -scheme Collector -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The single page provides live draft boxes, capture, photo review, class correction, polygon outlines for ground truth, vertex editing, shape movement, rectangle resize handles, undo, zoom/pan, explicit negative confirmation, pending/approved states, and session/dataset sheets. To outline an object, choose **Add polygon**, tap around its visible boundary, undo points if needed, then choose **Finish polygon**. Drag polygon vertices to refine the outline and drag inside it to move it. Review every visible target; model proposals are only drafts. Editing an approved sample first creates a pending server revision. Capture also works with no predictions.

Connection setup requires an HTTPS collector API and an operator account. Select a session or create one with specimen identity and real/proxy designation. All captured images, original predictions, human annotation revisions, counts, and versions are stored in a dedicated Neon database. The phone retains transient image/annotation buffers only in RAM, stores revocable session credentials in Keychain, and uses an ephemeral URLSession without disk image caching. Backgrounding covers the image view before application-switcher snapshots. Offline/backend failures pause collection; one unacknowledged upload can be retried from RAM with the same UUID. Releasing that buffer or terminating the app can lose an uncommitted capture. Refresh server samples to reconcile requests that may already have committed.

Freeze an approved collection from the dataset sheet and share its expiring download URL with the training computer. Download the ZIP there, then validate it independently:

```sh
services/collector/.venv/bin/python scripts/validate_export.py /path/to/collector-export-VERSION.zip --previews /path/to/previews
```

The bundle includes images, YOLO instance-segmentation labels, manifest, README, and an unsplit data.yaml. Each nonempty label row contains a class ID followed by normalized polygon vertex pairs; train a segmentation model, not a detection-only model. Empty approved negatives receive empty label files. Class IDs remain `0 collection_tube`, `1 kit_package`, `2 reply_paid_envelope`, `3 toilet_liner`, `4 ziplock_bag`. Review duplicate groups and keep related sessions/specimens together before preparing independent training/validation/test splits. Model training, conversion, and promotion are later stages and are not started by this app.

See [backend setup](services/collector/README.md) and [verification and remaining manual steps](VERIFICATION.md). The handoff plan remains intact. The source-inspection report is historical: its proposed clone/branch was superseded by the user's request to start from scratch.
