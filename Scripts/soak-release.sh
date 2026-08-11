#!/bin/bash
set -euo pipefail

app="${1:-}"
hours="${2:-24}"
output="${3:-soak-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! -d "$app/Contents" || ! "$hours" =~ ^[1-9][0-9]*$ || -e "$output" ]]; then
    echo "usage: $0 /path/to/DiskSwell.app [whole-hours] [new-output-directory]" >&2
    exit 2
fi
if pgrep -f '/DiskSwell.app/Contents/MacOS/DiskSwell$' >/dev/null; then
    echo "Quit the running DiskSwell instance before starting a controlled soak." >&2
    exit 2
fi

mkdir "$output"
log stream --style compact --level debug --predicate 'subsystem == "com.diskswell.DiskSwell"' > "$output/diagnostics.log" &
log_pid=$!
DISKSWELL_DIAGNOSTICS=1 "$app/Contents/MacOS/DiskSwell" &
app_pid=$!
cleanup() {
    kill "$app_pid" "$log_pid" 2>/dev/null || true
    wait "$app_pid" "$log_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

database="$HOME/Library/Application Support/DiskSwell/history.sqlite3"
echo 'utc,elapsed_seconds,cpu_percent,rss_kib,vsz_kib,threads,sqlite_bytes,samples,anomalies' > "$output/process.csv"
started="$(date +%s)"
duration=$((hours * 3600))
while kill -0 "$app_pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - started))
    [[ "$elapsed" -ge "$duration" ]] && break
    process="$(ps -p "$app_pid" -o %cpu=,rss=,vsz=,thcount= | awk '{$1=$1; print $1 "," $2 "," $3 "," $4}')"
    sqlite_bytes=0
    for file in "$database" "$database-wal" "$database-shm"; do
        [[ -f "$file" ]] && sqlite_bytes=$((sqlite_bytes + $(stat -f %z "$file")))
    done
    samples=0
    anomalies=0
    if [[ -f "$database" ]]; then
        samples="$(sqlite3 "$database" 'SELECT COUNT(*) FROM sample;' 2>/dev/null || echo 0)"
        anomalies="$(sqlite3 "$database" 'SELECT COUNT(*) FROM anomaly;' 2>/dev/null || echo 0)"
    fi
    echo "$(date -u +%FT%TZ),$elapsed,$process,$sqlite_bytes,$samples,$anomalies" >> "$output/process.csv"
    sleep 60
done

kill -0 "$app_pid" 2>/dev/null || { echo "DiskSwell exited before the soak completed." >&2; exit 1; }
