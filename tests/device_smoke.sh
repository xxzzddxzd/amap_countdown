#!/usr/bin/env bash
# Run on the computer connected to the iPhone. This script only reads the phone.
set -euo pipefail

target=root@127.0.0.1
port=2224
output_dir=./device-smoke-reports
usage() {
    printf '%s\n' "Usage: $0 [--target user@host] [--port port] [--output-dir local-directory]"
}
while (($#)); do
    case "$1" in
        --target|--port|--output-dir)
            if (($# < 2)); then usage >&2; exit 2; fi
            case "$1" in
                --target) target=$2 ;;
                --port) port=$2 ;;
                --output-dir) output_dir=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ -z "$target" || "$target" == -* || "$target" == *[[:space:]]* ||
      ! "$port" =~ ^[0-9]{1,5}$ ]]; then
    printf '%s\n' 'Invalid SSH target or port.' >&2
    exit 2
fi
if ((10#$port < 1 || 10#$port > 65535)); then
    printf '%s\n' 'SSH port must be between 1 and 65535.' >&2
    exit 2
fi
command -v ssh >/dev/null
command -v tee >/dev/null
mkdir -p "$output_dir"
report="$output_dir/device-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
printf 'Read-only device diagnostics; local report: %s\n' "$report"

# Authentication and host-key verification use the normal SSH configuration.
# No passwords, installation, process restarts or device-side output files.
if ssh -p "$port" -o ConnectTimeout=10 -- "$target" sh -s 2>&1 <<'REMOTE' | tee "$report"
set -u
PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}
export PATH
failed=0
printf 'COLLECTED_AT_UTC: '
date -u '+%Y-%m-%dT%H:%M:%SZ'
printf 'ARCHITECTURE: '
uname -m
printf '%s\n' 'EXPECTED_PLUGIN: com.dsh.amapcycleassist 1.1.0'
printf '%s\n' 'SUPPORTED_AMAP: 16.11.1; manually verify the installed app version before launching it.'

if [ -d /var/jb ]; then
    printf '%s\n' 'ROOTLESS_PATH: PRESENT /var/jb'
else
    printf '%s\n' 'ROOTLESS_PATH: MISSING /var/jb'
    failed=1
fi
if command -v sw_vers >/dev/null 2>&1; then
    printf 'IOS_VERSION: '
    sw_vers -productVersion || printf '%s\n' 'UNAVAILABLE'
elif command -v plutil >/dev/null 2>&1; then
    printf 'IOS_VERSION: '
    plutil -extract ProductVersion raw -o - /System/Library/CoreServices/SystemVersion.plist 2>/dev/null || printf '%s\n' 'UNAVAILABLE; manually verify iOS >= 15'
else
    printf '%s\n' 'IOS_VERSION: UNAVAILABLE; manually verify iOS >= 15'
fi

if command -v dpkg-query >/dev/null 2>&1; then
    for package in com.dsh.amapcycleassist ellekit; do
        if details=$(dpkg-query -W -f='${Status} ${Version}' "$package" 2>/dev/null); then
            printf 'PACKAGE: %s %s\n' "$package" "$details"
            case "$details" in
                'install ok installed '*) ;;
                *) failed=1 ;;
            esac
            if [ "$package" = com.dsh.amapcycleassist ] && [ "$details" != 'install ok installed 1.1.0' ]; then
                printf '%s\n' 'PLUGIN_VERSION: DOES_NOT_MATCH 1.1.0'
                failed=1
            fi
        else
            printf 'PACKAGE: %s NOT_FOUND\n' "$package"
            failed=1
        fi
    done
else
    printf '%s\n' 'PACKAGE_QUERY: UNAVAILABLE'
    failed=1
fi
for file in /var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib /var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.plist; do
    if [ -f "$file" ]; then
        ls -ln "$file"
    else
        printf 'INSTALLED_FILE: MISSING %s\n' "$file"
        failed=1
    fi
done

# Inspect only these exact plugin-owned paths in one-level app containers.
logs=0
for log in /var/mobile/Containers/Data/Application/*/tmp/amap-signal-countdown.log; do
    [ -f "$log" ] || continue
    logs=$((logs + 1))
    printf '\nLOG_CANDIDATE: %s\n' "$log"
    ls -ln "$log"
    if recent=$(tail -n 300 "$log" 2>/dev/null); then
        printf '%s\n' 'LOG_EVIDENCE: HISTORICAL, limited to the last 300 lines; does not prove a current running process.'
        printf '%s\n' "$recent" | grep -E 'native countdown hooks installed|hook installation failed|countdown HUD started|signal history open=' | tail -n 8 || :
        if printf '%s\n' "$recent" | grep -q 'native countdown hooks installed .*version=1\.1\.0'; then
            printf '%s\n' 'HOOK_1.1.0_EVIDENCE: FOUND_IN_BOUNDED_WINDOW'
        else
            printf '%s\n' 'HOOK_1.1.0_EVIDENCE: NOT_FOUND_IN_BOUNDED_WINDOW'
        fi
        if printf '%s\n' "$recent" | grep -q 'signal history open=1 route=1'; then
            printf '%s\n' 'HISTORY_OPEN_EVIDENCE: FOUND_IN_BOUNDED_WINDOW'
        else
            printf '%s\n' 'HISTORY_OPEN_EVIDENCE: NOT_FOUND_IN_BOUNDED_WINDOW'
        fi
        printf '%s\n' 'RECENT_PLUGIN_LOG:'
        printf '%s\n' "$recent" | tail -n 12
    else
        printf '%s\n' 'LOG_READ: FAILED'
    fi
done
[ "$logs" -gt 0 ] || printf '%s\n' 'PLUGIN_LOG: NOT_FOUND; app may not have run or its container may differ.'

databases=0
for db in /var/mobile/Containers/Data/Application/*/Library/'Application Support'/AMapSignalCountdown/Signals.sqlite3; do
    [ -f "$db" ] || continue
    databases=$((databases + 1))
    printf '\nDB_CANDIDATE: %s\n' "$db"
    ls -ln "$db"
    if command -v sqlite3 >/dev/null 2>&1; then
        printf '%s\n' 'DB_READ_ONLY: quick_check, schema version, counts, and up to 20 model ages; no database/WAL copy.'
        if ! sqlite3 -readonly -header -column "$db" <<'SQL'
PRAGMA quick_check;
PRAGMA user_version;
SELECT 'directions' AS table_name, COUNT(*) AS rows FROM directions
UNION ALL SELECT 'phases', COUNT(*) FROM phases
UNION ALL SELECT 'models', COUNT(*) FROM models
UNION ALL SELECT 'observations', COUNT(*) FROM observations;
SELECT signal_id, approach_key, valid, CAST(strftime('%s','now') - learned_at AS INTEGER) AS age_seconds,
       CASE WHEN valid=1 AND learned_at>0 AND strftime('%s','now')-learned_at BETWEEN 0 AND 21600
            THEN 'ELIGIBLE_BY_AGE_ONLY' ELSE 'NOT_ELIGIBLE' END AS age_status
FROM models ORDER BY learned_at DESC LIMIT 20;
SQL
        then
            printf '%s\n' 'DB_READ_ONLY: FAILED'
            failed=1
        fi
    else
        printf '%s\n' 'DB_QUERY: NOT_TESTED; sqlite3 unavailable, file size shown above.'
    fi
done
[ "$databases" -gt 0 ] || printf '%s\n' 'PLUGIN_DB: NOT_FOUND; app may not have run or its container may differ.'
printf '\n%s\n' 'UI_THREE_REGIONS: NOT_TESTED' 'DIRECTION_AND_BLACKLIST_BEHAVIOR: NOT_TESTED' 'UP_DOWN_SWIPE: NOT_TESTED' 'NAVIGATION_CAPTURE: NOT_TESTED' 'HISTORICAL_PREDICTION_BEHAVIOR: NOT_TESTED'
printf 'STATIC_DIAGNOSTIC_EXIT: %s (0 means collection/checks completed, not a device test PASS)\n' "$failed"
exit "$failed"
REMOTE
then
    printf 'Diagnostics collected. UI/navigation/prediction remain NOT_TESTED. Report: %s\n' "$report"
else
    status=$?
    printf 'SSH, diagnostics, or local report writing failed (exit %s). Report: %s\n' "$status" "$report" >&2
    exit "$status"
fi
