#!/usr/bin/env bash
# Smoke test: Cantaloupe starts, serves IIIF info.json, and produces a JPEG
# derivative (exercises the libjpeg-turbo/TurboJPEG processor and the JVM).
# The delegate script is disabled and a local filesystem source is used, so no
# S3 or Drupal is needed. Does not cover JP2, delegate or S3 paths.
# Usage: test/smoke.sh <image>
set -euo pipefail
IMAGE="${1:?usage: $0 <image>}"
NAME="cantaloupe-smoke-$$"
PORT="${SMOKE_PORT:-18182}"
WORKDIR=""
trap 'rc=$?; [ $rc -ne 0 ] && docker logs "$NAME" >&2 2>&1; docker rm -f "$NAME" >/dev/null 2>&1; [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; exit $rc' EXIT

WORKDIR="$(mktemp -d)"
cat > "$WORKDIR/smoke.properties" <<PROPS
extends=/opt/cantaloupe_configs/actual_cantaloupe.properties
delegate_script.enabled=false
source.static=FilesystemSource
source.delegate=false
FilesystemSource.lookup_strategy=BasicLookupStrategy
FilesystemSource.BasicLookupStrategy.path_prefix=/tmp/images/
PROPS
chmod 644 "$WORKDIR/smoke.properties"

docker run -d --name "$NAME" -p "${PORT}:8182" \
  -v "$WORKDIR/smoke.properties:/tmp/smoke.properties:ro" \
  -e CANTALOUPE_PROPERTIES=/tmp/smoke.properties \
  "$IMAGE" >/dev/null

echo "waiting for Cantaloupe..."
for _ in $(seq 1 90); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" || true)" = "200" ] && up=1 && break
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ] || { echo "FAIL: container exited" >&2; exit 1; }
  sleep 1
done
[ "${up:-0}" = "1" ] || { echo "FAIL: GET / never returned 200" >&2; exit 1; }
echo "ok: GET / 200"

# Create a source JPEG with the image's own ImageMagick.
docker exec -u 0 "$NAME" sh -c 'mkdir -p /tmp/images && (convert -size 400x300 gradient:red-blue /tmp/images/test.jpg || magick -size 400x300 gradient:red-blue /tmp/images/test.jpg)'

info="$(curl -sf "http://localhost:${PORT}/iiif/2/test.jpg/info.json")"
echo "$info" | grep -q '"width" *: *400' || { echo "FAIL: info.json missing/incorrect: $info" >&2; exit 1; }
echo "ok: info.json served"

out="$(curl -s -o /dev/null -w '%{http_code} %{content_type} %{size_download}' "http://localhost:${PORT}/iiif/2/test.jpg/50,50,200,150/100,/0/default.jpg")"
case "$out" in
  "200 image/jpeg "*) echo "ok: derivative $out" ;;
  *) echo "FAIL: derivative request returned: $out" >&2; exit 1 ;;
esac

if docker logs "$NAME" 2>&1 | grep -E 'UnsatisfiedLinkError|InaccessibleObjectException|UnsupportedClassVersionError'; then
  echo "FAIL: JVM/native-library error in logs" >&2
  exit 1
fi
echo "smoke test passed"
