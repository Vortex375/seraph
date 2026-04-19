#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker-compose.dev.yml}"
MONGODB_SERVICE="${MONGODB_SERVICE:-mongodb}"
SPACES_DB="${SPACES_DB:-seraph-spaces}"
SPACES_COLLECTION="${SPACES_COLLECTION:-spaces}"
SPACE_TITLE="${SPACE_TITLE:-dirtest dev space}"
SPACE_DESCRIPTION="${SPACE_DESCRIPTION:-Anonymous access to the dirtest provider for local debugging.}"
SPACE_USER="${SPACE_USER:-anonymous}"
SPACE_PROVIDER_ID="${SPACE_PROVIDER_ID:-dirtest}"
TARGET_PROVIDER_ID="${TARGET_PROVIDER_ID:-dirtest}"
TARGET_PATH="${TARGET_PATH:-/}"
TARGET_READ_ONLY="${TARGET_READ_ONLY:-false}"

if ! command -v docker >/dev/null 2>&1; then
  printf 'docker is required but not installed\n' >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  printf 'compose file not found: %s\n' "$COMPOSE_FILE" >&2
  exit 1
fi

docker compose -f "$COMPOSE_FILE" exec -T "$MONGODB_SERVICE" mongosh --quiet <<EOF
db = db.getSiblingDB("$SPACES_DB");
db.getCollection("$SPACES_COLLECTION").updateOne(
  { title: "$SPACE_TITLE", users: ["$SPACE_USER"] },
  {
    \$set: {
      title: "$SPACE_TITLE",
      description: "$SPACE_DESCRIPTION",
      users: ["$SPACE_USER"],
      fileProviders: [
        {
          spaceProviderId: "$SPACE_PROVIDER_ID",
          providerId: "$TARGET_PROVIDER_ID",
          path: "$TARGET_PATH",
          readOnly: $TARGET_READ_ONLY
        }
      ]
    }
  },
  { upsert: true }
);

printjson(
  db.getCollection("$SPACES_COLLECTION").find(
    { title: "$SPACE_TITLE", users: ["$SPACE_USER"] },
    { title: 1, description: 1, users: 1, fileProviders: 1 }
  ).toArray()
);
EOF
