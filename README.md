# ci

Shared CI for the krohmag-industries repos (kroh-lab, blaster, reelpick, spyglass). Why and how:
kroh-lab `docs/decisions.md`, "A shared CI repo".

- `actions/setup-mise`: download a pinned mise, check its SHA256, install, add to PATH. Input `version`.
- `actions/job-resources`: log the job's memory peak and CPU; quiet no-op without cgroup v2.

Callers pin by full commit SHA: `uses: krohmag-industries/ci/actions/<name>@<sha> # <ref>`.
Change one repo's pin first (kroh-lab), then the rest.

## Reusable workflow: `sign-image`

`.github/workflows/sign-image.yaml` signs an image a repo's build job pushed (keyless cosign), attests its SBOM and SLSA
provenance, verifies all three, and optionally moves a tag. The signature's identity is the workflow file:
`https://github.com/krohmag-industries/ci/.github/workflows/sign-image.yaml@<the SHA the caller wrote>`, with the caller in the
certificate's extensions (repository, ref, commit). Consumers match the subject with a pattern and pin the caller from the
extensions (`--certificate-github-workflow-repository`, `-ref`); kroh-lab `docs/decisions.md`, "Signing identity, tested".

```yaml
  sign:
    needs: build            # the caller's build job pushes the image and outputs its digest; it never holds id-token
    permissions: {contents: read, packages: write, id-token: write}
    uses: krohmag-industries/ci/.github/workflows/sign-image.yaml@<full sha> # vX.Y.Z
    with:
      image: ghcr.io/krohmag-industries/app            # no tag; the caller's repository name, optionally followed by - or /
      digest: ${{ needs.build.outputs.digest }}
      base: ghcr.io/krohmag-industries/app-base@sha256:...   # the base the build used, pinned by digest
      base-signer: '^https://github\.com/krohmag-industries/app/\.github/workflows/base\.yaml@refs/heads/main$'
      tag: main                                        # optional: moved only after everything verified, and only from refs/heads/main
      sbom-packages: 'git ca-certificates'             # optional: names the SBOM must list
      sbom-min-packages: '50'                          # optional: the least number of packages it must list (1 to 10000)
```

What it refuses before signing anything: an image whose revision label is not the caller's commit (`GITHUB_SHA`), that is not
linux/amd64, whose base labels are not `base`, whose layers are not the base's plus exactly one, or whose base lacks a keyless
signature matching `base-signer` from the caller repository's `main`; an SBOM with fewer packages than `sbom-min-packages` (at
least one when it is empty or unset); inputs that are not what they claim to be;
and a call that names this workflow by anything but a full commit SHA.

How the job holds the signing identity (`id-token: write`) safely:

- **The code that runs is the code the certificate names.** `uses:` and a plain checkout resolve to the caller's workspace, and a
  workflow can't name its own SHA, so the job reads `job_workflow_sha` from its OIDC token (the one place GitHub exposes it),
  requires it to equal the SHA in `job_workflow_ref`, and checks `ci` out at that commit. Scripts and tool pins
  (`.mise.sign.toml`) come from there.
- **No caller code runs and the caller's repository is not checked out.** The caller hands over an image, a digest and a base;
  the SBOM is syft's scan of the registry and the provenance is built from GitHub's environment, never taken from the build.
- Inputs reach shell only through `env:` after regexp validation; none is a path or a ref. `base-signer` is limited to one
  literal subject: the anchors, letters, digits and `_ : / @ -`, and `\.`. `image` must be the caller's repository name (or
  start with it plus `-` or `/`). `tag` may not be one of cosign's own tags (`sha256-<digest>`, `.sig`, `.att`, `.sbom`) and is
  moved only from `refs/heads/main`.
- The step that reads the pushed image (`predicates`: crane, syft, cosign) runs without the OIDC request variables, so only the
  signing step can mint a token.
- Every verification runs twice: against this run's own workflow exactly, and against the pattern consumers use, with the
  caller's repository, ref and commit, so a pattern that doesn't match fails here and not in a cluster.

Test: `tests/sign-image/test.sh` (fake crane, cosign, syft and curl), run by `scripts/validate`, covers the scripts and the
workflow's input and OIDC-claim steps. The checkout, tool install, registry login, summary and tag steps run only for real: a
run needs a package to push to; see kroh-lab `docs/decisions.md`. The caller's build is expected to have pushed
`<image>:<commit sha>`; nothing here creates that tag.

Callers must pin a full SHA (the org requires it). The subject carries that SHA, so any `ci` commit satisfies a policy that
matches `[0-9a-f]{40}`: the control is the callers' reviewed pin PRs.

Limits to know:

- The signature plus the policy's repository and ref checks are the trust. The image's revision label, the layer check,
  `sbom-packages` and `sbom-min-packages` are sanity checks: the build wrote the image, so a compromised build can make
  them pass. The provenance records what GitHub's environment says (commit, base, workflow, run); it is not build provenance.
- Two quick pushes can finish out of order and the older run can move `tag` back to an older, still-signed digest. Give the
  caller's sign job a `concurrency` group (`cancel-in-progress: false`) if that matters.
- Keyless signatures go to Sigstore's public Rekor log: the caller's repository name, ref, commit and run URL become public, even
  for a private repository.
- The signing tools are pinned in `.mise.sign.toml` and locked in `mise.sign.lock` (checksums, and the provenance mise
  re-checks with `MISE_LOCKED_VERIFY_PROVENANCE`). The job sets `MISE_OVERRIDE_CONFIG_FILENAMES`, so mise reads only
  `.mise.sign.toml`: no other config file in the checkout is loaded. `scripts/check-mise-locks` (run by `scripts/validate`)
  pins what a legitimate lock may contain, because `mise install --locked` trusts an entry as written, and fails a lock that no
  longer matches `.mise.sign.toml`. A tool bump needs `MISE_ENV=sign mise lock --platform linux-x64,macos-arm64 <tools>` by
  hand (`MISE_ENV` only selects the file when generating the lock; no Renovate here yet). Only linux-x64 and macos-arm64
  are locked; any other runner architecture fails closed. go-containerregistry (crane) publishes no provenance, so its
  checksum comes from mise-versions: a weaker pin than the other three. blaster has a similar lint for its own locks; a fix
  to one is a fix to both. The mise binary itself is still checked only against SHASUMS256.txt from its own release.