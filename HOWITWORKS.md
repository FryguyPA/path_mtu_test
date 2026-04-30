# How It Works

This document explains what the tool does on the wire and how to read its
results accurately. Both `mtu_path_test.py` and `mtu_path_test.sh`
implement the same probing model — anywhere this doc says "the tool", both
apply unless called out.

## Overview

For each target, the tool runs two phases:

1. **Discovery** — a single `traceroute` builds the list of hops between you
   and the target.
2. **Probe** — for every responsive hop, the tool sweeps packet sizes and
   sends **two ICMP echo requests per size**: one with the Don't-Fragment
   bit set, one without. The pair tells us, at every size, whether the
   path needs fragmentation, where it would happen, and whether
   fragmentation actually delivers the packet end-to-end.

The output is rendered as a vertical path diagram with two bars per hop and
a fragmentation-point line.

## Phase 1: Traceroute

```
traceroute -w 2 -q 1 -m <max-hops> <target>
```

- `-w 2` — wait 2 seconds for each probe.
- `-q 1` — one probe per TTL (we don't need three; we're not measuring
  jitter).
- `-m` — caps the hop count.

Output is parsed line by line. Two formats are handled:

- `hostname (1.2.3.4)  ...` — both hostname and IP captured.
- `1.2.3.4  ...` — IP only.

A hop that responds with only `* * *` is recorded as **unreachable** and
skipped during probing. This usually means an intermediate device drops or
rate-limits ICMP — common in carrier networks — and is not in itself a
problem.

## Phase 2: Dual MTU probing

### Building the sweep list

The sweep is **fine-grained near the standard 1500-byte MTU and
coarse-grained above it**. With the defaults
(`--start 1300 --fine-pivot 1500 --fine-step 1 --step 500 --end 9000`):

```
fine zone:    1300, 1301, 1302, ... , 1499, 1500     (step=1)
coarse zone:                  2000, 2500, ... , 9000 (step=500)
```

Why the asymmetry? Most real-world breakage clusters around the Ethernet
1500 boundary (PPPoE −8 here, GRE −24 there, IPSec −anywhere from 50 to
130). One-byte resolution in that window pinpoints the exact link MTU. Up
in jumbo-frame territory you usually only care *whether* a path supports
the size at all, so 500-byte steps are plenty.

If you want a flat sweep, set `--start 1500` (skips the fine zone) or
`--fine-step` to whatever resolution suits.

### The two probes per size

For every size in the list the tool issues two `ping` invocations:

```
ping <DF-flag>  -c 1 -W <wait> -s <payload> <hop-ip>   # DF set
ping            -c 1 -W <wait> -s <payload> <hop-ip>   # DF clear
```

- The DF-set probe sets the Don't Fragment bit. If any link on the path
  has a smaller MTU, the packet is dropped and the offending router emits
  an ICMP "Fragmentation Needed" (Type 3 / Code 4) message back to us.
- The DF-clear probe lets routers fragment freely. If the destination is
  reachable, you get an echo reply. This confirms that fragmented delivery
  actually works for that size.
- `-c 1` sends exactly one packet per probe.
- `-s <payload>` sets the **ICMP data payload size**, not the total IP
  packet size.

### Platform shims

The Linux/macOS implementations check the OS once at startup (bash:
`uname -s`; Python: `platform.system()`) and adapt their `ping` calls.
The PowerShell implementation runs only on Windows and uses the very
different `ping.exe` / `tracert.exe` flag set:

| Concern | macOS BSD ping | Linux iputils ping | Windows ping.exe |
| --- | --- | --- | --- |
| DF bit flag | `-D` | `-M do` | `-f` |
| Packet size flag | `-s <payload>` | `-s <payload>` | `-l <payload>` |
| Count flag | `-c 1` | `-c 1` | `-n 1` |
| Wait flag / units | `-W <ms>` | `-W <sec>` | `-w <ms>` |
| Source-address bind | `-S <addr>` | `-I <addr-or-iface>` | `-S <addr>` |
| Bind interface (alias) | `-b <iface>` (boundif) | `-I <iface>` | (resolve to addr, then `-S`) |
| traceroute bind | `-i <iface>` | `-i <iface>` | `-S <addr>` (`tracert.exe`) |
| traceroute hop cap | `-m N` | `-m N` | `-h N` |

`--timeout-ms` is always specified in milliseconds at the user level; the
scripts divide by 1000 (rounded up, min 1) before passing it to iputils.
So `--timeout-ms 1500` always means "1.5 seconds" regardless of platform.

`--iface` is plumbed through both `ping` and `traceroute`; pick the right
one for multi-homed hosts (laptop with WiFi+Ethernet, server with
management+data NICs). Without it the kernel routes per its routing
table, which may not be the path you actually want to test.

**Windows note:** `ping.exe` doesn't have a "bind to interface" flag, only
`-S <source-addr>`. The PowerShell script accepts either an IPv4 address
or a NIC alias (e.g. `"Ethernet"`, `"Wi-Fi"`) for `-Iface` and resolves
the alias to its primary IPv4 address via `Get-NetIPAddress` before
passing it to `ping -S`. The same source address is passed to
`tracert -S` so both phases use the same egress.

**Windows note (2):** Windows `ping.exe` does not embed the next-hop link
MTU in its "Packet needs to be fragmented but DF set" message the way
iputils and BSD ping do — newer versions name the offending router (e.g.
`Reply from 10.0.0.5: Packet needs to be fragmented but DF set.`) but
the link MTU is usually absent. The PowerShell script reports
`(link MTU N)` only when present, otherwise just the router IP.

**Windows note (3): file encoding.** `mtu_path_test.ps1` ships with a
UTF-8 BOM. This is **required** for Windows PowerShell 5.1, which reads
BOM-less script files as Windows-1252 by default and chokes on the
multi-byte Unicode characters used in the rendered bars (`█`, `░`,
`═`, `│`, `▼`). PowerShell 7+ reads UTF-8 by default and works either
way. Don't strip the BOM if you fork the script — and don't edit it in
old Notepad which silently drops it. Modern VS Code, PowerShell ISE,
and Notepad++ all preserve it correctly.

**Windows note (4): automatic-variable name collisions.** PowerShell
reserves a set of read-only globals (`$Host`, `$Args`, `$Input`,
`$Error`, `$Matches`, `$_`, `$True`, `$False`, `$Null`, `$PID`,
`$LASTEXITCODE`, `$Home`, `$PSHome`). Assigning to any of them at
function scope throws `Cannot overwrite variable X because it is
read-only or constant.` at runtime — the parser doesn't catch it. The
script avoids these (uses `$pingArgs`, `$trArgs`, `$hostName`, etc.).
If you extend the script, run `Invoke-ScriptAnalyzer mtu_path_test.ps1`
to surface any new collisions before they bite.

Success detection accepts any of `1 packets received` (BSD), `1 received`
(iputils), or `bytes from` as a positive signal — the wording differs
between the two stacks.

### The size math

`ping -s N` produces a packet of:

```
N (data)  +  8 (ICMP header)  +  20 (IPv4 header)  =  N + 28 bytes on the wire
```

The user-facing `--start` / `--end` / `--fine-pivot` values are **total
IPv4 packet bytes**, so the script subtracts 28 before calling `ping`:

```
payload = total_size - 28
```

That way `--end 9000` actually tests 9000-byte IP packets — i.e. real jumbo
frame territory — without you having to do the arithmetic.

### Capturing the fragmentation point

When the DF probe fails because a link is too small, the offending router
sends an ICMP error containing **its own address** and **the next-hop MTU**.
On macOS `ping` surfaces it as:

```
36 bytes from 10.0.0.5: frag needed and DF set (MTU 1500)
```

Linux iputils uses:

```
From 10.0.0.5 icmp_seq=1 Frag needed and DF set (mtu = 1500)
```

The script parses both forms with a single regex and records:

- `frag_router` — the router IP that returned the error.
- `frag_router_mtu` — the link MTU it advertised.

That router is the fragmentation point — i.e. where the silent
fragmentation *would* have happened if DF were off. We snapshot the first
such occurrence per hop sweep.

### Retries

ICMP rate-limiting causes random single-packet drops on otherwise-healthy
paths. To filter that noise:

- Each probe is retried up to `--retries` times (default 2 retries, i.e.
  up to 3 attempts).
- A **definitive** result short-circuits retries: a successful echo, or a
  parsed "Frag Needed" message. We never retry to overturn one of those.
- A "no reply" outcome is retried.

### When the sweep stops

The sweep stops at any size where **both** probes fail. That's a real
reachability or filtering boundary, not just an MTU constraint, and probing
larger sizes won't tell us anything new. With the default sweep this is
usually the saving grace — most hops fail-out long before churning through
all 216 sizes.

### Per-hop result

Each hop ends up with:

- `max_no_frag` — largest size whose DF probe succeeded (no fragmentation
  needed up to here).
- `frag_at` — first size whose DF probe failed (fragmentation begins).
- `frag_router`, `frag_router_mtu` — who fragments and what link MTU they
  reported, if captured.
- `max_with_frag` — largest size whose DF-clear probe succeeded
  (fragmentation actually works to here).
- `first_real_fail` — first size where both DF and DF-clear failed.
- `df_baseline_failed` / `nodf_baseline_failed` — even the smallest tested
  size failed.

## How to read the diagram

```
[ 2] ●  10.0.0.1
      │ no-frag : ████░░░░░░░░░░░░░░░░░░░░░░░░  max=2000
      │ w/ frag : ████████████████████████████  max=9000
      │ frag pt : 2500 → via 10.0.0.5 (link MTU 1500)
```

- **no-frag bar** — how far up the tested range packets went *without
  needing* fragmentation.
- **w/ frag bar** — how far up the range fragmented packets still got
  through.
- **frag pt** — first size where DF failed, and (when captured) the router
  that announced it can't carry that size on its outgoing link.
- A `(router silent — ICMP rate-limited or filtered)` note means we
  detected fragmentation is required (DF fails, non-DF works) but no router
  told us who. That's an ICMP-policy artifact, not a script bug.
- `frag pt : none in tested range` (green) means no DF probe ever failed —
  the real ceiling could be higher; raise `--end` if you want to know.
- A red `hard fail at N` line means both DF and DF-clear failed at size N —
  reachability or filtering issue, not an MTU one.

The summary at the bottom of each target shows:

- **No-frag Path MTU** — minimum `max_no_frag` across probed hops. Largest
  size that traversed the whole path without needing fragmentation.
- **Frag-OK Path MTU** — minimum `max_with_frag` across probed hops.
  Largest size that still got through end-to-end *with* fragmentation
  allowed.
- **First fragmentation** — earliest hop in the path where fragmentation
  begins, with the router IP and link MTU when reported.

## Live progress

While probing a hop, both implementations write a single-line status to
**stderr** that updates in place via `\r` and `\e[K`:

```
  [ 2] 10.0.0.1                                 probing [37/216] size=1336  DF=OK  non-DF=OK
```

It's gated on the stderr TTY check (`[[ -t 2 ]]` in bash;
`sys.stderr.isatty()` in Python), so when stderr is redirected (CI, `tee`,
log capture) the progress is silenced and the scripts emit clean
line-oriented output suitable for scripting. There's no flag for it; it
just turns on whenever you're at a real terminal.

## Saved log files

By default both implementations write a per-target log:

```
<sanitized-target>_<YYYYMMDD>_<HHMMSS>.<ext>
```

Mechanism differs by language but the result is identical:

- **bash** wraps each target's body in a function whose stdout is piped
  through `tee >(strip_ansi > "$file")`. ANSI sequences are stripped via
  `sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'`.
- **Python** swaps `sys.stdout` for a small `_Tee` object that fans every
  write to (a) the original stdout and (b) an `_AnsiStrippingFile` wrapper
  around the log handle. The wrapper applies the same ANSI-stripping regex
  before the bytes hit disk.

Live progress goes to stderr in both cases, never piped through the file
sink, so it doesn't clutter the log.

All targets in one invocation share a single timestamp captured at start
(`RUN_TS` in bash; a `datetime.now()` snapshot in Python), so sibling
files sort together. Disable with `--no-save`; relocate with `--out-dir`;
change the extension with `--out-ext`. After all targets finish, both
scripts print a `Saved logs:` recap listing the files written.

## Testing & CI

The Python implementation has a pytest suite under `tests/` covering all
the pure helpers — there's no network mocking, just direct unit tests on:

- `_build_sizes()` — sweep-list construction across default, no-fine,
  only-fine, custom-step, and off-step-end cases.
- `_FRAG_RE` — both BSD and iputils "Fragmentation Needed" wording, plus
  negative cases (normal echo reply, timeout output).
- `bar()`, `_sanitize_target()`, `_ping_w()`, `_AnsiStrippingFile`,
  `_Tee`, and `load_targets_from_file()`.

Run locally:

```bash
pip install pytest
pytest          # 36 cases, ~50 ms
```

GitHub Actions CI (`.github/workflows/ci.yml`) runs:

- The pytest suite on a Python `{3.9, 3.11, 3.12}` × `{ubuntu-latest,
  macos-latest}` matrix.
- `bash -n`, `--help` and `--version` smoke checks, plus ShellCheck
  (warning level) on the bash script.

The bash script doesn't have a parallel unit-test framework; its
behavioral parity with Python is verified by hand against the same set
of cases (the size-builder smoke test in particular has produced
identical outputs on both sides).

## What this tool does *not* do

- **It does not report a hop's interface MTU directly** — except where the
  ICMP error explicitly carried it (then `link MTU N` reflects the
  advertised value).
- **It does not see fragments on the wire.** It infers fragmentation from
  the DF/non-DF outcome pair, not from observing fragmented IP packets.
  For raw fragment counting you'd need `tcpdump` or a raw socket; that's
  outside the scope of this script.
- **It does not differentiate ICMP "Frag Needed" filtering from absence of
  fragmentation.** A DF failure with no parsed router IP could be either
  silent drop or filtered ICMP error. The DF-clear success tells you the
  path still works; the silent router just isn't advertising itself.
- **It does not test asymmetric paths.** ICMP replies come back over
  whatever return path the network chooses; if that direction has a
  smaller MTU you'll see DF failures even though the forward path would
  have allowed the size.
- **It does not test IPv6.** The overhead math and `ping` flags differ;
  this version assumes IPv4.

## Tuning

- **Fine step** (`--fine-step`): smaller = more accurate fragmentation
  point, more probes. Default 1 byte gives exact MTU resolution between
  `--start` and `--fine-pivot`.
- **Coarse step** (`--step`): controls resolution above `--fine-pivot`.
  Drop to 100 or 50 to pin breakage in the jumbo region.
- **Pivot** (`--fine-pivot`): move it up if you also want fine resolution
  through the next-common boundary (e.g. 4470 for legacy POS).
- **Timeout** (`--timeout-ms`): increase for high-latency WAN paths
  (satellite, transoceanic). Default 1500 ms is fine for most enterprise
  paths.
- **Retries** (`--retries`): raise on lossy links to filter rate-limit
  noise; lower to make sweeps faster on a clean LAN.
- **Range** (`--start` / `--end`): set `--start` low (e.g. 1280) when you
  suspect a sub-1500 path; raise `--end` past 9000 only if you have real
  9216-MTU jumbo paths to test.
