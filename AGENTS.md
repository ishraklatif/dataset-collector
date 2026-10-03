# Collector workspace

Implement the standalone collector described in AR_DATASET_COLLECTOR_PLAN.md. Keep the reference repository untouched. The user requested a fresh minimal project: no cloned repository, unrelated app screens, or services. No commits or pushes unless the user changes that instruction. No training, model downloads, paid model jobs, or benchmarks.

Use IBWD first for supported navigation when its tools are available; otherwise say so and use ordinary search. Preserve npm lockfiles and component-level environments. Do not add containers. Keep secrets outside code and mobile bundles.

Collector-specific exception to the reference CONTRIBUTING.md: this separate app uploads canonical captured images to an authenticated dedicated Neon backend. Inference remains on device. Durable dataset content belongs only in Neon; the iPhone uses RAM, Keychain credentials, and bundled assets. Never write captured images, annotations, thumbnails, or dataset exports to the device filesystem.
