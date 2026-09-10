# db-migrator (prototype)

Per-tenant Liquibase migrations for the **multi-tenant single-pod** model (e.g. `time`),
plus the `liquibase` **library chart** that makes the migration container reusable.

## Why this packaging

`time` moved from *one pod per tenant* to *one pod for all tenants*, but each tenant keeps
its own Postgres DB (`<tenant>.time`), so the schema must still be migrated once per DB.
The `app` chart migrates via a single fail-closed **initContainer** (one DB per pod) —
perfect for the old per-tenant model, unusable for one pod serving N DBs.

Chosen packaging: **extract the Liquibase container into a library chart** and reuse it two
ways (over a `time-backend`-derived chart, or bloating `app`):

- **`charts/liquibase`** (library) exposes `liquibase.container` — creds source is a param
  (`secret` = today's k8s-secret admin creds; `vault` = per-tenant creds via vault-env).
- **`app`** renders its initContainer via `include "liquibase.container"` (`creds: secret`).
  **Behaviour unchanged** for single/per-tenant apps.
- **`charts/db-migrator`** provides the multi-tenant migrator (this chart).

## Controller mode (b)

One **controller Job**, rendered as an **ArgoCD PreSync hook** (runs before the app Sync):

1. discovers tenants from ham `api/v1/tenants` (in-cluster, internal port 8083, no auth),
   at runtime — so there is **no tenant list in values**;
2. fans out one child migration Job per tenant, rendered from the shared
   `liquibase.container` (Vault mode: DDL role `<tenant>-time-db`, DB `<tenant>.time`);
3. by **batch** (`batchSize` concurrent child Jobs) — required at ~1150 tenants;
4. **isolates** per-tenant failures and exits non-zero only if the failure rate exceeds
   `failThresholdPct` (which blocks the Sync). This gives the CI-step's non-blocking +
   threshold semantics, but GitOps-native (ordering guaranteed by PreSync).

The controller script lives in `files/migrate.sh` (mounted via a ConfigMap); the child Job
template is helm-rendered from the library into the same ConfigMap (`${TENANT}`/`${RUN_ID}`
substituted at runtime). RBAC (SA + Role) to manage the child Jobs is in `templates/rbac.yaml`.

```
helm template charts/db-migrator \
  --set image.registry=<ecr> --set image.repository=strada/applications/backend/swc/time \
  --set image.tag=<BUILD_VERSION> --namespace strada-back
```

## How `time` consumes it

Deployed alongside the `time` app so its PreSync hook runs before each rollout. `image.*`
points at the app's `-db` (liquibase) image. The Vault role `time` (SA `time`) must be
allowed to read every tenant's `strada-db/static-creds/<tenant>-time-db` (done in dev;
replay on qualif/prod).

## Prototype notes

- `liquibase` dependency uses `repository: file://../liquibase`; publish to charts.w6d.io
  and switch the URL before release (in both `app` and `db-migrator`).
- Controller image needs `kubectl`+`curl`+`jq`+`envsubst` (the script installs the last
  three if missing on `w6dio/kubectl`).
- Two SAs: `db-migrator` (controller, manages Jobs) and `time` (child Jobs, Vault creds).
