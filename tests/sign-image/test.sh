#!/usr/bin/env bash
# Tests the sign-image workflow's scripts and inline steps against fake crane, cosign, syft and curl commands (no
# network, no credentials): an image is refused before anything is signed unless it is the caller's commit, its base
# plus one layer, with a base signed by the caller's main; the workflow refuses bad inputs and any reference to
# itself that is not a full SHA; and every verification names the repository, ref and commit. Run by scripts/validate;
# also: tests/sign-image/test.sh
# shellcheck disable=SC2016,SC2034 # the conditions given to check() are single-quoted on purpose: they are eval'd after each run, with $rc
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scripts=$PWD/scripts/sign-image
workflow=$PWD/.github/workflows/sign-image.yaml
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"

d() { local c=$1; printf "${c}%.0s" {1..64}; } # a sha256 hex of one repeated digit
sha=$(printf 'a%.0s' {1..40})
ci_sha=$(printf 'c%.0s' {1..40})
image=ghcr.io/krohmag-industries/app
digest=sha256:$(d 1)
base=ghcr.io/krohmag-industries/app-base@sha256:$(d 2)
signer='^https://github\.com/krohmag-industries/app/\.github/workflows/base\.yaml@refs/heads/main$'

cat >"$t/bin/crane" <<STUB
#!/usr/bin/env bash
case \$1 in
  config) cat "$t/config.json" ;;
  manifest) case \$2 in *app-base*) cat "$t/base-manifest.json" ;; *) cat "$t/image-manifest.json" ;; esac ;;
esac
STUB
cat >"$t/bin/cosign" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$t/cosign.calls"
if [ -n "\${FAKE_COSIGN_FAIL:-}" ] && grep -qE -- "\$FAKE_COSIGN_FAIL" <<<"\$*"; then exit 1; fi
STUB
cat >"$t/bin/syft" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do case \$a in spdx-json=*) cp "$t/sbom.json" "\${a#spdx-json=}" ;; esac; done
STUB
cat >"$t/bin/curl" <<STUB
#!/usr/bin/env bash
out=
while [ \$# -gt 0 ]; do case \$1 in -o) out=\$2; shift ;; esac; shift; done
cp "$t/token-response.json" "\$out"
STUB
chmod +x "$t"/bin/*
export PATH="$t/bin:$PATH"

fixtures() {
  jq -n --arg sha "$sha" --arg base "${base%@*}" --arg bd "${base#*@}" \
    '{architecture:"amd64", os:"linux", config:{Labels:{"org.opencontainers.image.revision":$sha,
      "org.opencontainers.image.base.name":$base, "org.opencontainers.image.base.digest":$bd}}}' >"$t/config.json"
  echo '{"layers":[{"digest":"sha256:l1"},{"digest":"sha256:l2"}]}' >"$t/base-manifest.json"
  echo '{"layers":[{"digest":"sha256:l1"},{"digest":"sha256:l2"},{"digest":"sha256:l3"}]}' >"$t/image-manifest.json"
  jq -n '{packages:[{name:"git"},{name:"libc6"}]}' >"$t/sbom.json"
}

n=0 fail=0
# check DESCRIPTION CONDITION: the condition is eval'd after the command ran, with $rc, $t and the logs in scope
check() {
  n=$((n + 1))
  if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1" >&2; fail=1; fi
}

run_predicates() { # [ARGS...] with the good defaults
  rm -rf "$t/out" "$t/cosign.calls"
  rc=0
  GITHUB_SHA=$sha GITHUB_REPOSITORY=krohmag-industries/app GITHUB_REF=refs/heads/main \
    GITHUB_WORKFLOW_REF=krohmag-industries/app/.github/workflows/validate.yaml@refs/heads/main \
    JOB_WORKFLOW_REF=krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha \
    "$scripts/predicates" "${1:-$image@$digest}" "${2:-$base}" "${3:-$signer}" "$t/out" >"$t/log" 2>&1 || rc=$?
}

fixtures
run_predicates
check "a good image gets its SBOM and provenance" '[ $rc = 0 ] && [ -s "$t/out/sbom.spdx.json" ] && [ -s "$t/out/provenance.json" ]'
check "the base is verified against the caller repository and main" \
  'grep -qF -- "--certificate-identity-regexp $signer --certificate-github-workflow-repository krohmag-industries/app --certificate-github-workflow-ref refs/heads/main $base" "$t/cosign.calls"'
check "the provenance names the caller, the base and the signing workflow's commit" \
  'jq -e --arg c "$ci_sha" --arg s "$sha" ".buildDefinition.resolvedDependencies | any(.digest.gitCommit == \$c) and any(.digest.gitCommit == \$s)" "$t/out/provenance.json" >/dev/null &&
   jq -e ".runDetails.builder.id == \"https://github.com/krohmag-industries/ci/.github/workflows/sign-image.yaml\"" "$t/out/provenance.json" >/dev/null'

refused() { # DESCRIPTION MESSAGE: the last run_predicates must have failed with MESSAGE (signing is a later script, so it never ran)
  want=$2
  check "refused: $1" '[ $rc != 0 ] && grep -q -- "$want" "$t/log"'
}
fixtures; jq '.config.Labels["org.opencontainers.image.revision"]="deadbeef"' "$t/config.json" >"$t/c" && mv "$t/c" "$t/config.json"
run_predicates; refused "a revision label that is not the commit" "revision label is not"
fixtures; jq '.architecture="arm64"' "$t/config.json" >"$t/c" && mv "$t/c" "$t/config.json"
run_predicates; refused "an arm64 image" "not linux/amd64"
fixtures; jq '.config.Labels["org.opencontainers.image.base.name"]="ghcr.io/krohmag-industries/other"' "$t/config.json" >"$t/c" && mv "$t/c" "$t/config.json"
run_predicates; refused "a base name label that is not the named base" "base name label"
fixtures; jq '.config.Labels["org.opencontainers.image.base.digest"]="sha256:'"$(d 3)"'"' "$t/config.json" >"$t/c" && mv "$t/c" "$t/config.json"
run_predicates; refused "a base digest label that is not the named base" "base digest label"
fixtures; echo '{"layers":[{"digest":"sha256:l1"},{"digest":"sha256:l2"},{"digest":"sha256:l3"},{"digest":"sha256:l4"}]}' >"$t/image-manifest.json"
run_predicates; refused "two layers on the base" "layers are not"
fixtures; echo '{"layers":[{"digest":"sha256:l1"},{"digest":"sha256:l2"}]}' >"$t/image-manifest.json"
run_predicates; refused "no layer on the base" "layers are not"
fixtures; echo '{"layers":[{"digest":"sha256:x1"},{"digest":"sha256:x2"},{"digest":"sha256:l3"}]}' >"$t/image-manifest.json"
run_predicates; refused "layers that are not the base's" "layers are not"
fixtures; FAKE_COSIGN_FAIL='certificate-identity-regexp' run_predicates
refused "a base without the expected signature" "has no signature"
fixtures; jq -n '{packages:[]}' >"$t/sbom.json"; run_predicates; refused "an empty SBOM" "lists no packages"
fixtures; SBOM_PACKAGES="git curl" run_predicates; refused "an SBOM missing a required package" "curl is not in the SBOM"
fixtures; run_predicates "$image:latest"; refused "a tag instead of a digest" "not a digest reference"
fixtures; run_predicates "$image@$digest" "ghcr.io/krohmag-industries/app-base"; refused "a base without a digest" "not a digest reference"

# sign: signs first, then verifies each result twice (exact subject and pattern) with repository, ref and commit
mkdir -p "$t/preds" && echo '{}' >"$t/preds/sbom.spdx.json" && echo '{}' >"$t/preds/provenance.json"
run_sign() {
  rm -f "$t/cosign.calls"
  rc=0
  GITHUB_SHA=$sha GITHUB_REPOSITORY=krohmag-industries/app GITHUB_REF=refs/pull/7/merge \
    JOB_WORKFLOW_REF=krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha \
    "$scripts/sign" "$image@$digest" "$t/preds" >"$t/log" 2>&1 || rc=$?
}
run_sign
check "sign: signs first, then verifies, then attests both types" \
  '[ $rc = 0 ] && [ "$(awk "{print \$1}" "$t/cosign.calls" | tr "\n" " ")" = "sign verify verify attest verify-attestation verify-attestation attest verify-attestation verify-attestation " ]'
check "sign: every verification names the repository, the run's ref and the commit" \
  'v=$(grep -c "^verify" "$t/cosign.calls"); [ "$v" = 6 ] && [ "$(grep "^verify" "$t/cosign.calls" | grep -c -- "--certificate-github-workflow-repository krohmag-industries/app --certificate-github-workflow-ref refs/pull/7/merge --certificate-github-workflow-sha $sha")" = 6 ]'
check "sign: one verification per kind uses the exact subject, one the pattern" \
  '[ "$(grep -c -- "--certificate-identity https://github.com/krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha" "$t/cosign.calls")" = 3 ] &&
   [ "$(grep -c -- "--certificate-identity-regexp ^https://github\\\\.com/krohmag-industries/ci/\\\\.github/workflows/sign-image\\\\.yaml@\\[0-9a-f\\]{40}\\$" "$t/cosign.calls")" = 3 ]'
FAKE_COSIGN_FAIL='^verify ' run_sign
check "sign: a signature that does not verify stops before any attestation" '[ $rc != 0 ] && ! grep -q "^attest" "$t/cosign.calls"'
rm "$t/preds/provenance.json"; run_sign
check "sign: missing predicates sign nothing" '[ $rc != 0 ] && [ ! -e "$t/cosign.calls" ]'

# The workflow's own steps, extracted from the YAML and run with fake inputs
step() { yq ".jobs.sign.steps[] | select(.name == \"$1\") | .run" "$workflow"; }
validate_inputs() { # [VAR=VALUE]...
  rc=0
  env OWNER=krohmag-industries REPO=krohmag-industries/app GITHUB_REF=refs/heads/main IMAGE="$image" DIGEST="$digest" BASE="$base" BASE_SIGNER="$signer" TAG=main SBOM_PACKAGES="git ca-certificates" "$@" \
    bash -c "$(step 'Validate the inputs')" >"$t/log" 2>&1 || rc=$?
}
validate_inputs; check "inputs: a good call is accepted" '[ $rc = 0 ]'
validate_inputs OWNER=Krohmag-Industries; check "inputs: the owner compares lower-cased" '[ $rc = 0 ]'
validate_inputs IMAGE=ghcr.io/krohmag-industries/app-extra; check "inputs: an image named app-<x> is accepted" '[ $rc = 0 ]'
validate_inputs IMAGE=ghcr.io/krohmag-industries/app/sub; check "inputs: an image named app/<x> is accepted" '[ $rc = 0 ]'
validate_inputs TAG=main GITHUB_REF=refs/pull/1/merge TAG=; check "inputs: no tag, any ref" '[ $rc = 0 ]'
validate_inputs TAG= SBOM_PACKAGES=; check "inputs: tag and sbom-packages are optional" '[ $rc = 0 ]'
bad() { validate_inputs "$1"; check "inputs: refused $2" '[ $rc != 0 ]'; }
bad "IMAGE=ghcr.io/other-org/app" "an image in another owner's namespace"
bad "IMAGE=ghcr.io/krohmag-industries/other-repo" "an image of another repository"
bad "IMAGE=ghcr.io/krohmag-industries/application" "an image that only starts with the repository name"
bad "IMAGE=$image:latest" "an image with a tag"
bad "IMAGE=ghcr.io/krohmag-industries/../other/app" "an image path with .."
bad "IMAGE=docker.io/krohmag-industries/app" "another registry"
bad "DIGEST=sha256:abc" "a short digest"
bad "BASE=ghcr.io/krohmag-industries/app-base:latest" "a base by tag"
bad "BASE=ghcr.io/other-org/base@sha256:$(d 2)" "a base in another owner's namespace"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/.*$' "a base-signer with a wildcard"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/app/x|.*$' "a base-signer with an alternation"
bad 'BASE_SIGNER=^https://github\.com/other-org/app/x$' "a base-signer for another owner"
bad 'BASE_SIGNER=https://github\.com/krohmag-industries/app/x$' "a base-signer that is not anchored at the start"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/app/x' "a base-signer that is not anchored at the end"
bad 'BASE_SIGNER=^https://github.com/krohmag-industries/app/x$' "a base-signer with an unescaped dot"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/\w\w\w/x$' "a base-signer with a character class"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/\Qx$' "a base-signer with a quote escape"
bad 'TAG=a b' "a tag with a space"
bad "TAG=sha256-$(d 1).sig" "cosign's signature tag"
bad "TAG=sha256-$(d 1)" "cosign's tag prefix"
bad 'TAG=x.att' "an attestation tag suffix"
bad 'TAG=x.sbom' "an sbom tag suffix"
validate_inputs TAG=main GITHUB_REF=refs/pull/1/merge; check "inputs: refused a tag moved from a pull request ref" '[ $rc != 0 ] && grep -q "refs/heads/main" "$t/log"'
bad 'TAG=$(id)' "a tag with a command substitution"
bad 'SBOM_PACKAGES=git;id' "sbom-packages with a shell metacharacter"
bad 'SBOM_PACKAGES=git*' "sbom-packages with a glob"
bad "TAG=$(printf 'a%.0s' {1..129})" "a tag longer than 128 characters"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/a^b$' "a base-signer with a ^ in the middle"
bad 'BASE_SIGNER=^https://github\.com/krohmag-industries/a$b$' "a base-signer with a $ in the middle"

# The OIDC claims step: a fake token whose payload names the called workflow
b64url() { base64 | tr -d '=\n' | tr '+/' '-_'; }
read_claims() { # JOB_WORKFLOW_REF JOB_WORKFLOW_SHA
  local payload
  payload=$(jq -nc --arg r "$1" --arg s "$2" '{job_workflow_ref:$r, job_workflow_sha:$s, other:"é"}' | b64url)
  jq -n --arg v "h.$payload.sig" '{value:$v}' >"$t/token-response.json"
  : >"$t/github_env"
  rc=0
  env RUNNER_TEMP="$t" GITHUB_ENV="$t/github_env" ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/token ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-request-token \
    bash -c "$(step 'Read this workflow'"'"'s commit from the OIDC claims')" >"$t/log" 2>&1 || rc=$?
}
read_claims "krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha" "$ci_sha"
check "claims: a full-SHA reference is accepted and exported" \
  '[ $rc = 0 ] && grep -qx "JOB_WORKFLOW_REF=krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha" "$t/github_env" && grep -qx "JOB_WORKFLOW_SHA=$ci_sha" "$t/github_env"'
check "claims: the request token is never printed" '! grep -q "secret-request-token" "$t/log"'
check "claims: nothing is left in the temp dir" '[ -z "$(ls -d "$t"/oidc.* 2>/dev/null)" ]'
read_claims "krohmag-industries/ci/.github/workflows/sign-image.yaml@refs/heads/main" "$ci_sha"
check "claims: a branch reference is refused" '[ $rc != 0 ] && [ ! -s "$t/github_env" ]'
read_claims "krohmag-industries/ci/.github/workflows/sign-image.yaml@v1.1.0" "$ci_sha"
check "claims: a tag reference is refused" '[ $rc != 0 ] && [ ! -s "$t/github_env" ]'
read_claims "krohmag-industries/ci/.github/workflows/sign-image.yaml@$ci_sha" "$(printf 'd%.0s' {1..40})"
check "claims: a reference whose SHA is not job_workflow_sha is refused" '[ $rc != 0 ] && [ ! -s "$t/github_env" ]'
read_claims "evil/ci/.github/workflows/sign-image.yaml@$ci_sha" "$ci_sha"
check "claims: a copy of the workflow in another repository is refused" '[ $rc != 0 ] && [ ! -s "$t/github_env" ]'
read_claims "krohmag-industries/ci/.github/workflows/other.yaml@$ci_sha" "$ci_sha"
check "claims: another workflow of ci is refused" '[ $rc != 0 ] && [ ! -s "$t/github_env" ]'

echo "$n checks"
exit "$fail"
