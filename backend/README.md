# Noto backend

Supabase Auth (email/password), PostgreSQL RPC uploads, and PowerSync downloads. Only tasks sync in this release. Notes and chat messages remain on the originating device; `hasConversation` is always false in cloud documents.

## Run the complete local integration stack

See [local/README.md](local/README.md). `./local/start.sh` starts a disposable loopback-only Supabase + PowerSync environment; `npm run test:live` exercises real authentication, RPC, logical replication and three independent SQLite clients. The setup and live test have been executed successfully on this development machine. Generated client fixture settings are in ignored `.local-docker/client-fixture.json`. No hosted project has been deployed.

## Run the database contract tests without Docker

```sh
cd backend
npm ci
npm test
```

The test runs the checked-in migration in PGlite (PostgreSQL WASM). It tests SQL/PLpgSQL execution and actual role permissions: two-user isolation, anonymous denial, direct-write denial, same-field conflicts, different-field merges, UTC normalization, deletion/restore, invalid documents and mutation replay. Only Supabase's `auth.users` and `auth.uid()` are minimal test substitutes. It does **not** validate real Supabase Auth, concurrent PostgreSQL sessions, logical replication, PowerSync delivery, or physical devices.

## Start local Supabase

Requires a running Docker daemon and the Supabase CLI. No script starts Docker or alters its settings.

```sh
cd backend
supabase start
supabase db reset
supabase status
```

`db reset` destroys **local** database contents; use only a disposable development instance. The migration is automatically loaded from `supabase/migrations`. API is at `http://127.0.0.1:54321`, Studio at port 54323, and local confirmation-email inbox at port 54324. Email confirmations are enabled. The desktop app can use the Mac's loopback service; another Mac needs reachable development services and appropriate HTTPS configuration. Use the anonymous/publishable project key on clients, never a service-role key or database password.

## Deploy a dedicated test project

1. Create a Supabase project and configure email/password Auth, confirmation email delivery, and allowed application redirects as needed. Create two separate test users.
2. Link this directory with `supabase link --project-ref <your-project-ref>`, inspect `supabase db push --dry-run`, then apply with `supabase db push`. These commands change the selected cloud project; credentials and project creation are intentionally not embedded in this repository.
3. Create a PowerSync Cloud instance connected to the Supabase project's direct PostgreSQL endpoint using a dedicated replication role. Follow [PowerSync's Supabase source setup](https://docs.powersync.com/configuration/source-db/setup) for role/replication requirements. The migration creates publication `powersync`, containing exactly `noto_tasks` and `noto_conflicts`; configure PowerSync to use that publication. Do not grant client access to replication credentials.
4. Configure PowerSync to verify that project's Supabase JWTs using the documented [Supabase Auth integration](https://docs.powersync.com/configuration/auth/supabase-auth). Restrict issuer/audience to the project; do not accept unsigned tokens or client-supplied user IDs.
5. Deploy `powersync/sync-rules.yaml` in the PowerSync dashboard's **Sync Rules** mode (these are bucket rules, not the newer Sync Streams syntax). Both queries filter using the verified JWT subject. RLS does not filter replication, so these filters are security-critical. See [PowerSync parameter queries](https://docs.powersync.com/sync/rules/parameter-queries) and [RLS with PowerSync](https://docs.powersync.com/integrations/supabase/rls-and-sync-streams).
6. Supply the Supabase URL, publishable key and PowerSync endpoint to each app's connection settings. Sign in to the same test account on both devices. Confirm email before testing.
7. Run the cross-device acceptance checklist in the root delivery documentation. Then repeat with distinct accounts and confirm neither task nor conflict data crosses accounts. Verify database backups and restore procedure before using production data.

No hosted cloud service has been provisioned or deployed. SQL contracts and the real local Supabase/PowerSync service path are validated; hosted connectivity and physical-device acceptance still require real project credentials and signed apps.

## Data and upload contract

`POST /rest/v1/rpc/noto_apply_mutation` with `Authorization: Bearer <user-access-token>` and the project's publishable key in `apikey`:

```json
{
  "p_mutation_id": "6b6c5275-53bb-4bfd-bbe6-2b17700b886a",
  "p_task_id": "77004158-cbe9-41c0-a335-b218ee3ece71",
  "p_operation": "upsert",
  "p_document": {
    "id": "77004158-cbe9-41c0-a335-b218ee3ece71",
    "kind": "todo",
    "text": "Test two-device sync",
    "status": "pending",
    "priority": "normal",
    "completed": false,
    "createdAt": "2026-09-09T00:00:00Z",
    "updatedAt": "2026-09-09T00:00:00Z",
    "hasConversation": false
  },
  "p_base_document": null
}
```

- Send a complete desired document and the last acknowledged **server** document as base. `null` base creates a new task. Keep the base across offline edits. Dates are ISO8601 timestamps; `due` is a calendar date (`YYYY-MM-DD`). Optional `due` and `completedAt` may be omitted/null. IDs are UUIDs. Completion status/boolean/timestamp must agree.
- Persist the mutation UUID and its exact payload before the request; retry that same payload after timeout. A successful retry returns the original response even if later mutations have changed the task. Reusing an ID with different payload or owner is rejected.
- Response: `{"outcome":"applied|conflict|deleted","revision":1,"document":{...},"deleted":false}`. Install only responses/downloads that are not older than the locally acknowledged revision; handle later queued edits separately. `conflict` is a successfully processed mutation, not an indefinitely retryable network failure.
- `text`, `due`, `priority`, and completion (`status`/`completed`/`completedAt` as one group) merge independently against the base. If any changed field conflicts, no part of that mutation overwrites the server task; its complete local document is retained in `noto_conflicts` using the mutation UUID. Clients must surface that retained version and allow explicit recovery.
- `id`, `kind`, and `createdAt` remain immutable after creation. The server sets `updatedAt` for applied changes, normalizes timestamps to UTC and strips local conversation presence. Metadata does not create merge conflicts.
- `delete` creates/preserves a tombstone and wins over offline edits. An old `upsert` returns `deleted` and preserves any differing local text/document as a conflict record. Only explicit `restore` with the matching current tombstone business/immutable fields as base (server-owned updatedAt and local hasConversation are ignored) can resurrect it. Restore conflicts are retained too. No automatic tombstone expiration is implemented: pruning requires a future device-expiry/retention protocol.
- Clients can SELECT their own tasks/conflicts but cannot write those tables directly. RPC identity comes exclusively from `auth.uid()`. Mutation receipts have no client SELECT permission and are not replicated. UUID collisions across users are rejected.
- Receipts and conflict records are retained indefinitely in this initial version to preserve retry correctness and user text. A future bounded-retention policy needs an explicit recovery contract; do not simply delete receipts while offline devices may retry.

The RPC uses fixed `search_path` and explicit schema names as recommended by [Supabase database function guidance](https://supabase.com/docs/guides/database/functions). Per-task transaction locks also cover first-insert races; the live test verifies simultaneous identical-mutation replay and independent-field writes through separate HTTP requests.
