#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$ROOT/scripts/swift-concurrency-baseline.txt"
LOG="${TMPDIR:-/tmp}/siriremoteforge-app-strict-$$.log"
CURRENT="${TMPDIR:-/tmp}/siriremoteforge-app-strict-current-$$.txt"
trap 'rm -f "$LOG" "$CURRENT"' EXIT

test -f "$BASELINE" || { echo "Missing concurrency baseline: $BASELINE" >&2; exit 1; }

# Keep the full strict-build transcript for baseline accounting, but if the build itself fails,
# put a compact compiler/linker summary at the end of the Actions log. GitHub truncates long app
# builds from the front, which previously hid the actual error behind the known warning baseline.
set +e
(cd "$ROOT/app" && HYPERVIBE_STRICT_CONCURRENCY=1 ./build.sh) 2>&1 | tee "$LOG"
build_status=${PIPESTATUS[0]}
set -e
if [ "$build_status" -ne 0 ]; then
    echo "" >&2
    echo "Strict concurrency build failed (exit $build_status). Error summary:" >&2
    grep -nE '(^|[[:space:]])(error:|fatal error:)|undefined symbol|Undefined symbols|ld:|clang: error:|swiftc: error:' "$LOG" \
        | tail -n 80 >&2 || true
    echo "--- final build context ---" >&2
    tail -n 80 "$LOG" >&2 || true
    exit "$build_status"
fi

python3 - "$LOG" "$CURRENT" <<'PY'
from collections import Counter
from pathlib import Path
import re, sys

source, output = map(Path, sys.argv[1:3])
rx = re.compile(r'^(?P<file>.*?\.swift):\d+:\d+: warning: (?P<message>.*)$')
counts = Counter()
for line in source.read_text(errors='replace').splitlines():
    m = rx.match(line)
    if m:
        counts[(Path(m.group('file')).name, m.group('message').strip())] += 1
with output.open('w') as f:
    for (file, message), count in sorted(counts.items()):
        f.write(f'{count}\t{file}\t{message}\n')
PY

python3 - "$BASELINE" "$CURRENT" <<'PY'
from pathlib import Path
import sys

def load(path):
    result = {}
    for raw in Path(path).read_text().splitlines():
        if not raw or raw.startswith('#'):
            continue
        count, file, message = raw.split('\t', 2)
        result[(file, message)] = int(count)
    return result

baseline = load(sys.argv[1])
current = load(sys.argv[2])
regressions = []
for key, count in sorted(current.items()):
    allowed = baseline.get(key, 0)
    if count > allowed:
        regressions.append((key, allowed, count))

if regressions:
    print('New Swift concurrency diagnostics detected:', file=sys.stderr)
    for (file, message), allowed, count in regressions:
        print(f'  {file}: {message} (baseline {allowed}, now {count})', file=sys.stderr)
    raise SystemExit(1)

removed = sum(max(0, baseline.get(key, 0) - count) for key, count in current.items())
removed += sum(count for key, count in baseline.items() if key not in current)
print(f'Concurrency gate passed: {sum(current.values())} known warning instances; baseline can only shrink.')
if removed:
    print(f'Note: {removed} baseline warning instance(s) disappeared; update the baseline in the same change.')
PY
