# Changelog

All notable changes to this project. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); dates are
YYYY-MM-DD.

## [0.6.0] — 2026-04-30

### Added
- **`--iface IFACE` flag** in both implementations. Binds `ping` and
  `traceroute` to a specific interface — essential on multi-homed hosts
  (laptop with WiFi+Ethernet, server with management+data NICs).
  Platform-aware: Linux iputils ping uses `-I IFACE`, macOS BSD ping uses
  `-b IFACE` (boundif). `traceroute -i IFACE` on both.
- **Test suite** under `tests/` (pytest). 36 tests covering:
  - `_build_sizes()` sweep-list construction (9 cases including default,
    no fine zone, only fine zone, custom fine step, off-step end).
  - `_FRAG_RE` parsing for both BSD and iputils ping wording, plus
    negative cases (normal reply, timeout).
  - `bar()`, `_sanitize_target()`, `_ping_w()`, `_AnsiStrippingFile`,
    `_Tee`, and `load_targets_from_file()`.
- **`pyproject.toml`** with pytest configuration (testpaths, pythonpath).
- **GitHub Actions CI** (`.github/workflows/ci.yml`):
  - Python matrix: 3.9 / 3.11 / 3.12 on ubuntu-latest + macos-latest.
    Runs `py_compile` and the full pytest suite on every push and PR.
  - Bash job on ubuntu-latest: `bash -n`, `--help` and `--version` smoke
    checks, plus ShellCheck (warning-level).

### Fixed
- **`_FRAG_RE` over-captured trailing colon** on macOS ping output. The
  regex previously returned `"10.0.0.5:"` instead of `"10.0.0.5"` for the
  fragmenting router IP because `[0-9a-fA-F:.]+` was greedy. Made the
  capture non-greedy and require an explicit `:?\s` boundary. Caught by
  the new `tests/test_parsing.py::test_parse_macos_frag_needed`.

## [0.5.0] — 2026-04-30

### Added
- **Python parity with bash.** The Python implementation now matches the
  bash version end-to-end:
  - Variable-step sweep with new `--fine-step` (default 1) and
    `--fine-pivot` (default 1500) flags. Default `--start` lowered from
    1500 to 1300.
  - Per-target log files via `--no-save` / `--out-dir` / `--out-ext`,
    using the same `<sanitized>_<YYYYMMDD>_<HHMMSS>.<ext>` naming.
    Implemented via a stdout `_Tee` that fans writes to the terminal and
    an `_AnsiStrippingFile` wrapper around the log handle, so live
    terminal output keeps its color while the file stays plain text.
  - Live `\r`-overwriting progress line on stderr while a hop is being
    swept, including `[idx/total]` counter.
  - Linux iputils platform shim: DF flag becomes `-M do`, `--timeout-ms`
    is divided by 1000 (rounded up, min 1) before being passed to
    `ping -W`. `platform.system()` is checked once at import.
  - Success detection accepts iputils' `1 received` and `bytes from` in
    addition to BSD's `1 packets received`.

## [0.4.0] — 2026-04-29

### Added
- **Per-target log files** (bash). Each target now writes
  `<sanitized-target>_<YYYYMMDD>_<HHMMSS>.<ext>` to the current directory
  by default. ANSI color sequences are stripped on the way to disk so logs
  are grep- and email-friendly. Live progress (stderr) is never piped into
  the log.
- **New flags**: `--no-save`, `--out-dir DIR`, `--out-ext EXT` (bash).
- **Final "Saved logs:" recap** prints all written paths after the
  multi-target summary.

### Changed
- Per-target body refactored into `run_one_target()` so it can be cleanly
  routed through `tee` for the save-to-file feature.

## [0.3.0] — 2026-04-29

### Added
- **Variable-step sweep**: fine resolution near 1500 (default 1-byte step)
  and coarse resolution above (default 500-byte step). New flags
  `--fine-step` and `--fine-pivot`. Default `--start` lowered from 1500
  to **1300** so the fine zone is included automatically.
- **Live progress line** (bash). While a hop is being swept the script
  writes `\r`-overwritten status on stderr in the form
  `probing [<idx>/<total>] size=<N>  DF=<X>  non-DF=<Y>`. Auto-disabled
  when stderr is not a TTY, so log files stay clean.

### Changed
- Sweep iterator in `probe_hop_dual()` rebuilt around a precomputed
  `sizes` array instead of an ad-hoc `while` loop, to support the
  fine/coarse split and the progress counter.

### Fixed
- **Linux iputils compatibility** in the bash script:
  - `ping -W` is now divided by 1000 on Linux (iputils interprets it as
    seconds; macOS BSD ping interprets it as milliseconds). Previously a
    default `--timeout-ms 1500` made each probe wait 1500 *seconds* on
    Ubuntu, hanging the script.
  - Don't-Fragment flag uses `-M do` on Linux and `-D` on macOS,
    auto-selected from `uname -s`.
  - Success detection accepts iputils' `1 received` and the universal
    `bytes from`, in addition to BSD's `1 packets received`.

## [0.2.0] — 2026-04-29

### Added
- **Bash port** (`mtu_path_test.sh`). Functionally equivalent to the
  Python script; same flags, same wire behavior, same output. Targeted
  initially at macOS — Linux fixes landed in 0.3.0.

### Documentation
- `HOWITWORKS.md` deeper explanation of probe semantics, ICMP error
  parsing, retry policy, and result interpretation.

## [0.1.0] — 2026-04-29

### Added
- Initial Python implementation (`mtu_path_test.py`).
- Traceroute discovery + per-hop MTU sweep with DF-set probes.
- **Dual probe per size** — DF-set probe identifies the no-frag ceiling
  and parses any returned ICMP "Fragmentation Needed" message for the
  offending router IP and link MTU; DF-clear probe confirms fragmented
  delivery actually works. Sweep stops at any size where both probes
  fail.
- Capture of fragmentation router IP / link MTU from ICMP errors
  (matches both macOS BSD and Linux iputils ping wording).
- Multi-target support: positional args plus `--file` for one host per
  line (with `#` comments).
- Per-hop and per-target rendering — vertical path diagram with two
  bars per hop (no-frag / w-frag), fragmentation-point line, and a
  per-target summary.
- Multi-target summary table.
- `README.md` and `HOWITWORKS.md`.

### Notes
The "0.x.0" release numbers in this changelog are retrospective — the
project did not have explicit version tags during the initial day of
development. Each step represents a coherent feature batch landed during
that day.
