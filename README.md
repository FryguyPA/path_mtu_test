# MTU Path Test

A small tool that traces the path to one or more targets and probes each hop
with a **dual ICMP probe per packet size**:

- a **DF-set** probe to find the largest size that fits *without*
  fragmentation, and to capture the router IP + link MTU from any returned
  ICMP "Fragmentation Needed" message (i.e. *where* fragmentation would
  occur);
- a **DF-clear** probe to confirm the path actually delivers the packet when
  fragmentation is allowed.

Useful for spotting silent jumbo-frame breakage, identifying which hop
fragments traffic, and verifying that fragmented delivery still works
end-to-end.

Two implementations ship together — pick whichever fits the host:

- `mtu_path_test.py` — Python 3.9+, primary implementation.
- `mtu_path_test.sh` — pure bash. Same flags, same output, no Python
  dependency. Drop it on any macOS or Linux box and go.

## Requirements

- macOS or Linux (both implementations auto-detect and adapt to iputils on
  Linux).
- `traceroute` and `ping` on `PATH` (both ship with macOS; on minimal Ubuntu
  install with `apt install traceroute iputils-ping`).
- Python 3.9+ if you want the `.py` version; the `.sh` version has no
  language dependency beyond bash 3.2+.

No third-party packages.

## Quick start

```bash
# single target, defaults  (1300 → 9000, fine step 1 below 1500, then 500)
python3 mtu_path_test.py 8.8.8.8
./mtu_path_test.sh        8.8.8.8

# multiple targets on the command line
./mtu_path_test.sh 8.8.8.8 1.1.1.1 www.example.com

# list of targets from a file
./mtu_path_test.sh --file targets.txt

# mix CLI + file, change coarse step, custom save dir
./mtu_path_test.sh 192.0.2.10 --file sites.txt --step 250 --out-dir ~/mtu-runs
```

`targets.txt` is one host per line. Blank lines and `#` comments are ignored;
trailing inline comments are stripped (`1.1.1.1   # cloudflare`).

## Sweep schedule

By default the sweep is **fine-grained near the standard 1500-byte MTU and
coarse-grained above it**, because that's where breakage is most often
interesting:

```
1300, 1301, 1302, ... , 1499, 1500,           ← fine step (1 byte)
2000, 2500, 3000, ... , 8500, 9000            ← coarse step (500 bytes)
```

That's the default with `--start 1300 --fine-pivot 1500 --fine-step 1
--step 500 --end 9000` (≈ 216 sizes per hop).

You can flatten or sharpen as needed:

```bash
# Quick coarse scan, no fine zone
./mtu_path_test.sh --start 1500 --step 500 8.8.8.8

# Tight focus around 1500 only
./mtu_path_test.sh --start 1450 --end 1520 --fine-step 1 8.8.8.8

# Coarse fine zone (sweeps 1300, 1310, 1320, ..., 1500)
./mtu_path_test.sh --fine-step 10 8.8.8.8
```

## Options

Both implementations accept the same flags.

| Flag                  | Default | Description |
| --------------------- | ------- | ----------- |
| `targets` (positional)| —       | One or more destination IPs/hostnames. |
| `--file`, `-f`        | —       | Path to a target list file. |
| `--start`             | 1300    | Smallest packet size to test (total IP bytes). |
| `--end`               | 9000    | Largest packet size to test. |
| `--step`              | 500     | Coarse step (used above `--fine-pivot`). |
| `--fine-step`         | 1       | Fine step (used between `--start` and `--fine-pivot`). |
| `--fine-pivot`        | 1500    | Boundary between fine and coarse stepping. |
| `--max-hops`          | 30      | Maximum traceroute hops. |
| `--timeout-ms`        | 1500    | Per-probe wait time in milliseconds. *(auto-converted to seconds on Linux.)* |
| `--retries`           | 2       | Retries per size before counting it as a failure. |
| `--iface IFACE`       | —       | Bind ping/traceroute to a specific interface. *(Linux: `ping -I`, macOS: `ping -b`; `traceroute -i` on both.)* |
| `--no-color`          | off     | Disable ANSI colors (auto-disabled when piped). |
| `--no-save`           | save on | Disable per-target file output. |
| `--out-dir DIR`       | `.`     | Where to write saved logs. |
| `--out-ext EXT`       | `log`   | File extension for saved logs. |
| `--version`, `-V`     | —       | Print version and exit. |

`--start` / `--end` / `--fine-pivot` are **total IPv4 packet sizes**, not
`ping -s` payloads. The scripts subtract the 28-byte IPv4 + ICMP overhead
before invoking `ping`.

## Saved log files

By default both implementations write a per-target log to the current
directory:

```
8.8.8.8_20260430_143022.log
1.1.1.1_20260430_143022.log
```

Naming: `<sanitized-target>_<YYYYMMDD>_<HHMMSS>.<ext>`. Anything outside
`[A-Za-z0-9._-]` in the target becomes `_` (so `fe80::1%eth0` →
`fe80__1_eth0`). One run shares one timestamp across all its targets, so
sibling files sort together. Files are ANSI-color stripped on the way in,
so they're grep- and email-friendly.

The live `\r`-overwriting progress line stays on the terminal only — it's
on stderr and never lands in the log.

Disable with `--no-save`. Change location/extension with `--out-dir DIR`
and `--out-ext EXT`. After all targets are done, both scripts print a
`Saved logs:` recap listing every file written.

## Live progress

While a hop is being swept, both implementations print a single-line
status on stderr that updates in place:

```
  [ 2] 10.0.0.1                                 probing [37/216] size=1336  DF=OK  non-DF=OK
```

You can see exactly which size and which probe is currently in flight, so
the script doesn't appear to "sit there silly" on a hop that's slow to
answer. Auto-disabled when stderr isn't a TTY (i.e. when redirected),
so log files stay clean.

## What the output looks like

For each target the tool prints a tree-style path. Each hop gets two bars
(no-frag ceiling and fragmentation-allowed ceiling) plus a fragmentation
point line when one was identified.

```
══════════════════════════════════════════════════════════════════════════════
  MTU Path Test  →  target: 8.8.8.8
  Tested range: 1300 → 9000 bytes  (dual probe: DF-set + DF-clear per size; fine step under 1500, coarse above)
══════════════════════════════════════════════════════════════════════════════
  [ 1] ●  192.168.1.1  (router.local)
        │ no-frag : ████████████████████████████  max=9000
        │ w/ frag : ████████████████████████████  max=9000
        │ frag pt : none in tested range
        ▼
  [ 2] ●  10.0.0.1
        │ no-frag : ████░░░░░░░░░░░░░░░░░░░░░░░░  max=2000
        │ w/ frag : ████████████████████████████  max=9000
        │ frag pt : 2500 → via 10.0.0.5 (link MTU 1500)
        ▼
  [ 3] ◆  8.8.8.8
        │ no-frag : ████░░░░░░░░░░░░░░░░░░░░░░░░  max=2000
        │ w/ frag : ████████████████████████████  max=9000
        │ frag pt : 2500 → via 10.0.0.5 (link MTU 1500)
══════════════════════════════════════════════════════════════════════════════
  No-frag Path MTU:    2000 bytes
  Frag-OK Path MTU:    9000 bytes
  First fragmentation: hop 2 (10.0.0.1) starts fragmenting at 2500 — 10.0.0.5 (link MTU 1500)
══════════════════════════════════════════════════════════════════════════════
```

When more than one target is tested, a final summary table compares them.

## Notes & caveats

- Some routers rate-limit or drop ICMP entirely. Such hops appear as
  `*  no response` and are skipped — that's network behavior, not a script
  bug.
- A "Fragmentation Needed" ICMP error can be rate-limited or filtered. The
  tool will still detect *that* fragmentation is needed (DF probe fails,
  DF-clear probe succeeds) but the fragmenting router will show as
  `(router silent — ICMP rate-limited or filtered)`.
- The tool only reports what survives **to that hop**; it doesn't claim the
  hop's interface MTU. See `HOWITWORKS.md` for the full reasoning.
- IPv6 isn't supported in this version (the overhead math and `ping` flags
  would need to change).
- macOS `ping -W` takes milliseconds; iputils `ping -W` takes seconds.
  Both implementations read `uname -s` / `platform.system()` once and
  convert ms → seconds on Linux (rounded up, min 1), so `--timeout-ms`
  is always meaningful as milliseconds.
- macOS `ping -D` sets DF; iputils uses `ping -M do`. Both implementations
  pick the right form per platform.
- Both implementations also accept iputils' `1 received` and `bytes from`
  as success signals, in addition to BSD's `1 packets received` wording.
- Dual probes per size roughly double the run time vs. DF-only. Probing
  stops early at any hop where both DF and DF-clear fail at the same size
  (real reachability bottleneck), so most paths don't sweep the full range.

## Files

- `mtu_path_test.py` — Python 3.9+ implementation. Live progress, log-file
  output, Linux+macOS auto-detect.
- `mtu_path_test.sh` — pure bash equivalent. Same flags, same behavior, no
  Python dependency.
- `HOWITWORKS.md` — deeper explanation of the probing logic.
- `CHANGELOG.md` — change history.
