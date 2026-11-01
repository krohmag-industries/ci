# ci

Shared CI for the krohmag-industries repos (kroh-lab, blaster, reelpick, spyglass). Why and how:
kroh-lab `docs/decisions.md`, "A shared CI repo".

- `actions/setup-mise`: download a pinned mise, check its SHA256, install, add to PATH. Input `version`.
- `actions/job-resources`: log the job's memory peak and CPU; quiet no-op without cgroup v2.

Callers pin by full commit SHA: `uses: krohmag-industries/ci/actions/<name>@<sha> # <ref>`.
Change one repo's pin first (kroh-lab), then the rest.
