#!/usr/bin/env bash
#
# check-mavericks-symbols.sh — flag weakly-imported system symbols that may be
# unavailable on the target macOS deployment version (default 10.9 "Mavericks").
#
# When PrismLauncher is compiled against a modern SDK with -mmacosx-version-min=10.9,
# any libSystem / libc++ / framework symbol that was introduced *after* 10.9 is
# emitted as a *weak import*. On a real 10.9 machine that symbol resolves to NULL and
# calling it crashes. This script walks every Mach-O inside a built .app (the launcher
# binary, the bundled Qt frameworks and the Qt plugins), extracts those weak imports
# and diffs them against an accepted baseline, so a rebase or new upstream code that
# starts using a post-10.9 symbol trips CI instead of shipping a broken DMG.
#
# It is the second layer of the guard. The first is the linker flag
# -Wl,-no_weak_imports on the launcher executables (see build-mavericks.yml): that
# fails the *link* the moment our own code references a post-10.9 symbol that isn't
# backfilled by macports-legacy-support. This scanner additionally covers the
# prebuilt Qt frameworks/plugins that the app-level link never re-checks.
#
# Usage:
#   check-mavericks-symbols.sh <path-to-.app | directory | Mach-O file>
#
# Environment:
#   MAVERICKS_SYMBOL_BASELINE   path to the baseline file
#                               (default: <this dir>/mavericks-symbols.baseline.txt)
#   UPDATE_BASELINE=1           rewrite the baseline from the current scan, then exit 0
#
# Exit codes:
#   0  clean, or baseline was (re)generated
#   1  new weak-imported symbols found that are not in the baseline
#   2  usage / environment error
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="${MAVERICKS_SYMBOL_BASELINE:-$SCRIPT_DIR/mavericks-symbols.baseline.txt}"

TARGET="${1:-}"
if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
    echo "usage: $0 <path-to-.app | directory | Mach-O file>" >&2
    exit 2
fi

for tool in nm otool file; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found (need Xcode command line tools)" >&2
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# 1. Collect every Mach-O file under the target.
# ---------------------------------------------------------------------------
machos=()
if [[ -f "$TARGET" ]]; then
    machos+=("$TARGET")
else
    while IFS= read -r -d '' f; do
        if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
            machos+=("$f")
        fi
    done < <(find "$TARGET" -type f -print0)
fi

if [[ ${#machos[@]} -eq 0 ]]; then
    echo "error: no Mach-O binaries found under $TARGET" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Extract weak-imported *system* undefined symbols from each Mach-O.
#
#    `nm -m` prints an undefined weak import as:
#        (undefined) weak external _symbol (from libSystem)
#    Qt's own cross-framework references are ALSO weak/undefined and show up as
#    "(from QtCore)" etc. — those are not OS-availability symbols, so drop anything
#    coming from a bundled Qt framework. Everything else (libSystem, libc++, libobjc,
#    CoreFoundation, Foundation, AppKit, IOKit, Security, ...) is a real OS symbol.
# ---------------------------------------------------------------------------
found="$(mktemp)"          # lines: <symbol>\t<from-lib>\t<binary>
trap 'rm -f "$found"' EXIT

for m in "${machos[@]}"; do
    nm -m "$m" 2>/dev/null | awk -v bin="$(basename "$m")" '
        /\(undefined\)/ && /weak external/ {
            sym=""; lib="";
            for (i = 1; i <= NF; i++) {
                if ($i == "external") sym = $(i + 1);
                if ($i == "(from")   { lib = $(i + 1); sub(/\)$/, "", lib); }
            }
            if (sym == "")       next;   # not the shape we expect
            if (lib ~ /^Qt/)     next;   # Qt-internal cross-framework ref, not an OS symbol
            if (lib == "")       lib = "(flat-namespace)";
            print sym "\t" lib "\t" bin;
        }'
done | sort -u > "$found"

# Advisory: make sure nothing was accidentally built with a newer minimum than 10.9.
if command -v vtool >/dev/null 2>&1; then
    for m in "${machos[@]}"; do
        minos="$(vtool -show-build "$m" 2>/dev/null | awk '/minos/{print $2; exit}')"
        if [[ -n "$minos" && "$minos" != "10.9" && "$minos" != "10.9.0" ]]; then
            echo "::warning:: $(basename "$m") has minos $minos (expected 10.9)"
        fi
    done
fi

found_syms="$(cut -f1 "$found" | sort -u)"
found_count="$(printf '%s\n' "$found_syms" | grep -c . || true)"

# ---------------------------------------------------------------------------
# 3. (Re)generate the baseline on request or when it does not exist yet.
# ---------------------------------------------------------------------------
if [[ "${UPDATE_BASELINE:-0}" == "1" || ! -f "$BASELINE" ]]; then
    {
        echo "# Accepted weak-imported system symbols for the macOS 10.9 build."
        echo "# Generated by scripts/check-mavericks-symbols.sh — review before committing."
        echo "# Each symbol here is currently present in a build that runs on 10.9, i.e."
        echo "# either available on 10.9 or guarded at runtime. CI fails on any symbol NOT"
        echo "# listed here. When a legitimately-new-but-safe symbol appears, add it below."
        printf '%s\n' "$found_syms" | grep -v '^[[:space:]]*$' || true
    } > "$BASELINE"

    if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
        echo "Baseline updated ($found_count symbols): $BASELINE"
    else
        echo "No baseline found — created one with $found_count symbols: $BASELINE"
        echo "Review it and commit it so future runs can detect new symbols."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Diff the current scan against the committed baseline.
# ---------------------------------------------------------------------------
baseline_syms="$(grep -v '^[[:space:]]*#' "$BASELINE" | grep -v '^[[:space:]]*$' | sort -u || true)"
new_syms="$(comm -23 <(printf '%s\n' "$found_syms" | grep -v '^[[:space:]]*$') \
                     <(printf '%s\n' "$baseline_syms"))"

echo "Scanned ${#machos[@]} Mach-O file(s); $found_count weak-imported system symbol(s), baseline has $(printf '%s\n' "$baseline_syms" | grep -c . || true)."

if [[ -z "$new_syms" ]]; then
    echo "OK: no weak-imported symbols outside the 10.9 baseline."
    exit 0
fi

echo
echo "FAIL: found weak-imported system symbols NOT in the 10.9 baseline."
echo "These may be unavailable on macOS 10.9 and crash at runtime. For each one,"
echo "either avoid the API / guard it behind a runtime availability check, or — if"
echo "it is genuinely available on (or backfilled for) 10.9 — add it to:"
echo "  $BASELINE"
echo
while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    echo "  * $sym"
    awk -F'\t' -v s="$sym" '$1==s {print "      from " $2 "  in " $3}' "$found" | sort -u
done <<< "$new_syms"

exit 1
