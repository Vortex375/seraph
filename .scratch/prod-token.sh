#!/bin/sh
# Prints a fresh access token for the prod instance from .env.seraph-prod
. "$(dirname "$0")/../.env.seraph-prod"
curl -s -X POST "$OIDC_TOKEN_URL" -d grant_type=refresh_token -d client_id="$OIDC_CLIENT_ID" -d refresh_token="$SERAPH_REFRESH_TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
