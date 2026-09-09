#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Anonymous public-image pulls avoid desktop credential-helper prompts. User config is untouched.
mkdir -p .local-docker
printf '{"auths":{},"cliPluginsExtraDirs":["/Applications/Docker.app/Contents/Resources/cli-plugins"]}\n' > .local-docker/config.json
export DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
export DOCKER_CONFIG="$PWD/.local-docker"
docker network inspect noto-local >/dev/null 2>&1 || docker network create --driver bridge --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 noto-local
npx --yes supabase@2.117.0 start --network-id noto-local -x realtime,storage-api,imgproxy,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
python3 local/loopback.py
# Only this task's disposable local DB; never targets a linked/hosted project.
docker exec supabase_db_noto psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='noto_replication') THEN CREATE ROLE noto_replication WITH REPLICATION BYPASSRLS LOGIN PASSWORD 'noto-local-replication-only'; END IF; END \$\$; GRANT USAGE ON SCHEMA public TO noto_replication; GRANT SELECT ON public.noto_tasks, public.noto_conflicts TO noto_replication;"
if ! docker exec supabase_db_noto psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='noto_powersync_storage'" | grep -q 1; then
  docker exec supabase_db_noto createdb -U postgres noto_powersync_storage
fi
npx --yes supabase@2.117.0 status -o json > .local-docker/status.json
docker compose -f local/compose.yaml up -d
node local/fixtures.mjs
