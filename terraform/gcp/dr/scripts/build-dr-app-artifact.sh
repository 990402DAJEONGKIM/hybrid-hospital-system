#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

SOURCE_BACKEND="$REPO_ROOT/app/combined/backend"
SOURCE_FRONTEND="$REPO_ROOT/app/dr-frontend"

DR_APP_DIR="$REPO_ROOT/app/dr-app"
DR_BACKEND="$DR_APP_DIR/backend"
DR_FRONTEND="$DR_APP_DIR/frontend"

ARTIFACT_DIR="$REPO_ROOT/.artifacts/dr-app"
ARTIFACT_ZIP="$ARTIFACT_DIR/dr-app.zip"

echo "[1/6] Prepare clean DR app directory"
rm -rf "$DR_BACKEND" "$DR_FRONTEND"
mkdir -p "$DR_BACKEND" "$DR_FRONTEND" "$ARTIFACT_DIR"

echo "[2/6] Sync backend: app/combined/backend -> app/dr-app/backend"
rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='*.db' \
  --exclude='*.sqlite' \
  --exclude='*.sqlite3' \
  --exclude='.env' \
  --exclude='cookies.txt' \
  --exclude='nurse_cookies.txt' \
  --exclude='*:Zone.Identifier' \
  "$SOURCE_BACKEND/" "$DR_BACKEND/"

echo "[3/6] Sync frontend: app/dr-frontend -> app/dr-app/frontend"
rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='*:Zone.Identifier' \
  "$SOURCE_FRONTEND/" "$DR_FRONTEND/"

echo "[4/6] Remove local-only artifacts before packaging"
find "$DR_APP_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$DR_APP_DIR" -type f \( \
  -name '*.pyc' -o \
  -name '*.pyo' -o \
  -name '*.db' -o \
  -name '*.sqlite' -o \
  -name '*.sqlite3' -o \
  -name '.env' -o \
  -name 'cookies.txt' -o \
  -name 'nurse_cookies.txt' -o \
  -name '*:Zone.Identifier' \
\) -delete

echo "[5/6] Write non-secret build metadata"
cat > "$DR_APP_DIR/VERSION" << META
git_sha=${GITHUB_SHA:-local}
branch=${GITHUB_REF_NAME:-local}
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
source_backend=app/combined/backend
source_frontend=app/dr-frontend
artifact_root=app/dr-app
META

echo "[6/6] Build zip from app/dr-app"
rm -f "$ARTIFACT_ZIP" "$ARTIFACT_ZIP.sha256"

(
  cd "$DR_APP_DIR"
  zip -qr "$ARTIFACT_ZIP" . \
    -x '*/__pycache__/*' \
    -x '*.pyc' \
    -x '*.pyo' \
    -x '*.db' \
    -x '*.sqlite' \
    -x '*.sqlite3' \
    -x '.env' \
    -x 'cookies.txt' \
    -x 'nurse_cookies.txt' \
    -x '*:Zone.Identifier'
)

sha256sum "$ARTIFACT_ZIP" > "$ARTIFACT_ZIP.sha256"

echo "Built artifact:"
echo "  $ARTIFACT_ZIP"
echo "  $ARTIFACT_ZIP.sha256"
