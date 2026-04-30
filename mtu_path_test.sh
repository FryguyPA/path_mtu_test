#!/usr/bin/env bash
# mtu_path_test.sh — dual-probe MTU path tester
#
# Per hop, per packet size, sends:
#   1. ping -D (DF set) — finds the no-frag ceiling and parses any returned
#      ICMP "Fragmentation Needed" message for the offending router IP + MTU
#   2. ping     (DF clear) — confirms the path actually delivers the size
#      with fragmentation allowed
#
# Targeted at macOS (uses macOS-style ping -W milliseconds). Works on Linux
# iputils too if you adjust --timeout-ms units.

set -u

# ---- defaults ----
START=1300
END=9000
STEP=500
FINE_STEP=1            # step size used between START and FINE_PIVOT
FINE_PIVOT=1500        # below this, use FINE_STEP; above this, use STEP
MAX_HOPS=30
TIMEOUT_MS=1500        # logical milliseconds; converted to seconds on Linux
RETRIES=2
USE_COLOR=1
FILE=""
TARGETS=()
ICMP_OVERHEAD=28
BAR_WIDTH=28
SAVE=1
OUT_DIR="."
OUT_EXT="log"
RUN_TS=""           # set at startup once per run
SAVED_FILES=()

usage() {
  cat <<'EOF'
Usage: mtu_path_test.sh [options] target [target ...]

Per-hop dual-probe (DF + non-DF) MTU path test.

Options:
  -f, --file FILE        File with one target per line (# comments allowed)
      --start N          Smallest tested size       (default 1300)
      --end N            Largest tested size        (default 9000)
      --step N           Coarse step (above 1500)   (default 500)
      --fine-step N      Fine step (start..1500)    (default 1)
      --fine-pivot N     Boundary between fine/coarse (default 1500)
      --max-hops N       Traceroute hop cap         (default 30)
      --timeout-ms N     Per-probe wait ms (auto-converted on Linux) (default 1500)
      --retries N        Retries per probe          (default 2)
      --no-color         Disable ANSI colors
      --no-save          Don't save per-target output to a file
      --out-dir DIR      Directory for saved logs   (default: cwd)
      --out-ext EXT      Extension for saved logs   (default: log)
  -h, --help             Show this help

By default each target's output is saved to a file named:
  <DST>_<YYYYMMDD>_<HHMMSS>.<ext>      (ANSI colors stripped)

Sweep schedule: <start>..<fine-pivot> stepping by <fine-step>, then up to
<end> stepping by <step>. With defaults that is 1300, 1301, ..., 1500,
2000, 2500, ..., 9000.

Sizes are total IPv4 packet bytes (script subtracts 28 before ping -s).
EOF
}

# ---- argument parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --start)      START="$2"; shift 2 ;;
    --end)        END="$2"; shift 2 ;;
    --step)       STEP="$2"; shift 2 ;;
    --fine-step)  FINE_STEP="$2"; shift 2 ;;
    --fine-pivot) FINE_PIVOT="$2"; shift 2 ;;
    --max-hops)   MAX_HOPS="$2"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
    --retries)    RETRIES="$2"; shift 2 ;;
    --no-color)   USE_COLOR=0; shift ;;
    --no-save)    SAVE=0; shift ;;
    --out-dir)    OUT_DIR="$2"; shift 2 ;;
    --out-ext)    OUT_EXT="${2#.}"; shift 2 ;;   # accept ".log" or "log"
    -f|--file)    FILE="$2"; shift 2 ;;
    --)           shift; while [[ $# -gt 0 ]]; do TARGETS+=("$1"); shift; done ;;
    -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)            TARGETS+=("$1"); shift ;;
  esac
done

# Load --file targets
if [[ -n "$FILE" ]]; then
  if [[ ! -r "$FILE" ]]; then
    echo "Cannot read --file $FILE" >&2; exit 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    line="${line%% *}"
    TARGETS+=("$line")
  done < "$FILE"
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No targets given. Pass one or more positional targets, or --file." >&2
  exit 2
fi

# Validate sweep
if [[ $START -lt 64 || $END -gt 65500 || $START -ge $END \
      || $STEP -lt 1 || $FINE_STEP -lt 1 ]]; then
  echo "Invalid --start/--end/--step/--fine-step combination" >&2; exit 2
fi

command -v traceroute >/dev/null || { echo "traceroute not on PATH" >&2; exit 2; }
command -v ping       >/dev/null || { echo "ping not on PATH"       >&2; exit 2; }

# ping -W units differ:  macOS BSD = milliseconds, Linux iputils = seconds.
# Convert TIMEOUT_MS to whatever the local ping wants.
case "$(uname -s)" in
  Linux)  PING_W_DIVISOR=1000 ;;
  Darwin) PING_W_DIVISOR=1    ;;
  *)      PING_W_DIVISOR=1000 ;;   # default to seconds elsewhere
esac
PING_W=$(( (TIMEOUT_MS + PING_W_DIVISOR - 1) / PING_W_DIVISOR ))
[[ $PING_W -lt 1 ]] && PING_W=1

# Linux iputils uses -M do/dont/want for the DF bit instead of -D.
case "$(uname -s)" in
  Linux)  PING_DF_FLAGS=(-M do)  ;;
  *)      PING_DF_FLAGS=(-D)     ;;
esac

# Color
if [[ $USE_COLOR -eq 1 && -t 1 ]]; then
  RESET=$'\e[0m'; DIM=$'\e[2m'; BOLD=$'\e[1m'
  GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'
  CYAN=$'\e[36m'; GREY=$'\e[90m'
else
  RESET=""; DIM=""; BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; GREY=""
fi

# Progress only when stderr is an interactive tty
if [[ -t 2 ]]; then STDERR_IS_TTY=1; else STDERR_IS_TTY=0; fi

# Live progress helpers — overwrite the same line on stderr.
_progress() {
  [[ $STDERR_IS_TTY -eq 1 ]] || return 0
  printf '\r%s probing %s\e[K' "$1" "$2" >&2
}
_progress_clear() {
  [[ $STDERR_IS_TTY -eq 1 ]] || return 0
  printf '\r\e[K' >&2
}

# Safe filename component for an arbitrary target string.
sanitize_target() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

# Strip ANSI CSI sequences (used when writing to log files).
strip_ansi() {
  # \e[ ... letter   covers SGR (color), cursor, erase-in-line, etc.
  sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

# ---- helpers ----

# rep CHAR N — emit CHAR repeated N times
rep() {
  local ch="$1" n="$2" i s=""
  for ((i=0; i<n; i++)); do s+="$ch"; done
  printf '%s' "$s"
}

# make_bar VALUE LO HI [WIDTH]
make_bar() {
  local val="$1" lo="$2" hi="$3" w="${4:-$BAR_WIDTH}"
  local fill=0
  if [[ $val -gt 0 && $hi -gt $lo ]]; then
    fill=$(awk -v v="$val" -v l="$lo" -v h="$hi" -v w="$w" \
      'BEGIN{ p=(v-l)/(h-l); if (p<0) p=0; if (p>1) p=1; printf "%d", p*w + 0.5 }')
  fi
  [[ $fill -gt $w ]] && fill=$w
  local empty=$((w - fill))
  printf '%s%s' "$(rep '█' "$fill")" "$(rep '░' "$empty")"
}

# Run traceroute, emit "<num>|<ip>|<hostname>" per line; ip="*" for unreachable
run_traceroute() {
  local target="$1"
  traceroute -w 2 -q 1 -m "$MAX_HOPS" "$target" 2>/dev/null | awk '
    /^traceroute/ { next }
    {
      n = $1 + 0
      if (n <= 0) next
      line = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
      if (line ~ /^\*/) { print n "|*|"; next }
      ip = ""; host = ""
      if (match(line, /\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\)/)) {
        ip = substr(line, RSTART+1, RLENGTH-2)
        h = substr(line, 1, RSTART-1)
        sub(/[[:space:]]+$/, "", h)
        if (h != "" && h != ip) host = h
      } else if (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        ip = substr(line, RSTART, RLENGTH)
      }
      if (ip != "") print n "|" ip "|" host
    }
  '
}

# ping_probe IP TOTAL_SIZE DF(0|1)
# Echoes:  OK  |  FRAG <router> <mtu>  |  FAIL <reason>
ping_probe() {
  local ip="$1" total="$2" df="$3"
  local payload=$((total - ICMP_OVERHEAD))
  if [[ $payload -lt 0 ]]; then echo "FAIL too-small"; return; fi
  local out rc
  if [[ "$df" == "1" ]]; then
    out=$(ping "${PING_DF_FLAGS[@]}" -c 1 -W "$PING_W" -s "$payload" "$ip" 2>&1); rc=$?
  else
    out=$(ping                       -c 1 -W "$PING_W" -s "$payload" "$ip" 2>&1); rc=$?
  fi
  # iputils prints "received" (singular check below covers both "1 received" and
  # macOS "1 packets received"); also accept "bytes from" as a success signal.
  if [[ $rc -eq 0 ]] && \
     { [[ "$out" == *"1 packets received"* ]] || \
       [[ "$out" == *"1 received"* ]]         || \
       [[ "$out" == *"bytes from"* ]]; }; then
    echo "OK"; return
  fi
  local fline
  fline=$(printf "%s\n" "$out" | grep -i "frag needed" | head -n1)
  if [[ -n "$fline" ]]; then
    local router mtu
    router=$(printf "%s\n" "$fline" | sed -nE 's/.*[Ff]rom[[:space:]]+([0-9.]+).*/\1/p' | head -n1 | tr -d ':')
    mtu=$(printf "%s\n" "$fline" | grep -oEi 'MTU[[:space:]=]*[0-9]+' | head -n1 | grep -oE '[0-9]+')
    : "${mtu:=0}"
    echo "FRAG $router $mtu"
    return
  fi
  if printf "%s\n" "$out" | grep -qi "message too long"; then
    echo "FAIL local-mtu"; return
  fi
  echo "FAIL no-reply"
}

# probe_with_retry IP TOTAL DF — don't retry definitive results (OK / FRAG)
probe_with_retry() {
  local ip="$1" total="$2" df="$3"
  local i result=""
  for ((i=0; i<=RETRIES; i++)); do
    result=$(ping_probe "$ip" "$total" "$df")
    case "$result" in
      OK*|FRAG*) echo "$result"; return ;;
    esac
  done
  echo "$result"
}

# probe_hop_dual IP [PREFIX] — echoes pipe-delimited:
#   mnf|fa|fr|fmtu|mwf|frf|dfb|nodfb|note
# When PREFIX is given and stderr is a tty, live progress is shown on stderr
# (overwriting the same line) of the form: "<PREFIX> probing size=N DF=X non-DF…"
probe_hop_dual() {
  local ip="$1"
  local prefix="${2:-}"
  local mnf=0 fa=0 fr="" fmtu=0 mwf=0 frf=0 dfb=0 nodfb=0 note=""
  local first=1
  local df_r nodf_r df_short nodf_short

  # Build the sweep list: fine step from START up to FINE_PIVOT, then coarse
  # step from there to END.
  local -a sizes=()
  local s=$START
  if [[ $s -lt $FINE_PIVOT && $s -le $END ]]; then
    while [[ $s -le $FINE_PIVOT && $s -le $END ]]; do
      sizes+=("$s"); s=$((s + FINE_STEP))
    done
    s=$((FINE_PIVOT + STEP))
  fi
  while [[ $s -le $END ]]; do
    sizes+=("$s"); s=$((s + STEP))
  done
  # Ensure END is always tested as the last sample
  local n_sizes=${#sizes[@]}
  if [[ $n_sizes -gt 0 ]]; then
    local last_idx=$((n_sizes - 1))
    [[ ${sizes[$last_idx]} -ne $END && $END -gt ${sizes[$last_idx]} ]] && sizes+=("$END")
  fi

  local total=${#sizes[@]} idx=0 size
  for size in "${sizes[@]}"; do
    idx=$((idx + 1))
    _progress "$prefix" "[$idx/$total] size=$size  DF…"
    df_r=$(probe_with_retry "$ip" "$size" 1)
    df_short="${df_r%% *}"
    _progress "$prefix" "[$idx/$total] size=$size  DF=$df_short  non-DF…"
    nodf_r=$(probe_with_retry "$ip" "$size" 0)
    nodf_short="${nodf_r%% *}"
    _progress "$prefix" "[$idx/$total] size=$size  DF=$df_short  non-DF=$nodf_short"

    case "$df_r" in
      OK*) mnf=$size ;;
      FRAG*)
        if [[ $fa -eq 0 ]]; then
          fa=$size
          fr=$(printf "%s" "$df_r" | awk '{print $2}')
          fmtu=$(printf "%s" "$df_r" | awk '{print $3}')
        fi
        ;;
      *) [[ $fa -eq 0 ]] && fa=$size ;;
    esac
    case "$nodf_r" in
      OK*) mwf=$size ;;
    esac

    if [[ $first -eq 1 ]]; then
      [[ "$df_r"   != OK* ]] && dfb=1
      [[ "$nodf_r" != OK* ]] && nodfb=1
      first=0
    fi

    if [[ "$df_r" != OK* && "$nodf_r" != OK* ]]; then
      frf=$size
      note="${nodf_r#FAIL }"
      note="${note#FRAG }"
      break
    fi
  done
  _progress_clear
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$mnf" "$fa" "$fr" "$fmtu" "$mwf" "$frf" "$dfb" "$nodfb" "$note"
}

# ---- rendering ----

render_target() {
  local target="$1" rfile="$2"
  local total
  total=$(wc -l <"$rfile" | tr -d ' ')
  local sep
  sep=$(rep '═' 78)
  echo
  echo "$sep"
  printf "  %sMTU Path Test%s  →  target: %s%s%s\n" "$BOLD" "$RESET" "$CYAN" "$target" "$RESET"
  printf "  Tested range: %s → %s bytes  (dual probe: DF-set + DF-clear per size)\n" "$START" "$END"
  echo "$sep"

  local i=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    i=$((i+1))
    local glyph="●"
    [[ $i -eq $total ]] && glyph="◆"
    local n ip host mnf fa fr fmtu mwf frf dfb nodfb note
    IFS='|' read -r n ip host mnf fa fr fmtu mwf frf dfb nodfb note <<< "$line"

    if [[ "$ip" == "*" ]]; then
      printf "  [%2d] %s%s  *  no response%s\n" "$n" "$GREY" "$glyph" "$RESET"
    else
      local label="$ip"
      [[ -n "$host" ]] && label="$ip  ${DIM}(${host})${RESET}"
      printf "  [%2d] %s%s%s  %s\n" "$n" "$BOLD" "$glyph" "$RESET" "$label"

      if [[ "$dfb" == "1" && "$nodfb" == "1" ]]; then
        printf "        %s│ no-frag : %s  FAIL at baseline %s%s\n" "$RED" "$(make_bar 0 "$START" "$END")" "$START" "$RESET"
        printf "        %s│ w/ frag : %s  FAIL at baseline %s%s\n" "$RED" "$(make_bar 0 "$START" "$END")" "$START" "$RESET"
        [[ -n "$note" ]] && printf "        %s│ note    : %s%s\n" "$DIM" "$note" "$RESET"
      else
        local nfc=$YELLOW wfc=$YELLOW
        [[ $mnf -ge $END ]] && nfc=$GREEN
        [[ $mnf -eq 0 ]]   && nfc=$RED
        [[ $mwf -ge $END ]] && wfc=$GREEN
        [[ $mwf -eq 0 ]]   && wfc=$RED
        local nfl="max=$mnf" wfl="max=$mwf"
        [[ $mnf -eq 0 ]] && nfl="none up to $START"
        [[ $mwf -eq 0 ]] && wfl="none up to $START"
        printf "        %s│ no-frag : %s  %s%s\n" "$nfc" "$(make_bar "$mnf" "$START" "$END")" "$nfl" "$RESET"
        printf "        %s│ w/ frag : %s  %s%s\n" "$wfc" "$(make_bar "$mwf" "$START" "$END")" "$wfl" "$RESET"
        if [[ $fa -gt 0 ]]; then
          if [[ -n "$fr" ]]; then
            printf "        %s│ frag pt : %s → via %s (link MTU %s)%s\n" "$YELLOW" "$fa" "$fr" "$fmtu" "$RESET"
          else
            printf "        %s│ frag pt : %s (router silent — ICMP rate-limited or filtered)%s\n" "$YELLOW" "$fa" "$RESET"
          fi
        else
          printf "        %s│ frag pt : none in tested range%s\n" "$GREEN" "$RESET"
        fi
        if [[ $frf -gt 0 ]]; then
          printf "        %s│ hard fail at %s (both DF and DF-clear)  %s%s\n" "$RED" "$frf" "$note" "$RESET"
        fi
      fi
    fi
    [[ $i -ne $total ]] && printf "        %s▼%s\n" "$DIM" "$RESET"
  done <"$rfile"
  echo "$sep"

  # per-target summary
  local pnf=0 pwf=0 first=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local n ip host mnf fa fr fmtu mwf frf dfb nodfb note
    IFS='|' read -r n ip host mnf fa fr fmtu mwf frf dfb nodfb note <<< "$line"
    [[ "$ip" == "*" ]] && continue
    if [[ $mnf -gt 0 ]]; then
      [[ $pnf -eq 0 || $mnf -lt $pnf ]] && pnf=$mnf
    fi
    if [[ $mwf -gt 0 ]]; then
      [[ $pwf -eq 0 || $mwf -lt $pwf ]] && pwf=$mwf
    fi
    if [[ -z "$first" && $fa -gt 0 ]]; then
      first="$n|$ip|$fa|$fr|$fmtu"
    fi
  done <"$rfile"

  printf "  %sNo-frag Path MTU:%s    %s bytes\n" "$BOLD" "$RESET" "$pnf"
  printf "  %sFrag-OK Path MTU:%s    %s bytes\n" "$BOLD" "$RESET" "$pwf"
  if [[ -n "$first" ]]; then
    local fn fi_ fa fr fmtu
    IFS='|' read -r fn fi_ fa fr fmtu <<< "$first"
    if [[ -n "$fr" ]]; then
      printf "  %sFirst fragmentation:%s hop %s (%s) starts fragmenting at %s — %s (link MTU %s)\n" \
        "$BOLD" "$RESET" "$fn" "$fi_" "$fa" "$fr" "$fmtu"
    else
      printf "  %sFirst fragmentation:%s hop %s (%s) starts fragmenting at %s — router silent\n" \
        "$BOLD" "$RESET" "$fn" "$fi_" "$fa"
    fi
  else
    printf "  %sNo fragmentation observed within the tested range.%s\n" "$GREEN" "$RESET"
  fi
  echo "$sep"
  echo
}

render_multi_summary() {
  local map_file="$1"
  local n
  n=$(wc -l <"$map_file" | tr -d ' ')
  [[ $n -le 1 ]] && return
  local sep
  sep=$(rep '═' 86)
  echo "$sep"
  printf "  %sMulti-Target Summary%s\n" "$BOLD" "$RESET"
  echo "$sep"
  printf "  %-28s %9s %9s  %s\n" "Target" "No-frag" "W/frag" "Fragmentation point"
  printf "  %-28s %9s %9s  %s\n" "$(rep '-' 28)" "$(rep '-' 9)" "$(rep '-' 9)" "$(rep '-' 36)"

  while IFS=$'\t' read -r target rfile; do
    local pnf=0 pwf=0 first=""
    if [[ -s "$rfile" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local hn hip hhost mnf fa fr fmtu mwf frf dfb nodfb note
        IFS='|' read -r hn hip hhost mnf fa fr fmtu mwf frf dfb nodfb note <<< "$line"
        [[ "$hip" == "*" ]] && continue
        if [[ $mnf -gt 0 ]]; then
          [[ $pnf -eq 0 || $mnf -lt $pnf ]] && pnf=$mnf
        fi
        if [[ $mwf -gt 0 ]]; then
          [[ $pwf -eq 0 || $mwf -lt $pwf ]] && pwf=$mwf
        fi
        if [[ -z "$first" && $fa -gt 0 ]]; then
          if [[ -n "$fr" ]]; then
            first="hop $hn @ $fa ($fr MTU $fmtu)"
          else
            first="hop $hn @ $fa (silent)"
          fi
        fi
      done <"$rfile"
    fi
    local note_color="$GREEN" note_text="no frag in range"
    if [[ -n "$first" ]]; then
      note_color="$YELLOW"; note_text="$first"
    fi
    printf "  %-28s %9s %9s  %s%s%s\n" "$target" "$pnf" "$pwf" "$note_color" "$note_text" "$RESET"
  done <"$map_file"
  echo "$sep"
  echo
}

run_one_target() {
  local t="$1" rfile="$2"

  echo
  printf "%s%s%s\n" "$BOLD" "$(rep '━' 72)" "$RESET"
  printf "%sTarget:%s %s%s%s\n" "$BOLD" "$RESET" "$CYAN" "$t" "$RESET"
  printf "%s%s%s\n" "$BOLD" "$(rep '━' 72)" "$RESET"

  printf "%sRunning:%s traceroute -w 2 -q 1 -m %s %s\n" "$CYAN" "$RESET" "$MAX_HOPS" "$t"
  local hops
  hops=$(run_traceroute "$t")
  if [[ -z "$hops" ]]; then
    echo "${RED}No hops discovered for ${t}${RESET}"
    : > "$rfile"
    return
  fi

  local hops_count
  hops_count=$(printf "%s\n" "$hops" | grep -c '^')
  printf "Discovered %s hop(s). Probing MTU per hop (%s→%s, fine_step=%s up to %s, then step=%s)...\n\n" \
    "$hops_count" "$START" "$END" "$FINE_STEP" "$FINE_PIVOT" "$STEP"

  : > "$rfile"
  local n ip host hop_prefix rec mnf fa fr fmtu mwf frf dfb nodfb note
  while IFS='|' read -r n ip host; do
    [[ -z "$n" ]] && continue
    hop_prefix=$(printf "  [%2d] %-39s" "$n" "$ip")
    if [[ "$ip" == "*" ]]; then
      printf "%s %sskip (no response)%s\n" "$hop_prefix" "$GREY" "$RESET"
      printf '%s|%s|%s|0|0|||0|0|0|0|\n' "$n" "$ip" "$host" >> "$rfile"
      continue
    fi
    rec=$(probe_hop_dual "$ip" "$hop_prefix")
    IFS='|' read -r mnf fa fr fmtu mwf frf dfb nodfb note <<< "$rec"
    if [[ "$dfb" == "1" && "$nodfb" == "1" ]]; then
      printf "%s %sboth probes fail at baseline (%s)%s\n" "$hop_prefix" "$RED" "$note" "$RESET"
    elif [[ -n "$fr" ]]; then
      printf "%s %sno-frag=%s, frag@%s via %s (MTU %s), w/frag=%s%s\n" "$hop_prefix" "$YELLOW" "$mnf" "$fa" "$fr" "$fmtu" "$mwf" "$RESET"
    elif [[ $fa -gt 0 ]]; then
      printf "%s %sno-frag=%s, frag@%s (silent), w/frag=%s%s\n" "$hop_prefix" "$YELLOW" "$mnf" "$fa" "$mwf" "$RESET"
    else
      printf "%s %sno-frag=%s, w/frag=%s ✓%s\n" "$hop_prefix" "$GREEN" "$mnf" "$mwf" "$RESET"
    fi
    printf '%s|%s|%s|%s\n' "$n" "$ip" "$host" "$rec" >> "$rfile"
  done <<< "$hops"

  render_target "$t" "$rfile"
}

# ---- main ----
TMPDIR_RUN=$(mktemp -d 2>/dev/null || mktemp -d -t mtu_path)
trap 'rm -rf "$TMPDIR_RUN"' EXIT INT TERM
MAP_FILE="$TMPDIR_RUN/targets.tsv"
: > "$MAP_FILE"

# Run-wide timestamp so all targets in one invocation share it.
RUN_TS=$(date +%Y%m%d_%H%M%S)

# Make the output dir if needed
if [[ $SAVE -eq 1 ]]; then
  if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
    echo "Cannot create --out-dir '$OUT_DIR'; disabling save." >&2
    SAVE=0
  fi
fi

# de-dup targets (preserve order)
declare -a SEEN=()
DEDUP_TARGETS=()
for t in "${TARGETS[@]}"; do
  dup=0
  for s in "${SEEN[@]:-}"; do
    [[ "$s" == "$t" ]] && dup=1 && break
  done
  [[ $dup -eq 1 ]] && continue
  SEEN+=("$t"); DEDUP_TARGETS+=("$t")
done

idx=0
for t in "${DEDUP_TARGETS[@]}"; do
  idx=$((idx+1))
  rfile="$TMPDIR_RUN/r_$idx"

  if [[ $SAVE -eq 1 ]]; then
    safe=$(sanitize_target "$t")
    out_file="${OUT_DIR%/}/${safe}_${RUN_TS}.${OUT_EXT}"
    printf "%s↳ saving to:%s %s\n" "$DIM" "$RESET" "$out_file"
    # Tee colored output to terminal; write ANSI-stripped copy to file.
    run_one_target "$t" "$rfile" | tee >(strip_ansi > "$out_file")
    SAVED_FILES+=("$out_file")
  else
    run_one_target "$t" "$rfile"
  fi

  printf '%s\t%s\n' "$t" "$rfile" >> "$MAP_FILE"
done

render_multi_summary "$MAP_FILE"

# Recap saved files
if [[ ${#SAVED_FILES[@]} -gt 0 ]]; then
  printf "%sSaved logs:%s\n" "$BOLD" "$RESET"
  for f in "${SAVED_FILES[@]}"; do printf "  %s\n" "$f"; done
  echo
fi
