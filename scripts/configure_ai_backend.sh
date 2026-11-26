#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="${1:-}"

if [[ -z "$PROJECT_ID" ]]; then
  printf 'Usage: %s FIREBASE_PROJECT_ID\n' "$0" >&2
  exit 2
fi

if [[ ! "$PROJECT_ID" =~ ^[a-z0-9][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  printf 'Firebase project ID has an invalid format.\n' >&2
  exit 2
fi

for command_name in firebase npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command is not installed: %s\n' "$command_name" >&2
    exit 1
  fi
done

printf 'Firebase project: %s\n' "$PROJECT_ID"
printf 'Enter a model name verified against current official documentation: '
IFS= read -r model_name

if [[ ! "$model_name" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  printf 'OPENAI_MODEL is empty or contains unsupported characters.\n' >&2
  exit 1
fi

cat > "$ROOT_DIR/.firebaserc" <<EOF
{
  "projects": {
    "default": "$PROJECT_ID"
  }
}
EOF

cat > "$ROOT_DIR/functions/.env.$PROJECT_ID" <<EOF
OPENAI_MODEL=$model_name
EOF

printf '\nInstalling Functions dependencies...\n'
npm --prefix "$ROOT_DIR/functions" install

printf '\nRunning Functions tests...\n'
npm --prefix "$ROOT_DIR/functions" test

printf '\nThe Firebase CLI will now request OPENAI_API_KEY securely.\n'
firebase --project "$PROJECT_ID" functions:secrets:set OPENAI_API_KEY

printf '\nDeploying generateNarrative...\n'
firebase --project "$PROJECT_ID" deploy --only functions

printf '\nAI backend deployment completed. Run the signed-in device checks in TESTING.md.\n'
