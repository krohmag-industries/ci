#!/usr/bin/env bash
# Usage: job-resources.sh (the job-resources action runs it)
# Prints what this job's container used, for sizing the CI runners (docs/runner.md "Capacity"): the container
# cgroup's peak and current memory against its limit, CPU seconds, and CPU/IO pressure (share of time something
# waited, over the last 60 s). The peak includes reclaimable page cache, so it overstates what the job needs.
# Appends a table to the job summary when GITHUB_STEP_SUMMARY is set. Does nothing where cgroup v2 isn't visible
# (a hosted runner shows the whole VM's root cgroup, which has no memory.peak). Never fails the job.
set -uo pipefail

cg=/sys/fs/cgroup
[ -r "$cg/memory.peak" ] || { echo "job-resources: no $cg/memory.peak here; skipping"; exit 0; }

mib() { awk -v b="$1" 'BEGIN { if (b ~ /^[0-9]+$/) printf "%.0f MiB", b / 1048576; else print b }'; }
pressure() { sed -n 's/^some .*avg60=\([0-9.]*\).*/\1%/p' "$cg/$1.pressure" 2>/dev/null; }

peak=$(mib "$(cat "$cg/memory.peak")")
current=$(mib "$(cat "$cg/memory.current" 2>/dev/null)")
limit=$(mib "$(cat "$cg/memory.max" 2>/dev/null)")
cpu=$(awk '/^usage_usec/ { printf "%.0f s", $2 / 1e6 }' "$cg/cpu.stat" 2>/dev/null)

line="memory peak ${peak}, now ${current}, limit ${limit}; cpu ${cpu:-?}; pressure avg60 cpu $(pressure cpu), io $(pressure io)"
echo "job-resources: $line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Runner resources (${GITHUB_JOB:-job})"
    echo "| memory peak | memory now | memory limit | cpu time | cpu pressure | io pressure |"
    echo "|---|---|---|---|---|---|"
    echo "| ${peak} | ${current} | ${limit} | ${cpu:-?} | $(pressure cpu) | $(pressure io) |"
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
