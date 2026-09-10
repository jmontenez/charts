# db-migrator (prototype)

Per-tenant Liquibase migrations for the **multi-tenant single-pod** model (e.g. `time`),
plus the `liquibase` **library chart** that makes the migration container reusable.

## Why this packaging

`time` moved from *one pod per tenant* to *one pod for all tenants*, but each tenant keeps
its own Postgres DB (`<tenant>.time`), so the schema must still be migrated once per DB.
The `app` chart migrates via a single fail-closed **initContainer** (one DB per pod) — a
perfect fit for the old per-tenant model, unusable for one pod serving N DBs.

Three options were considered:

| Option | Verdict |
|---|---|
| A dedicated `time-backend` chart deriving from `app` | ❌ per-app chart proliferation; the migration logic isn't reusable; `.package_application` already repackages `app`+values per project |
| Put the multi-tenant logic **inside `app`** | ➖ bloats the shared chart; every consumer carries it |
| **Extract liquibase into a library chart, reuse it two ways** | ✅ chosen — one source of truth |

## What's here

- **`charts/liquibase`** — a Helm **library chart** exposing `liquibase.container`
  (image helpers + the `liquibase update` container). Credential source is a parameter:
  - `creds: secret` — admin creds from the dlm-provisioned k8s secret (today's behaviour);
  - `creds: vault` — per-tenant creds resolved at runtime by vault-env.
- **`app`** now renders its initContainer by `include`-ing `liquibase.container`
  (`creds: secret`). **Behaviour unchanged** for existing single-tenant / per-tenant apps.
- **`charts/db-migrator`** — renders **one migration Job per tenant** (`creds: vault`,
  DDL role `<tenant>-time-db`, DB `<tenant>.time`), as an **ArgoCD PreSync hook** so
  migrations run *before* the app is rolled out. Batching = ArgoCD **sync-waves** of
  `batchSize` (waves run sequentially → at most `batchSize` Jobs at once; protects
  Postgres/Vault at ~1150 tenants).

## How `time` consumes it

`db-migrator` is deployed as an ArgoCD Application (or an extra resource of the `time`
appset) alongside the `time` app. `.Values.tenants` is the tenant list from the source of
truth, **ham `api/v1/tenants`** — injected at render time by the appset generator or a
small values-writer step. On each sync, ArgoCD runs the PreSync migration Jobs (wave by
wave) before syncing the `time` Deployment.

```
helm template charts/db-migrator \
  --set image.registry=<ecr> --set image.repository=strada/applications/backend/swc/time \
  --set image.tag=<BUILD_VERSION> --set 'tenants={business,essential,premium}' --set batchSize=25
```

## Failure semantics (`failurePolicy`) — open decision

PreSync hooks are **fail-closed** by nature: a failed tenant Job fails the hook and blocks
the rollout. That is *safer* when new code needs the new schema, but differs from the
CI-step requirement ("don't block the pipeline on one tenant; gate on a failure threshold").
Two ways to reconcile, to decide before productionising:
- `fail-closed` (default): a failed migration blocks the sync. Simplest, safest.
- `isolate`: wrap liquibase so a single tenant failure doesn't fail the hook (record it,
  proceed), with a separate threshold gate. Closer to the CI step — **not yet implemented**
  in this prototype.

## vs. the CI step (`time` !1536)

Same migration command and Vault role (`time`), same per-tenant creds. The difference is
*where the fan-out lives*: CI job launching k8s Jobs (visible JUnit, but not sequenced with
ArgoCD) vs. chart-rendered PreSync Jobs (GitOps-native ordering, reusable, versioned). This
prototype is the chart path (option B).

## Prototype notes / not-yet-done

- `liquibase` dependency uses `repository: file://../liquibase`; for release, publish it to
  charts.w6d.io and switch the repo URL (in both `app` and `db-migrator`).
- `failurePolicy: isolate` not wired yet.
- `serviceAccount.name: time` and the Vault role `time` must be allowed to read every
  tenant's `strada-db/static-creds/<tenant>-time-db` (done in dev; replay on qualif/prod).
