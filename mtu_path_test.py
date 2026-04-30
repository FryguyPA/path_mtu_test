#!/usr/bin/env python3
"""
MTU Path Tester
===============

Project : path_mtu_test
Author  : Jeff Fry <jeff@fryguy.net>
Repo    : https://github.com/FryguyPA/path_mtu_test
License : MIT (see LICENSE)
Version : 0.5.0
Date    : 2026-04-30

Runs a traceroute to a target, then for each hop sweeps packet sizes with a
DUAL probe per size:

  1. DF-set probe   — identifies the "no-frag ceiling" and, on failure,
                      captures the router IP + link MTU from the resulting
                      ICMP "Fragmentation Needed" message.
  2. DF-clear probe — confirms the path actually delivers the packet when
                      fragmentation is allowed.

The combination tells you (a) the largest size that fits without
fragmentation, (b) where fragmentation kicks in and which router fragments,
and (c) up to what size fragmented delivery still works.

Sweep schedule (defaults):
    1300, 1301, 1302, ... , 1500   (fine step = 1 byte)
    2000, 2500, 3000, ..., 9000    (coarse step = 500 bytes)

Usage:
    ./mtu_path_test.py 8.8.8.8
    ./mtu_path_test.py 8.8.8.8 1.1.1.1 www.example.com
    ./mtu_path_test.py --file targets.txt --start 1300 --end 9000
    ./mtu_path_test.py --fine-step 5 --fine-pivot 1500 8.8.8.8
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime

__version__ = "0.5.0"
__author__ = "Jeff Fry <jeff@fryguy.net>"
__repo__ = "https://github.com/FryguyPA/path_mtu_test"

# IPv4 (20) + ICMP (8) overhead. ping -s sets the data payload only.
ICMP_OVERHEAD = 28

# Platform shims (mirrors the bash script).
#   macOS BSD ping:  -D for DF, -W in milliseconds.
#   Linux iputils :  -M do for DF, -W in seconds.
_IS_LINUX = platform.system() == "Linux"
_PING_DF_FLAGS = ["-M", "do"] if _IS_LINUX else ["-D"]
_PING_W_DIVISOR = 1000 if _IS_LINUX else 1   # ms → seconds on Linux

# Strip ANSI CSI escapes (used when writing log files).
_ANSI_RE = re.compile(r"\x1B\[[0-9;]*[A-Za-z]")


def _ping_w(timeout_ms: int) -> str:
    """Convert logical milliseconds to whatever the local ping expects, with
    ceiling-division and a floor of 1."""
    w = (timeout_ms + _PING_W_DIVISOR - 1) // _PING_W_DIVISOR
    return str(max(1, w))


def _sanitize_target(t: str) -> str:
    """Filename-safe version of an arbitrary target string."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", t)


def _progress(prefix: str, msg: str) -> None:
    """Carriage-return progress line on stderr; no-op when stderr isn't a tty."""
    if sys.stderr.isatty():
        sys.stderr.write(f"\r{prefix} probing {msg}\033[K")
        sys.stderr.flush()


def _progress_clear() -> None:
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()


class _AnsiStrippingFile:
    """File-like wrapper that strips ANSI sequences before writing."""

    def __init__(self, underlying):
        self._u = underlying

    def write(self, s):
        return self._u.write(_ANSI_RE.sub("", s))

    def flush(self):
        return self._u.flush()

    def close(self):
        return self._u.close()


class _Tee:
    """Fan a stream to multiple file-like sinks."""

    def __init__(self, *sinks):
        self._sinks = sinks

    def write(self, s):
        for sink in self._sinks:
            sink.write(s)
        return len(s)

    def flush(self):
        for sink in self._sinks:
            sink.flush()


# ANSI colors (disabled if not a tty)
class C:
    RESET = "\033[0m"
    DIM = "\033[2m"
    BOLD = "\033[1m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    CYAN = "\033[36m"
    GREY = "\033[90m"


def disable_colors():
    for attr in dir(C):
        if not attr.startswith("_") and attr.isupper():
            setattr(C, attr, "")


@dataclass
class Hop:
    number: int
    ip: str
    hostname: str = ""
    unreachable: bool = False
    # Dual-probe sweep results
    max_no_frag: int = 0          # largest size DF-probe succeeded (no frag needed)
    frag_at: int = 0              # first size DF-probe failed (frag would be required)
    frag_router: str = ""         # router that returned ICMP "Frag Needed"
    frag_router_mtu: int = 0      # MTU it reported on that link
    max_with_frag: int = 0        # largest size delivered with DF cleared
    first_real_fail: int = 0      # first size where BOTH DF and non-DF failed
    df_baseline_failed: bool = False
    nodf_baseline_failed: bool = False
    note: str = ""


def run_traceroute(target: str, max_hops: int) -> list[Hop]:
    cmd = ["traceroute", "-w", "2", "-q", "1", "-m", str(max_hops), target]
    print(f"{C.CYAN}Running:{C.RESET} {' '.join(cmd)}")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=max_hops * 6)
    except subprocess.TimeoutExpired:
        print(f"{C.RED}traceroute timed out{C.RESET}")
        return []
    except FileNotFoundError:
        print(f"{C.RED}traceroute not found on PATH{C.RESET}")
        return []

    hops: list[Hop] = []
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*(\d+)\s+(.+)", line)
        if not m:
            continue
        num = int(m.group(1))
        rest = m.group(2).strip()

        # All-stars hop (no response)
        if re.match(r"^\*(\s|\*)*$", rest):
            hops.append(Hop(number=num, ip="*", unreachable=True))
            continue

        # "host (1.2.3.4)  ..." or just "1.2.3.4 ..."
        m2 = re.search(r"(\S+)\s+\(([0-9a-fA-F:.]+)\)", rest)
        if m2:
            hostname = m2.group(1)
            ip = m2.group(2)
            if hostname == ip:
                hostname = ""
        else:
            m3 = re.match(r"([0-9a-fA-F:.]+)", rest)
            if not m3:
                continue
            ip = m3.group(1)
            hostname = ""
        hops.append(Hop(number=num, ip=ip, hostname=hostname))
    return hops


# Matches both macOS  ("from 1.2.3.4: frag needed and DF set (MTU 1500)")
# and Linux iputils  ("From 1.2.3.4 icmp_seq=1 Frag needed and DF set (mtu = 1500)")
_FRAG_RE = re.compile(
    r"[Ff]rom\s+([0-9a-fA-F:.]+)[^\n]*?[Ff]rag(?:mentation)?\s+needed"
    r"[^\n]*?(?:mtu\s*=\s*|MTU\s+|mtu\s+)(\d+)",
    re.IGNORECASE,
)


def ping_probe(ip: str, total_size: int, timeout_ms: int, df: bool) -> dict:
    """One ICMP echo. Returns:
        ok          — True if the echo reply came back
        frag_router — router IP from "Frag Needed" ICMP error (DF probes only)
        frag_mtu    — MTU it reported (0 if not parsed)
        error       — short string when ok is False
    """
    payload = total_size - ICMP_OVERHEAD
    if payload < 0:
        return {"ok": False, "frag_router": "", "frag_mtu": 0,
                "error": "size below ICMP overhead"}
    cmd = ["ping", "-c", "1", "-W", _ping_w(timeout_ms), "-s", str(payload), ip]
    if df:
        # Insert DF flag(s) right after "ping" so they precede the rest.
        for i, flag in enumerate(_PING_DF_FLAGS):
            cmd.insert(1 + i, flag)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=(timeout_ms / 1000.0) + 2)
    except subprocess.TimeoutExpired:
        return {"ok": False, "frag_router": "", "frag_mtu": 0, "error": "timeout"}

    out = (proc.stdout or "") + (proc.stderr or "")
    # macOS prints "1 packets received"; iputils prints "1 received".
    # Either implies success; "bytes from" is a backstop.
    if proc.returncode == 0 and (
        "1 packets received" in proc.stdout
        or "1 received" in proc.stdout
        or "bytes from" in proc.stdout
    ):
        return {"ok": True, "frag_router": "", "frag_mtu": 0, "error": ""}

    m = _FRAG_RE.search(out)
    if m:
        return {"ok": False, "frag_router": m.group(1),
                "frag_mtu": int(m.group(2)), "error": "frag-needed"}

    if "Message too long" in out or "message too long" in out:
        return {"ok": False, "frag_router": "", "frag_mtu": 0,
                "error": "local iface MTU exceeded"}
    return {"ok": False, "frag_router": "", "frag_mtu": 0, "error": "no reply"}


def _build_sizes(start: int, end: int, step: int,
                 fine_step: int, fine_pivot: int) -> list[int]:
    """Fine resolution from start up to fine_pivot, then coarse step to end.

    Examples (defaults: start=1300, end=9000, step=500, fine_step=1, pivot=1500)
    produce: 1300, 1301, ..., 1500, 2000, 2500, ..., 9000.
    """
    sizes: list[int] = []
    s = start
    if s < fine_pivot and s <= end:
        while s <= fine_pivot and s <= end:
            sizes.append(s)
            s += fine_step
        s = fine_pivot + step
    while s <= end:
        sizes.append(s)
        s += step
    if sizes and sizes[-1] != end and end > sizes[-1]:
        sizes.append(end)
    return sizes


def probe_hop_dual(ip: str, start: int, end: int, step: int, timeout_ms: int,
                   retries: int, fine_step: int = 1, fine_pivot: int = 1500,
                   prefix: str = "") -> dict:
    """
    Per size, send a DF probe and a non-DF probe. Stop sweeping once both
    fail at the same size (real reachability bottleneck) or once we exhaust
    the range.

    Retries only kick in for "no reply" outcomes — a captured "Frag Needed"
    is a definitive answer and isn't retried.

    `prefix` is used for the live progress line on stderr; pass empty to
    suppress.
    """
    sizes = _build_sizes(start, end, step, fine_step, fine_pivot)
    if not sizes:
        sizes = [start]

    out = {
        "max_no_frag": 0,
        "frag_at": 0,
        "frag_router": "",
        "frag_router_mtu": 0,
        "max_with_frag": 0,
        "first_real_fail": 0,
        "df_baseline_failed": False,
        "nodf_baseline_failed": False,
        "note": "",
    }
    first_size = sizes[0]

    def probe_with_retry(size: int, df: bool):
        last = None
        for _ in range(retries + 1):
            last = ping_probe(ip, size, timeout_ms, df=df)
            # Definitive answers we don't retry
            if last["ok"] or last["frag_router"]:
                return last
        return last

    total = len(sizes)
    for idx, size in enumerate(sizes, start=1):
        if prefix:
            _progress(prefix, f"[{idx}/{total}] size={size}  DF…")
        df_r = probe_with_retry(size, df=True)
        if prefix:
            _progress(prefix,
                      f"[{idx}/{total}] size={size}  "
                      f"DF={'OK' if df_r['ok'] else 'FAIL'}  non-DF…")
        nodf_r = probe_with_retry(size, df=False)
        if prefix:
            _progress(prefix,
                      f"[{idx}/{total}] size={size}  "
                      f"DF={'OK' if df_r['ok'] else 'FAIL'}  "
                      f"non-DF={'OK' if nodf_r['ok'] else 'FAIL'}")

        if df_r["ok"]:
            out["max_no_frag"] = size
        else:
            if not out["frag_at"]:
                out["frag_at"] = size
                if df_r["frag_router"]:
                    out["frag_router"] = df_r["frag_router"]
                    out["frag_router_mtu"] = df_r["frag_mtu"]

        if nodf_r["ok"]:
            out["max_with_frag"] = size

        if size == first_size:
            out["df_baseline_failed"] = not df_r["ok"]
            out["nodf_baseline_failed"] = not nodf_r["ok"]

        if not df_r["ok"] and not nodf_r["ok"]:
            out["first_real_fail"] = size
            out["note"] = nodf_r["error"] or df_r["error"]
            break

    if prefix:
        _progress_clear()
    return out


def bar(value: int, lo: int, hi: int, width: int = 28) -> str:
    if hi <= lo or value <= 0:
        return "░" * width
    pct = (value - lo) / (hi - lo)
    pct = max(0.0, min(1.0, pct))
    fill = int(round(pct * width))
    return "█" * fill + "░" * (width - fill)


def render(target: str, hops: list[Hop], start: int, end: int) -> None:
    line = "═" * 78
    print()
    print(line)
    print(f"  {C.BOLD}MTU Path Test{C.RESET}  →  target: {C.CYAN}{target}{C.RESET}")
    print(f"  Tested range: {start} → {end} bytes  "
          f"(dual probe: DF-set + DF-clear per size; "
          f"fine step under 1500, coarse above)")
    print(line)

    for i, h in enumerate(hops):
        is_last = i == len(hops) - 1
        glyph = "◆" if is_last else "●"

        if h.unreachable:
            print(f"  [{h.number:>2}] {C.GREY}{glyph}  *  no response{C.RESET}")
        else:
            label = h.ip + (f"  {C.DIM}({h.hostname}){C.RESET}" if h.hostname else "")
            print(f"  [{h.number:>2}] {C.BOLD}{glyph}{C.RESET}  {label}")

            nf_bar = bar(h.max_no_frag, start, end)
            wf_bar = bar(h.max_with_frag, start, end)

            if h.df_baseline_failed and h.nodf_baseline_failed:
                print(f"        {C.RED}│ no-frag : {bar(0, start, end)}  "
                      f"FAIL at baseline {start}{C.RESET}")
                print(f"        {C.RED}│ w/ frag : {bar(0, start, end)}  "
                      f"FAIL at baseline {start}{C.RESET}")
                if h.note:
                    print(f"        {C.DIM}│ note    : {h.note}{C.RESET}")
            else:
                nf_color = C.GREEN if h.max_no_frag >= end else C.YELLOW if h.max_no_frag else C.RED
                wf_color = C.GREEN if h.max_with_frag >= end else C.YELLOW if h.max_with_frag else C.RED
                nf_label = (f"max={h.max_no_frag}" if h.max_no_frag
                            else f"none up to {start}")
                wf_label = (f"max={h.max_with_frag}" if h.max_with_frag
                            else f"none up to {start}")
                print(f"        {nf_color}│ no-frag : {nf_bar}  {nf_label}{C.RESET}")
                print(f"        {wf_color}│ w/ frag : {wf_bar}  {wf_label}{C.RESET}")

                if h.frag_at:
                    if h.frag_router:
                        print(f"        {C.YELLOW}│ frag pt : {h.frag_at} "
                              f"→ via {h.frag_router} (link MTU {h.frag_router_mtu})"
                              f"{C.RESET}")
                    else:
                        print(f"        {C.YELLOW}│ frag pt : {h.frag_at} "
                              f"(router silent — ICMP rate-limited or filtered)"
                              f"{C.RESET}")
                else:
                    print(f"        {C.GREEN}│ frag pt : none in tested range"
                          f"{C.RESET}")

                if h.first_real_fail:
                    print(f"        {C.RED}│ hard fail at {h.first_real_fail} "
                          f"(both DF and DF-clear)  {h.note}{C.RESET}")

        if not is_last:
            print(f"        {C.DIM}▼{C.RESET}")

    print(line)

    # Summary
    tested = [h for h in hops
              if not h.unreachable and (h.max_no_frag or h.frag_at or h.max_with_frag)]
    if tested:
        path_no_frag = min((h.max_no_frag for h in tested if h.max_no_frag),
                           default=0)
        path_with_frag = min((h.max_with_frag for h in tested if h.max_with_frag),
                             default=0)
        first_frag = next((h for h in tested if h.frag_at), None)

        print(f"  {C.BOLD}No-frag Path MTU:{C.RESET}    {path_no_frag} bytes")
        print(f"  {C.BOLD}Frag-OK Path MTU:{C.RESET}    {path_with_frag} bytes")
        if first_frag:
            who = (f"{first_frag.frag_router} (link MTU {first_frag.frag_router_mtu})"
                   if first_frag.frag_router else "router silent")
            print(f"  {C.BOLD}First fragmentation:{C.RESET} hop {first_frag.number} "
                  f"({first_frag.ip}) starts fragmenting at {first_frag.frag_at}"
                  f" — {who}")
        else:
            print(f"  {C.GREEN}No fragmentation observed within the tested range."
                  f"{C.RESET}")
    print(line)
    print()


def load_targets_from_file(path: str) -> list[str]:
    """Load one target per line. Blank lines and #-comments are ignored.
    A trailing inline comment after whitespace is stripped, e.g. `1.1.1.1  # cf`."""
    out: list[str] = []
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            line = re.split(r"\s+#", line, maxsplit=1)[0].strip()
            line = line.split()[0] if line.split() else ""
            if line:
                out.append(line)
    # de-dupe while preserving order
    seen: set[str] = set()
    uniq: list[str] = []
    for t in out:
        if t not in seen:
            seen.add(t)
            uniq.append(t)
    return uniq


def _run_one_target_body(target: str, args) -> tuple[str, list[Hop]]:
    print(f"\n{C.BOLD}{'━' * 72}{C.RESET}")
    print(f"{C.BOLD}Target:{C.RESET} {C.CYAN}{target}{C.RESET}")
    print(f"{C.BOLD}{'━' * 72}{C.RESET}")

    hops = run_traceroute(target, args.max_hops)
    if not hops:
        print(f"{C.RED}No hops discovered for {target}{C.RESET}")
        return target, []

    print(f"Discovered {len(hops)} hop(s). Probing MTU per hop "
          f"({args.start}→{args.end}, fine_step={args.fine_step} up to "
          f"{args.fine_pivot}, then step={args.step})...\n")

    for h in hops:
        prefix = f"  [{h.number:>2}] {h.ip:<39}"
        if h.unreachable:
            print(f"{prefix} {C.GREY}skip (no response){C.RESET}")
            continue
        r = probe_hop_dual(
            h.ip, args.start, args.end, args.step, args.timeout_ms, args.retries,
            fine_step=args.fine_step, fine_pivot=args.fine_pivot, prefix=prefix,
        )
        h.max_no_frag = r["max_no_frag"]
        h.frag_at = r["frag_at"]
        h.frag_router = r["frag_router"]
        h.frag_router_mtu = r["frag_router_mtu"]
        h.max_with_frag = r["max_with_frag"]
        h.first_real_fail = r["first_real_fail"]
        h.df_baseline_failed = r["df_baseline_failed"]
        h.nodf_baseline_failed = r["nodf_baseline_failed"]
        h.note = r["note"]

        nf = h.max_no_frag or "—"
        wf = h.max_with_frag or "—"
        if h.df_baseline_failed and h.nodf_baseline_failed:
            print(f"{prefix} {C.RED}both probes fail at baseline "
                  f"({h.note}){C.RESET}")
        elif h.frag_at and h.frag_router:
            print(f"{prefix} {C.YELLOW}no-frag={nf}, frag@{h.frag_at} via "
                  f"{h.frag_router} (MTU {h.frag_router_mtu}), w/frag={wf}"
                  f"{C.RESET}")
        elif h.frag_at:
            print(f"{prefix} {C.YELLOW}no-frag={nf}, frag@{h.frag_at} "
                  f"(silent), w/frag={wf}{C.RESET}")
        else:
            print(f"{prefix} {C.GREEN}no-frag={nf}, w/frag={wf} ✓ "
                  f"(no frag in range){C.RESET}")

    render(target, hops, args.start, args.end)
    return target, hops


def run_one_target(target: str, args, run_ts: str,
                   saved_files: list[str]) -> tuple[str, list[Hop]]:
    """Wrap _run_one_target_body so its stdout is fanned to a per-target log
    (with ANSI stripped) when saving is enabled."""
    if not args.no_save:
        safe = _sanitize_target(target)
        ext = args.out_ext.lstrip(".")
        out_path = os.path.join(args.out_dir, f"{safe}_{run_ts}.{ext}")
        try:
            os.makedirs(args.out_dir, exist_ok=True)
            log_fh = open(out_path, "w", encoding="utf-8")
        except OSError as e:
            print(f"{C.RED}Cannot open log file {out_path}: {e}{C.RESET}",
                  file=sys.stderr)
            return _run_one_target_body(target, args)
        print(f"{C.DIM}↳ saving to:{C.RESET} {out_path}")
        original_stdout = sys.stdout
        sys.stdout = _Tee(original_stdout, _AnsiStrippingFile(log_fh))
        try:
            return _run_one_target_body(target, args)
        finally:
            try:
                sys.stdout.flush()
            except Exception:
                pass
            sys.stdout = original_stdout
            log_fh.close()
            saved_files.append(out_path)
    else:
        return _run_one_target_body(target, args)


def render_multi_summary(results: list[tuple[str, list[Hop]]]) -> None:
    if len(results) <= 1:
        return
    line = "═" * 86
    print(line)
    print(f"  {C.BOLD}Multi-Target Summary{C.RESET}")
    print(line)
    print(f"  {'Target':<28} {'No-frag':>9} {'W/frag':>9}  Fragmentation point")
    print(f"  {'-' * 28} {'-' * 9} {'-' * 9}  {'-' * 36}")
    for target, hops in results:
        tested = [h for h in hops if not h.unreachable
                  and (h.max_no_frag or h.frag_at or h.max_with_frag)]
        if not tested:
            print(f"  {target:<28} {'—':>9} {'—':>9}  {C.GREY}no data{C.RESET}")
            continue
        nf_min = min((h.max_no_frag for h in tested if h.max_no_frag), default=0)
        wf_min = min((h.max_with_frag for h in tested if h.max_with_frag), default=0)
        first = next((h for h in tested if h.frag_at), None)
        if first:
            who = (f"{first.frag_router} MTU {first.frag_router_mtu}"
                   if first.frag_router else "silent")
            note = f"hop {first.number} @ {first.frag_at} ({who})"
            color = C.YELLOW
        else:
            note = "no frag in range"
            color = C.GREEN
        print(f"  {target:<28} {nf_min:>9} {wf_min:>9}  {color}{note}{C.RESET}")
    print(line)
    print()


def main() -> int:
    p = argparse.ArgumentParser(
        description=f"Traceroute + per-hop MTU sweep (v{__version__})",
        epilog=f"Author: {__author__}  ·  Repo: {__repo__}",
    )
    p.add_argument("--version", action="version",
                   version=f"mtu_path_test.py {__version__}")
    p.add_argument("targets", nargs="*",
                   help="One or more destination IPs/hostnames")
    p.add_argument("--file", "-f", help="File with one target per line "
                   "(blank lines and # comments ignored)")
    p.add_argument("--start", type=int, default=1300,
                   help="Starting MTU (default 1300)")
    p.add_argument("--end", type=int, default=9000,
                   help="Ending MTU (default 9000)")
    p.add_argument("--step", type=int, default=500,
                   help="Coarse step above --fine-pivot (default 500)")
    p.add_argument("--fine-step", type=int, default=1,
                   help="Fine step from --start up to --fine-pivot (default 1)")
    p.add_argument("--fine-pivot", type=int, default=1500,
                   help="Boundary between fine and coarse stepping (default 1500)")
    p.add_argument("--max-hops", type=int, default=30,
                   help="Max traceroute hops (default 30)")
    p.add_argument("--timeout-ms", type=int, default=1500,
                   help="Per-probe wait in ms (auto-converted on Linux) (default 1500)")
    p.add_argument("--retries", type=int, default=2,
                   help="Retries per probe before counting a fail (default 2)")
    p.add_argument("--no-color", action="store_true", help="Disable ANSI colors")
    p.add_argument("--no-save", action="store_true",
                   help="Don't write per-target output to a file")
    p.add_argument("--out-dir", default=".",
                   help="Directory for saved per-target logs (default: cwd)")
    p.add_argument("--out-ext", default="log",
                   help="Extension for saved logs (default: log)")
    args = p.parse_args()

    if args.no_color or not sys.stdout.isatty():
        disable_colors()

    if (args.start < 64 or args.end > 65500 or args.start >= args.end
            or args.step < 1 or args.fine_step < 1):
        print("Invalid --start/--end/--step/--fine-step combination",
              file=sys.stderr)
        return 2

    if not shutil.which("traceroute") or not shutil.which("ping"):
        print("traceroute and/or ping not found", file=sys.stderr)
        return 2

    targets: list[str] = list(args.targets)
    if args.file:
        try:
            targets.extend(load_targets_from_file(args.file))
        except OSError as e:
            print(f"Could not read --file {args.file}: {e}", file=sys.stderr)
            return 2

    # de-dupe, preserve order
    seen: set[str] = set()
    targets = [t for t in targets if not (t in seen or seen.add(t))]

    if not targets:
        print("No targets given. Pass one or more positional targets, or --file.",
              file=sys.stderr)
        return 2

    run_ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    saved_files: list[str] = []

    results: list[tuple[str, list[Hop]]] = []
    for t in targets:
        try:
            results.append(run_one_target(t, args, run_ts, saved_files))
        except KeyboardInterrupt:
            print(f"\n{C.YELLOW}Skipping {t} (interrupted){C.RESET}")
            results.append((t, []))

    render_multi_summary(results)

    if saved_files:
        print(f"{C.BOLD}Saved logs:{C.RESET}")
        for f in saved_files:
            print(f"  {f}")
        print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted")
        sys.exit(130)
