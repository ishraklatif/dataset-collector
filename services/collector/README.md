# Collector API

Dedicated Flask/PostgreSQL service. All durable images are `bytea` in Neon. Do not point this service at the main application's database.

Create a Python 3.11 environment and install `requirements.txt`. Configure backend environment values from `.env.example`; the service reads process environment variables, not `.env` automatically. Runtime connections require `sslmode=verify-full`. The loopback-only `ALLOW_LOCAL_DATABASE=1` switch is for development and tests.

```sh
python3.11 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/flask --app 'app:create_app()' migrate
.venv/bin/flask --app 'app:create_app()' create-operator
.venv/bin/gunicorn --config gunicorn.conf.py 'app:create_app()'
```

Migration and operator administration use `MIGRATION_DATABASE_URL` (direct/unpooled Neon URL). Keep that variable out of the running web service after setup. Create a separate `collector_app` login role privately and apply `migrations/runtime_grants.sql` as the database owner. The linked Neon project currently uses its dedicated `neondb` database; update the CONNECT grant and connection URLs if you choose another database. Use the limited role and pooled Neon URL for the running service's `DATABASE_URL`. No shared administrator key goes into the phone. Device sessions last seven days; login attempts are limited to 30 per operator name per ten minutes. Revoke an operator's sessions and download links with `flask --app 'app:create_app()' revoke-operator USERNAME` using migration credentials.

Publish behind HTTPS. Set `PUBLIC_BASE_URL` to the final public HTTPS URL. Raw `image/jpeg` request bodies remain in RAM; Flask does not use multipart parsing. Keep upstream proxy request/response buffering and caching off for image/upload/export endpoints. If using nginx, configure `proxy_request_buffering off`, `proxy_buffering off`, `client_max_body_size 12m`, and header buffers at least 32 KiB. Do not log Authorization, X-Capture, request/response bodies, or `/download/` capability URLs. Gunicorn access logs are disabled. Check the chosen host's actual upload/header/time limits before collection; defaults are 12 MiB per JPEG, 4096 maximum dimension, and 5000 images per version. Raising a limit requires reviewing worker memory and host limits. Each worker permits two uploads and one export concurrently.

The phone posts binary JPEG bytes with base64-encoded JSON in `X-Capture` and a sample UUID in `Idempotency-Key`. Capture metadata must match the image hash/dimensions and the bundled model identity. Uploads commit images, predictions, and pending revisions together. Identical retries return the committed sample; conflicting retries return 409. Every database read/write is scoped to the signed-in operator's projects. Image bytes are excluded from sample lists/counts. Shared URLs open a text-only download page so link-preview fetching never retrieves the ZIP or a dataset image. The archive is a separate route reached by deliberately clicking the page's download link on the training computer.

Review edits create immutable revisions using `expected_revision`. Approved annotations are polygons with 3–256 image-coordinate points, stored in the immutable `annotation_polygons` table alongside their bounding rectangles. Existing rectangle-only approvals must be reopened and traced before they can be frozen into a segmentation dataset. An approved image must have nonempty annotations or explicit negative confirmation. Reopening an approved sample is read-only until the user marks it pending. Discard uses a deletion marker; frozen versions retain historical membership, hashes, and revisions. Exports use YOLO instance-segmentation labels, contain only frozen approved revisions, and remain unsplit. ZIPs stream with one bounded image in memory, deterministic paths/timestamps, and no durable server archive. A generated 30-minute link grants access only to one dataset version. The phone shares the URL and never downloads the archive. Train a segmentation model with these labels, not a detection-only model.

Tests require an isolated local PostgreSQL database whose name includes `collector_test`:

```sh
TEST_DATABASE_URL=postgresql://127.0.0.1:55437/collector_test .venv/bin/python -m pytest -q
```

Use separate Neon branches/projects for development and collection. Choose a restore retention period that covers both images and annotation history. Before real collection, restore a branch or database to an isolated target and compare image SHA-256 values, revision counts, and version memberships, then regenerate and independently validate an export. Local transaction tests do not establish the cloud backup policy or a Neon restore. Do not delete frozen version history to reclaim space without a deliberate retention decision — the Google Drive archival feature below is that one deliberate, narrowly-scoped exception.

## Google Drive archival

Schema migration 003 adds one narrow exception to the immutability rule above: `sample_images.image_bytes` may be set to `NULL` (and only `NULL`, never reassigned) once a sample's image has been verified-uploaded to Google Drive, to keep the Neon branch under its storage cap. Every other field, and every other table, remains fully immutable; an already-archived row can never be touched again, and deleting a `sample_images` row is still always rejected.

`POST /v1/projects/<project>/archive` is the one-tap flow: it selects newly approved, not-yet-archived samples (oldest first, capped by `MAX_ARCHIVE_SAMPLES`/`MAX_ARCHIVE_BYTES` so one call stays well under the phone app's 90-second request timeout), freezes them into their own dataset version, builds the ZIP in memory, uploads it to Drive, and **only after Drive confirms the upload** nulls those samples' image bytes in Neon. Any failure before that confirmation leaves Neon untouched. `/v1/health`'s `needs_archive` flag (true once usage crosses `ARCHIVE_PROMPT_RATIO`, default 95%) tells the phone app when to prompt for this.

Archiving is one-way: an archived sample can never be reopened for review (`PUT .../review` rejects it, `GET .../image` returns 410) since its original pixels are gone from Neon — only the Drive copy remains. If a sample already belonged to an earlier, separately-frozen dataset version, that older version's ZIP becomes undownloadable once its samples are archived (`/v1/versions` and the manual freeze/export flow still work, but archiving and manual export share the same underlying image bytes — once gone, they're gone from Neon for every version, not just the one the archive run created). At single-operator scale this is an accepted tradeoff rather than something the server tracks or blocks.

One-time setup (outside this codebase, run by the project owner, not from the server):

1. In Google Cloud Console: enable the Drive API; create an OAuth client of type **Desktop app**; if the consent screen is in testing mode, add the Google account that will own the archive as a test user; create a Drive folder to receive archives and copy its folder ID from the folder's URL.
2. Run `python3 scripts/google_drive_authorize.py` locally (stdlib only, no install needed) with that OAuth client's ID/secret. It opens the consent URL, catches the redirect on a one-shot local server, and prints a refresh token.
3. Set `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `GOOGLE_OAUTH_REFRESH_TOKEN`, and `GOOGLE_DRIVE_FOLDER_ID` as Render secrets (`sync: false`, never committed). Until all four are set, `/v1/projects/<project>/archive` returns 503 and the rest of the service is unaffected.

## Render image deployment

The API is packaged as an image for Render so this workspace does not need a Git remote or source push. Docker Desktop must be running and authenticated to the image registry before building. From this directory, build and publish a Linux AMD64 image to a private Docker Hub repository:

```sh
docker buildx build --platform linux/amd64 -t docker.io/YOUR_DOCKERHUB_USERNAME/eachpath-ar-collector:2026-10-02 --push .
```

In Render, create a Web Service from **Existing Image**, enter that image URL, add Docker Hub pull credentials, choose the Ohio region, and set health check path `/healthz`. Set `DATABASE_URL` to the `collector_app` pooled Neon URL with `sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt`; set `PUBLIC_BASE_URL` to the Render HTTPS URL. Keep the owner/direct URL out of Render's runtime environment. The service settings are also recorded in `render.example.yaml`.

The polygon release requires schema migration 002, and Drive archival requires migration 003, each with a newly built API image. First test migrations against an isolated Neon branch, then run `flask --app 'app:create_app()' migrate` with `MIGRATION_DATABASE_URL` set to the direct (unpooled) connection. The command applies any numbered SQL migration not yet recorded in `schema_migrations`. Build and publish the updated image yourself, then update the Render image tag and redeploy. The running API reports its annotation format in `/v1/health`; the updated iPhone app refuses polygon capture against an older API to prevent labels from silently degrading to rectangles. Never add `MIGRATION_DATABASE_URL` to Render.

Official references: [Neon pooling](https://neon.com/docs/connect/connection-pooling), [PostgreSQL bytea](https://www.postgresql.org/docs/current/datatype-binary.html), [Render image-backed services](https://render.com/docs/deploying-an-image), and the [Render Blueprint specification](https://render.com/docs/blueprint-spec). A private image requires a registry credential configured in Render.
