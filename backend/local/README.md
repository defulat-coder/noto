# Disposable local integration environment

Requires Docker Desktop running, Node.js 24 and Python 3. No hosted project or real credentials are used.

```sh
cd backend
npm ci
./local/start.sh
npm run test:live
```

`start.sh` starts the pinned Supabase CLI stack, applies migrations on first startup, creates a separate PowerSync storage database, starts the pinned PowerSync service and creates two confirmed development users. It uses an isolated Docker config for anonymous image pulls to avoid desktop credential-helper prompts. It does not modify the user's Docker configuration or other containers.

Supabase CLI initially creates host-wide port bindings. The script snapshots and recreates **only** `supabase_db_noto`, `supabase_kong_noto`, and `supabase_inbucket_noto` with loopback bindings, preserving volumes and CLI-injected gateway files. Final exposed ports are 127.0.0.1:54321 (API), 54322 (Postgres), 54324 (local email), and 8080 (PowerSync). These public development credentials must never be used on a public host.

The generated `backend/.local-docker/client-fixture.json` contains only the client URLs, anonymous project key and development users (`users: [{email,password,id}]`). Use it for app integration tests. `status.json` in the same ignored directory includes local administration credentials and must not be shipped with an app.

Accounts: `alice@noto.local` and `bob@noto.local`, password `Noto-local-only-2026!`. Both are local-only fixtures. PowerSync verifies real Supabase ES256 access tokens through the local JWKS endpoint; no custom fake-auth endpoint is used.

The live test opens three independent PowerSync/SQLite databases (two Alice devices and one Bob device), performs Auth login and RPC uploads, verifies replicated tasks/conflicts and user isolation, and tests tombstone/restore delivery. The desktop app integration tests are separate and must also pass.

Stop services without deleting data:

```sh
cd backend
docker compose -f local/compose.yaml down
npx --yes supabase@2.117.0 stop
```

Do not run `supabase db reset` while PowerSync is running. To reinitialize this disposable environment after changing initial migrations, stop PowerSync first; then reset the local database and restart using `start.sh`. Production upgrades require new incremental migrations and a reviewed rollout.
