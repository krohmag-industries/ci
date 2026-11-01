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
      image: ghcr.io/krohmag-industries/app            # no tag; under the caller's owner
      digest: ${{ needs.build.outputs.digest }}
      base: ghcr.io/krohmag-industries/app-base@sha256:...   # the base the build used, pinned by digest
      base-signer: '^https://github\.com/krohmag-industries/app/\.github/workflows/base\.yaml@refs/heads/main$'
      tag: main                                        # optional: moved only after everything verified
      sbom-packages: 'git ca-certificates'             # optional: names the SBOM must list
```

What it refuses before signing anything: an image whose revision label is not the caller's commit (`GITHUB_SHA`), that is not
linux/amd64, whose base labels are not `base`, whose layers are not the base's plus exactly one, or whose base lacks a keyless
signature matching `base-signer` from the caller repository's `main`; an empty SBOM; inputs that are not what they claim to be;
and a call that names this workflow by anything but a full commit SHA.

How the job holds the signing identity (`id-token: write`) safely:

- **The code that runs is the code the certificate names.** `uses:` and a plain checkout resolve to the caller's workspace, and a
  workflow can't name its own SHA, so the job reads `job_workflow_sha` from its OIDC token (the one place GitHub exposes it),
  requires it to equal the SHA in `job_workflow_ref`, and checks `ci` out at that commit. Scripts and tool pins
  (`.mise.sign.toml`) come from there.
- **No caller code runs and the caller's repository is not checked out.** The caller hands over an image, a digest and a base;
  the SBOM is syft's scan of the registry and the provenance is built from GitHub's environment, never taken from the build.
- Inputs reach shell only through `env:` after regexp validation; none is a path or a ref. `base-signer` is limited to one
  literal subject (no wildcards or alternation).
- Every verification runs twice: against this run's own workflow exactly, and against the pattern consumers use, with the
  caller's repository, ref and commit, so a pattern that doesn't match fails here and not in a cluster.

Test: `tests/sign-image/test.sh` (fake crane, cosign, syft and curl), run by `scripts/validate`. A real run needs a package to push to; see
kroh-lab `docs/decisions.md`.

Callers must pin a full SHA (the org requires it). The subject carries that SHA, so any `ci` commit satisfies a policy that
matches `[0-9a-f]{40}`: the control is the callers' reviewed pin PRs.
