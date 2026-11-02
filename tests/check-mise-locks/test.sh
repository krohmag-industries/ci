#!/usr/bin/env bash
# Tests scripts/check-mise-locks on throwaway copies of the real lock: it passes the real files and fails on every way
# a lock edit could slip a different tool, version, URL or checksum past `mise install --locked`. Run by scripts/validate;
# also: tests/check-mise-locks/test.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
n=0 fail=0

fresh() { # a git repo with the lint, the pins and the lock
  rm -rf "$t/r" && mkdir -p "$t/r/scripts"
  cp scripts/check-mise-locks "$t/r/scripts/" && cp .mise.toml .mise.sign.toml mise.sign.lock "$t/r/"
  git -C "$t/r" init -q && git -C "$t/r" add -A
}
edit() { python3 -I - "$t/r/$1" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
assert a in s, a
open(p, "w").write(s.replace(a, b, 1))
PY
}
expect() { # DESCRIPTION EXIT [MESSAGE]
  n=$((n + 1))
  rc=0
  "$t/r/scripts/check-mise-locks" >"$t/out" 2>&1 || rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -- "$3" "$t/out"; }; then echo "ok    $1"; else echo "FAIL  $1 (rc=$rc)" >&2; cat "$t/out" >&2; fail=1; fi
}

fresh; expect "the real files pass" 0
fresh; edit mise.sign.lock 'url = "https://' 'url = "http://'; expect "an http url" 1 "url is not"
fresh; edit mise.sign.lock 'https://github.com/sigstore/' 'https://evil.example/sigstore/'; expect "a foreign host" 1 "url is not"
fresh; edit mise.sign.lock '/v3.1.4/cosign-linux-amd64' '/v3.1.4/../v9/cosign-linux-amd64'; expect "a dot segment" 1 "url is not"
fresh; edit mise.sign.lock 'releases/download/v3.1.4/' 'releases/download/v3.1.3/'; expect "a tag that is not the locked version" 1 "url is not"
fresh; edit mise.sign.lock 'checksum = "sha256:' 'checksum = "md5:'; expect "a checksum that is not sha256" 1 "no sha256 checksum"
fresh; edit mise.sign.lock 'provenance = "cosign"' 'provenance = "github-attestations"'; expect "the wrong provenance for a tool" 1 "provenance is"
fresh; edit mise.sign.lock 'provenance = "cosign"
' ''; expect "a missing provenance" 1 "provenance is None"
fresh; edit mise.sign.lock 'checksum_source = "mise-versions"' 'checksum_source = "evil"'; expect "a foreign checksum_source" 1 "checksum_source"
fresh; edit mise.sign.lock 'lockfile_version = 3' 'lockfile_version = 3
extra = 1'; expect "an extra top-level key" 1 "unexpected top-level keys"
fresh; edit mise.sign.lock 'backend = "aqua:sigstore/cosign"' 'backend = "ubi:sigstore/cosign"'; expect "a changed backend" 1 "backend"
fresh; edit mise.sign.lock '[tools."aqua:sigstore/cosign"."platforms.macos-arm64"]' '[tools."aqua:sigstore/cosign"."platforms.freebsd-x64"]'; expect "a missing platform" 1 "platforms"
fresh; edit .mise.sign.toml '"aqua:anchore/syft" = "1.55.0"' '"aqua:anchore/syft" = "1.54.1"'; expect "a pin bumped without relocking" 1 "the pin is"
fresh; edit .mise.sign.toml '"aqua:jqlang/jq" = "1.8.2"' '"aqua:jqlang/jq" = "1.8.2"
"aqua:rhysd/actionlint" = "1.7.12"'; expect "a new pin without a lock entry" 1 "are not the pins"
fresh; edit mise.sign.lock '[[tools."aqua:anchore/syft"]]' '[[tools."aqua:evil/tool"]]
version = "1"
backend = "aqua:evil/tool"
specifiers = ["1"]

[[tools."aqua:anchore/syft"]]'; expect "a lock entry for a tool that is not pinned" 1 "are not the pins"
fresh; : >"$t/r/mise.lock"; git -C "$t/r" add -A; expect "a stray mise.lock" 1 "mise would load"
fresh; : >"$t/r/mise.local.toml"; git -C "$t/r" add -A; expect "a stray mise.local.toml" 1 "mise would load"
fresh; mkdir "$t/r/.config"; : >"$t/r/.config/mise.toml"; git -C "$t/r" add -A; expect "a stray .config/mise.toml" 1 "mise would load"

echo "$n checks"
exit "$fail"
