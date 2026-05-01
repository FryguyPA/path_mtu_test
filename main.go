// ============================================================================
//
//	mtu_path_test (Go) — dual-probe MTU path tester
//
//	Project : path_mtu_test
//	Author  : Jeff Fry <jeff@fryguy.net>
//	Repo    : https://github.com/FryguyPA/path_mtu_test
//	License : MIT (see LICENSE)
//	Version : 0.7.0
//	Date    : 2026-05-01
//
//	Per hop, per packet size, sends:
//	  1. ping with DF set     — finds the no-frag ceiling and parses any
//	     ICMP "Fragmentation Needed" response for the offending router.
//	  2. ping with DF clear   — confirms the path delivers when fragmentation
//	     is allowed.
//
//	This implementation shells out to the platform's native ping/traceroute
//	(matching the bash, Python, and PowerShell versions) — it does NOT yet
//	use raw ICMP sockets. Build:
//
//	    go build -o mtu_path_test
//	    ./mtu_path_test 8.8.8.8
//
// ============================================================================
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	Version      = "0.7.0"
	Author       = "Jeff Fry <jeff@fryguy.net>"
	Repo         = "https://github.com/FryguyPA/path_mtu_test"
	ICMPOverhead = 28
	BarWidth     = 28
)

// ---------------------------------------------------------------- types ----

type Hop struct {
	Number      int
	IP          string
	Hostname    string
	Unreachable bool

	MaxNoFrag        int
	FragAt           int
	FragRouter       string
	FragRouterMTU    int
	MaxWithFrag      int
	FirstRealFail    int
	DfBaselineFail   bool
	NoDfBaselineFail bool
	Note             string
}

type probeResult struct {
	OK         bool
	FragRouter string
	FragMTU    int
	Err        string
}

type sweepResult struct {
	MaxNoFrag        int
	FragAt           int
	FragRouter       string
	FragRouterMTU    int
	MaxWithFrag      int
	FirstRealFail    int
	DfBaselineFail   bool
	NoDfBaselineFail bool
	Note             string
}

type config struct {
	Targets   []string
	File      string
	Start     int
	End       int
	Step      int
	FineStep  int
	FinePivot int
	MaxHops   int
	TimeoutMs int
	Retries   int
	Iface     string
	NoColor   bool
	NoSave    bool
	OutDir    string
	OutExt    string
	Version   bool
	Help      bool
}

// ----------------------------------------------------- platform detection ---

var (
	isLinux   = runtime.GOOS == "linux"
	isWindows = runtime.GOOS == "windows"
	pingExe   = func() string {
		if isWindows {
			return "ping.exe"
		}
		return "ping"
	}()
	trExe = func() string {
		if isWindows {
			return "tracert.exe"
		}
		return "traceroute"
	}()
)

// pingArgs builds the platform-correct ping arguments.
func pingArgs(payload, timeoutMs int, df bool, ifaceAddr, ip string) []string {
	args := []string{}
	switch {
	case isWindows:
		if df {
			args = append(args, "-f")
		}
		args = append(args,
			"-n", "1",
			"-w", strconv.Itoa(timeoutMs),
			"-l", strconv.Itoa(payload),
		)
		if ifaceAddr != "" {
			args = append(args, "-S", ifaceAddr)
		}
	case isLinux:
		if df {
			args = append(args, "-M", "do")
		}
		wait := (timeoutMs + 999) / 1000
		if wait < 1 {
			wait = 1
		}
		args = append(args,
			"-c", "1",
			"-W", strconv.Itoa(wait),
			"-s", strconv.Itoa(payload),
		)
		if ifaceAddr != "" {
			args = append(args, "-I", ifaceAddr)
		}
	default: // macOS BSD
		if df {
			args = append(args, "-D")
		}
		args = append(args,
			"-c", "1",
			"-W", strconv.Itoa(timeoutMs), // ms
			"-s", strconv.Itoa(payload),
		)
		if ifaceAddr != "" {
			args = append(args, "-b", ifaceAddr)
		}
	}
	args = append(args, ip)
	return args
}

func tracerouteArgs(target string, maxHops int, ifaceAddr string) []string {
	args := []string{}
	if isWindows {
		args = append(args, "-d", "-h", strconv.Itoa(maxHops), "-w", "2000")
		if ifaceAddr != "" {
			args = append(args, "-S", ifaceAddr)
		}
	} else {
		args = append(args, "-w", "2", "-q", "1", "-m", strconv.Itoa(maxHops))
		if ifaceAddr != "" {
			args = append(args, "-i", ifaceAddr)
		}
	}
	args = append(args, target)
	return args
}

// ------------------------------------------------------------- regexes ----

var (
	fragLineRE    = regexp.MustCompile(`(?i)Packet needs to be fragmented|Frag(?:mentation)? needed`)
	fragIPRE      = regexp.MustCompile(`(?i)from\s+([0-9.]+)`)
	fragMTURE     = regexp.MustCompile(`(?i)mtu\s*[=]?\s*(\d+)`)
	winSuccessRE  = regexp.MustCompile(`Reply from\s+\S+:\s*bytes=\d+`)
	hopLineRE     = regexp.MustCompile(`^\s*(\d+)\s+(.+)$`)
	ipv4RE        = regexp.MustCompile(`(\d+\.\d+\.\d+\.\d+)`)
	ipv4InParens  = regexp.MustCompile(`\((\d+\.\d+\.\d+\.\d+)\)`)
	ansiRE        = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
	unsafeFnameRE = regexp.MustCompile(`[^A-Za-z0-9._-]`)
)

// parseFragNeeded returns the offending router and (if reported) link MTU
// from a ping output that tripped the DF bit.
func parseFragNeeded(out string) (router string, mtu int, ok bool) {
	for _, line := range strings.Split(out, "\n") {
		if !fragLineRE.MatchString(line) {
			continue
		}
		ok = true
		if m := fragIPRE.FindStringSubmatch(line); m != nil {
			router = strings.TrimRight(m[1], ":")
		}
		if m := fragMTURE.FindStringSubmatch(line); m != nil {
			n, _ := strconv.Atoi(m[1])
			mtu = n
		}
		return
	}
	return "", 0, false
}

// successPattern returns true when the captured ping output looks like a
// successful echo reply on any of the supported platforms.
func successPattern(out string) bool {
	return strings.Contains(out, "1 packets received") || // BSD
		strings.Contains(out, "1 received") || // iputils
		strings.Contains(out, "bytes from") || // both *nix
		winSuccessRE.MatchString(out) // Windows
}

// ------------------------------------------------------------ sweep list ----

func buildSizes(start, end, step, fineStep, finePivot int) []int {
	out := []int{}
	s := start
	if s < finePivot && s <= end {
		for s <= finePivot && s <= end {
			out = append(out, s)
			s += fineStep
		}
		s = finePivot + step
	}
	for s <= end {
		out = append(out, s)
		s += step
	}
	if len(out) > 0 {
		last := out[len(out)-1]
		if last != end && end > last {
			out = append(out, end)
		}
	}
	return out
}

// ------------------------------------------------------------ rendering ----

func bar(value, lo, hi, width int) string {
	if value <= 0 || hi <= lo {
		return strings.Repeat("░", width)
	}
	pct := float64(value-lo) / float64(hi-lo)
	if pct < 0 {
		pct = 0
	}
	if pct > 1 {
		pct = 1
	}
	fill := int(pct*float64(width) + 0.5)
	if fill > width {
		fill = width
	}
	if fill < 0 {
		fill = 0
	}
	return strings.Repeat("█", fill) + strings.Repeat("░", width-fill)
}

// ------------------------------------------------------------- helpers ----

func sanitizeTarget(t string) string {
	return unsafeFnameRE.ReplaceAllString(t, "_")
}

func stripANSI(s string) string {
	return ansiRE.ReplaceAllString(s, "")
}

// resolveIfaceIPv4 turns an interface name OR an IPv4 address into a usable
// IPv4 source address. Used for `ping -I/-S/-b` and `tracert -S`.
func resolveIfaceIPv4(iface string) (string, error) {
	if iface == "" {
		return "", nil
	}
	if ip := net.ParseIP(iface); ip != nil && ip.To4() != nil {
		return ip.String(), nil
	}
	netIface, err := net.InterfaceByName(iface)
	if err != nil {
		return "", fmt.Errorf("cannot find interface %q: %w", iface, err)
	}
	addrs, err := netIface.Addrs()
	if err != nil {
		return "", err
	}
	for _, addr := range addrs {
		var ip net.IP
		switch v := addr.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		if ip == nil {
			continue
		}
		if v4 := ip.To4(); v4 != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
			return v4.String(), nil
		}
	}
	return "", fmt.Errorf("no usable IPv4 address on interface %q", iface)
}

// --------------------------------------------------------- output / log ----

// stripAnsiWriter wraps a Writer and strips ANSI escapes before delegating.
type stripAnsiWriter struct{ w io.Writer }

func (s *stripAnsiWriter) Write(p []byte) (int, error) {
	if _, err := s.w.Write([]byte(stripANSI(string(p)))); err != nil {
		return 0, err
	}
	return len(p), nil
}

// Global current writer — main swaps this between os.Stdout and a tee
// (stdout + per-target log).
var out io.Writer = os.Stdout
var currentLogFile *os.File

func setLogFile(f *os.File) {
	currentLogFile = f
	if f == nil {
		out = os.Stdout
		return
	}
	out = io.MultiWriter(os.Stdout, &stripAnsiWriter{w: f})
}

// outprintln / outprintf emit to the current `out` sink.
func outprintln(args ...any)               { fmt.Fprintln(out, args...) }
func outprintf(format string, args ...any) { fmt.Fprintf(out, format, args...) }

// ---------------------------------------------------------- ANSI colors ----

type palette struct{ Reset, Dim, Bold, Green, Yellow, Red, Cyan, Grey string }

var col = palette{}

func setColors(useColor bool) {
	if !useColor {
		col = palette{}
		return
	}
	col = palette{
		Reset:  "\x1b[0m",
		Dim:    "\x1b[2m",
		Bold:   "\x1b[1m",
		Green:  "\x1b[32m",
		Yellow: "\x1b[33m",
		Red:    "\x1b[31m",
		Cyan:   "\x1b[36m",
		Grey:   "\x1b[90m",
	}
}

// --------------------------------------------------------- live progress ---

var stderrIsTTY = func() bool {
	fi, err := os.Stderr.Stat()
	return err == nil && (fi.Mode()&os.ModeCharDevice) != 0
}()

func writeProgress(prefix, msg string) {
	if !stderrIsTTY {
		return
	}
	fmt.Fprintf(os.Stderr, "\r%s probing %s\x1b[K", prefix, msg)
}

func clearProgress() {
	if !stderrIsTTY {
		return
	}
	fmt.Fprint(os.Stderr, "\r\x1b[K")
}

// ----------------------------------------------------------- subprocess ----

// runCmd captures combined stdout+stderr from cmd, with an enforced wall
// clock deadline (a little longer than the per-probe timeout).
func runCmd(name string, args []string, hardDeadline time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), hardDeadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// ---------------------------------------------------------- traceroute ----

func runTraceroute(target string, maxHops int, ifaceAddr string) []Hop {
	args := tracerouteArgs(target, maxHops, ifaceAddr)
	outprintf("%sRunning:%s %s %s\n", col.Cyan, col.Reset, trExe, strings.Join(args, " "))

	deadline := time.Duration(maxHops*6) * time.Second
	if deadline < 30*time.Second {
		deadline = 30 * time.Second
	}
	stdout, _ := runCmd(trExe, args, deadline)
	return parseTraceroute(stdout)
}

func parseTraceroute(stdout string) []Hop {
	hops := []Hop{}
	for _, line := range strings.Split(stdout, "\n") {
		m := hopLineRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[1])
		rest := strings.TrimSpace(m[2])

		if strings.HasPrefix(rest, "*") || strings.Contains(rest, "Request timed out") {
			hops = append(hops, Hop{Number: n, IP: "*", Unreachable: true})
			continue
		}

		ip, host := "", ""
		if mm := ipv4InParens.FindStringSubmatch(rest); mm != nil {
			ip = mm[1]
			if idx := strings.Index(rest, "("); idx > 0 {
				cand := strings.TrimSpace(rest[:idx])
				if cand != ip {
					host = cand
				}
			}
		} else {
			ips := ipv4RE.FindAllString(rest, -1)
			if len(ips) > 0 {
				ip = ips[len(ips)-1] // last IP on the line (Windows tracert -d)
			}
		}
		if ip != "" {
			hops = append(hops, Hop{Number: n, IP: ip, Hostname: host})
		}
	}
	return hops
}

// ----------------------------------------------------------- ping probe ----

func pingProbe(ip string, totalSize, timeoutMs int, df bool, ifaceAddr string) probeResult {
	payload := totalSize - ICMPOverhead
	if payload < 0 {
		return probeResult{Err: "size below ICMP overhead"}
	}
	args := pingArgs(payload, timeoutMs, df, ifaceAddr, ip)
	deadline := time.Duration(timeoutMs)*time.Millisecond + 2*time.Second
	stdout, _ := runCmd(pingExe, args, deadline)

	if successPattern(stdout) {
		return probeResult{OK: true}
	}
	if router, mtu, ok := parseFragNeeded(stdout); ok {
		return probeResult{Err: "frag-needed", FragRouter: router, FragMTU: mtu}
	}
	if strings.Contains(stdout, "Message too long") || strings.Contains(stdout, "message too long") ||
		strings.Contains(stdout, "transmit failed") || strings.Contains(stdout, "General failure") {
		return probeResult{Err: "local-mtu-or-error"}
	}
	return probeResult{Err: "no reply"}
}

func probeWithRetry(ip string, size, timeoutMs int, df bool, retries int, ifaceAddr string) probeResult {
	var last probeResult
	for i := 0; i <= retries; i++ {
		last = pingProbe(ip, size, timeoutMs, df, ifaceAddr)
		if last.OK || last.FragRouter != "" {
			return last
		}
	}
	return last
}

// --------------------------------------------------------- sweep per hop ---

func okStr(b bool) string {
	if b {
		return "OK"
	}
	return "FAIL"
}

func probeHopDual(ip string, c *config, ifaceAddr, prefix string) sweepResult {
	sizes := buildSizes(c.Start, c.End, c.Step, c.FineStep, c.FinePivot)
	if len(sizes) == 0 {
		sizes = []int{c.Start}
	}

	r := sweepResult{}
	total := len(sizes)

	for idx, size := range sizes {
		if prefix != "" {
			writeProgress(prefix, fmt.Sprintf("[%d/%d] size=%d  DF…", idx+1, total, size))
		}
		df := probeWithRetry(ip, size, c.TimeoutMs, true, c.Retries, ifaceAddr)
		if prefix != "" {
			writeProgress(prefix, fmt.Sprintf("[%d/%d] size=%d  DF=%s  non-DF…",
				idx+1, total, size, okStr(df.OK)))
		}
		nodf := probeWithRetry(ip, size, c.TimeoutMs, false, c.Retries, ifaceAddr)
		if prefix != "" {
			writeProgress(prefix, fmt.Sprintf("[%d/%d] size=%d  DF=%s  non-DF=%s",
				idx+1, total, size, okStr(df.OK), okStr(nodf.OK)))
		}

		if df.OK {
			r.MaxNoFrag = size
		} else if r.FragAt == 0 {
			r.FragAt = size
			if df.FragRouter != "" {
				r.FragRouter = df.FragRouter
				r.FragRouterMTU = df.FragMTU
			}
		}
		if nodf.OK {
			r.MaxWithFrag = size
		}
		if idx == 0 {
			r.DfBaselineFail = !df.OK
			r.NoDfBaselineFail = !nodf.OK
		}
		if !df.OK && !nodf.OK {
			r.FirstRealFail = size
			r.Note = nodf.Err
			if r.Note == "" {
				r.Note = df.Err
			}
			break
		}
	}

	if prefix != "" {
		clearProgress()
	}
	return r
}

// ------------------------------------------------------------- render -----

func renderTarget(target string, hops []Hop, c *config) {
	sep := strings.Repeat("═", 78)
	outprintln()
	outprintln(sep)
	outprintf("  %sMTU Path Test%s  →  target: %s%s%s\n",
		col.Bold, col.Reset, col.Cyan, target, col.Reset)
	outprintf("  Tested range: %d → %d bytes  (dual probe: DF-set + DF-clear per size; fine step under %d, coarse above)\n",
		c.Start, c.End, c.FinePivot)
	outprintln(sep)

	for i, h := range hops {
		isLast := i == len(hops)-1
		glyph := "●"
		if isLast {
			glyph = "◆"
		}
		if h.Unreachable {
			outprintf("  [%2d] %s%s  *  no response%s\n",
				h.Number, col.Grey, glyph, col.Reset)
		} else {
			label := h.IP
			if h.Hostname != "" {
				label = fmt.Sprintf("%s  %s(%s)%s", h.IP, col.Dim, h.Hostname, col.Reset)
			}
			outprintf("  [%2d] %s%s%s  %s\n", h.Number, col.Bold, glyph, col.Reset, label)

			if h.DfBaselineFail && h.NoDfBaselineFail {
				b0 := bar(0, c.Start, c.End, BarWidth)
				outprintf("        %s│ no-frag : %s  FAIL at baseline %d%s\n", col.Red, b0, c.Start, col.Reset)
				outprintf("        %s│ w/ frag : %s  FAIL at baseline %d%s\n", col.Red, b0, c.Start, col.Reset)
				if h.Note != "" {
					outprintf("        %s│ note    : %s%s\n", col.Dim, h.Note, col.Reset)
				}
			} else {
				nfBar := bar(h.MaxNoFrag, c.Start, c.End, BarWidth)
				wfBar := bar(h.MaxWithFrag, c.Start, c.End, BarWidth)
				nfColor := col.Yellow
				if h.MaxNoFrag >= c.End {
					nfColor = col.Green
				} else if h.MaxNoFrag == 0 {
					nfColor = col.Red
				}
				wfColor := col.Yellow
				if h.MaxWithFrag >= c.End {
					wfColor = col.Green
				} else if h.MaxWithFrag == 0 {
					wfColor = col.Red
				}
				nfLabel := fmt.Sprintf("max=%d", h.MaxNoFrag)
				if h.MaxNoFrag == 0 {
					nfLabel = fmt.Sprintf("none up to %d", c.Start)
				}
				wfLabel := fmt.Sprintf("max=%d", h.MaxWithFrag)
				if h.MaxWithFrag == 0 {
					wfLabel = fmt.Sprintf("none up to %d", c.Start)
				}
				outprintf("        %s│ no-frag : %s  %s%s\n", nfColor, nfBar, nfLabel, col.Reset)
				outprintf("        %s│ w/ frag : %s  %s%s\n", wfColor, wfBar, wfLabel, col.Reset)

				switch {
				case h.FragAt > 0 && h.FragRouter != "":
					mtuPart := ""
					if h.FragRouterMTU > 0 {
						mtuPart = fmt.Sprintf(" (link MTU %d)", h.FragRouterMTU)
					}
					outprintf("        %s│ frag pt : %d → via %s%s%s\n",
						col.Yellow, h.FragAt, h.FragRouter, mtuPart, col.Reset)
				case h.FragAt > 0:
					outprintf("        %s│ frag pt : %d (router silent — ICMP rate-limited or filtered)%s\n",
						col.Yellow, h.FragAt, col.Reset)
				default:
					outprintf("        %s│ frag pt : none in tested range%s\n", col.Green, col.Reset)
				}
				if h.FirstRealFail > 0 {
					outprintf("        %s│ hard fail at %d (both DF and DF-clear)  %s%s\n",
						col.Red, h.FirstRealFail, h.Note, col.Reset)
				}
			}
		}
		if !isLast {
			outprintf("        %s▼%s\n", col.Dim, col.Reset)
		}
	}
	outprintln(sep)

	// Per-target summary
	tested := []Hop{}
	for _, h := range hops {
		if !h.Unreachable && (h.MaxNoFrag != 0 || h.FragAt != 0 || h.MaxWithFrag != 0) {
			tested = append(tested, h)
		}
	}
	if len(tested) > 0 {
		pnf, pwf := minPositive(tested, func(h Hop) int { return h.MaxNoFrag }),
			minPositive(tested, func(h Hop) int { return h.MaxWithFrag })
		outprintf("  %sNo-frag Path MTU:%s    %d bytes\n", col.Bold, col.Reset, pnf)
		outprintf("  %sFrag-OK Path MTU:%s    %d bytes\n", col.Bold, col.Reset, pwf)
		var first *Hop
		for i := range tested {
			if tested[i].FragAt > 0 {
				first = &tested[i]
				break
			}
		}
		if first != nil {
			who := "router silent"
			if first.FragRouter != "" {
				if first.FragRouterMTU > 0 {
					who = fmt.Sprintf("%s (link MTU %d)", first.FragRouter, first.FragRouterMTU)
				} else {
					who = first.FragRouter
				}
			}
			outprintf("  %sFirst fragmentation:%s hop %d (%s) starts fragmenting at %d — %s\n",
				col.Bold, col.Reset, first.Number, first.IP, first.FragAt, who)
		} else {
			outprintf("  %sNo fragmentation observed within the tested range.%s\n",
				col.Green, col.Reset)
		}
	}
	outprintln(sep)
	outprintln()
}

func minPositive(hops []Hop, get func(Hop) int) int {
	best := 0
	for _, h := range hops {
		v := get(h)
		if v > 0 && (best == 0 || v < best) {
			best = v
		}
	}
	return best
}

func renderMultiSummary(results []targetResult) {
	if len(results) <= 1 {
		return
	}
	sep := strings.Repeat("═", 86)
	outprintln(sep)
	outprintf("  %sMulti-Target Summary%s\n", col.Bold, col.Reset)
	outprintln(sep)
	outprintf("  %-28s %9s %9s  %s\n", "Target", "No-frag", "W/frag", "Fragmentation point")
	outprintf("  %s %s %s  %s\n",
		strings.Repeat("-", 28), strings.Repeat("-", 9),
		strings.Repeat("-", 9), strings.Repeat("-", 36))
	for _, r := range results {
		tested := []Hop{}
		for _, h := range r.Hops {
			if !h.Unreachable && (h.MaxNoFrag != 0 || h.FragAt != 0 || h.MaxWithFrag != 0) {
				tested = append(tested, h)
			}
		}
		if len(tested) == 0 {
			outprintf("  %-28s %9s %9s  %sno data%s\n",
				r.Target, "—", "—", col.Grey, col.Reset)
			continue
		}
		pnf := minPositive(tested, func(h Hop) int { return h.MaxNoFrag })
		pwf := minPositive(tested, func(h Hop) int { return h.MaxWithFrag })
		var first *Hop
		for i := range tested {
			if tested[i].FragAt > 0 {
				first = &tested[i]
				break
			}
		}
		var note, color string
		if first != nil {
			who := "silent"
			if first.FragRouter != "" {
				who = fmt.Sprintf("%s MTU %d", first.FragRouter, first.FragRouterMTU)
			}
			note = fmt.Sprintf("hop %d @ %d (%s)", first.Number, first.FragAt, who)
			color = col.Yellow
		} else {
			note = "no frag in range"
			color = col.Green
		}
		outprintf("  %-28s %9d %9d  %s%s%s\n",
			r.Target, pnf, pwf, color, note, col.Reset)
	}
	outprintln(sep)
	outprintln()
}

type targetResult struct {
	Target string
	Hops   []Hop
}

// ------------------------------------------------------- targets-from-file ---

func loadTargetsFromFile(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := []string{}
	seen := map[string]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		first := strings.Fields(line)[0]
		if !seen[first] {
			seen[first] = true
			out = append(out, first)
		}
	}
	return out, sc.Err()
}

// --------------------------------------------------------- run-one-target ---

func runOneTarget(target string, c *config, ifaceAddr string) []Hop {
	bar1 := strings.Repeat("━", 72)
	outprintln()
	outprintf("%s%s%s\n", col.Bold, bar1, col.Reset)
	outprintf("%sTarget:%s %s%s%s\n", col.Bold, col.Reset, col.Cyan, target, col.Reset)
	outprintf("%s%s%s\n", col.Bold, bar1, col.Reset)

	hops := runTraceroute(target, c.MaxHops, ifaceAddr)
	if len(hops) == 0 {
		outprintf("%sNo hops discovered for %s%s\n", col.Red, target, col.Reset)
		return nil
	}

	outprintf("Discovered %d hop(s). Probing MTU per hop (%d→%d, fine_step=%d up to %d, then step=%d)...\n\n",
		len(hops), c.Start, c.End, c.FineStep, c.FinePivot, c.Step)

	for i := range hops {
		h := &hops[i]
		prefix := fmt.Sprintf("  [%2d] %-39s", h.Number, h.IP)
		if h.Unreachable {
			outprintf("%s %sskip (no response)%s\n", prefix, col.Grey, col.Reset)
			continue
		}
		r := probeHopDual(h.IP, c, ifaceAddr, prefix)
		h.MaxNoFrag = r.MaxNoFrag
		h.FragAt = r.FragAt
		h.FragRouter = r.FragRouter
		h.FragRouterMTU = r.FragRouterMTU
		h.MaxWithFrag = r.MaxWithFrag
		h.FirstRealFail = r.FirstRealFail
		h.DfBaselineFail = r.DfBaselineFail
		h.NoDfBaselineFail = r.NoDfBaselineFail
		h.Note = r.Note

		nf := dashOr(h.MaxNoFrag)
		wf := dashOr(h.MaxWithFrag)

		switch {
		case h.DfBaselineFail && h.NoDfBaselineFail:
			outprintf("%s %sboth probes fail at baseline (%s)%s\n",
				prefix, col.Red, h.Note, col.Reset)
		case h.FragAt > 0 && h.FragRouter != "":
			mtuPart := ""
			if h.FragRouterMTU > 0 {
				mtuPart = fmt.Sprintf(" (MTU %d)", h.FragRouterMTU)
			}
			outprintf("%s %sno-frag=%s, frag@%d via %s%s, w/frag=%s%s\n",
				prefix, col.Yellow, nf, h.FragAt, h.FragRouter, mtuPart, wf, col.Reset)
		case h.FragAt > 0:
			outprintf("%s %sno-frag=%s, frag@%d (silent), w/frag=%s%s\n",
				prefix, col.Yellow, nf, h.FragAt, wf, col.Reset)
		default:
			outprintf("%s %sno-frag=%s, w/frag=%s ✓ (no frag in range)%s\n",
				prefix, col.Green, nf, wf, col.Reset)
		}
	}
	renderTarget(target, hops, c)
	return hops
}

func dashOr(v int) string {
	if v == 0 {
		return "—"
	}
	return strconv.Itoa(v)
}

// --------------------------------------------------------------- main -----

func showUsage() {
	fmt.Fprintf(os.Stderr,
		`mtu_path_test (Go) %s  —  %s
%s

USAGE
    mtu_path_test [options] target [target ...]

OPTIONS
    -file, -f <path>      File with one target per line (# comments allowed)
    -start <int>          Smallest tested size       (default 1300)
    -end <int>            Largest tested size        (default 9000)
    -step <int>           Coarse step above pivot    (default 500)
    -fine-step <int>      Fine step under pivot      (default 1)
    -fine-pivot <int>     Boundary fine ↔ coarse     (default 1500)
    -max-hops <int>       Traceroute hop cap         (default 30)
    -timeout-ms <int>     Per-probe wait in ms       (default 1500)
    -retries <int>        Retries per probe          (default 2)
    -iface <name|ip>      Bind probes to interface name or source IP
    -no-color             Disable ANSI colors
    -no-save              Don't save per-target output to a file
    -out-dir <path>       Directory for saved logs   (default: cwd)
    -out-ext <ext>        Extension for saved logs   (default: log)
    -version, -V          Print version and exit
    -help, -h             Show this help

Both single (-flag) and double (--flag) dash forms are accepted.
`, Version, Author, Repo)
}

func main() {
	c := &config{}
	flag.Usage = showUsage
	flag.StringVar(&c.File, "file", "", "")
	flag.StringVar(&c.File, "f", "", "")
	flag.IntVar(&c.Start, "start", 1300, "")
	flag.IntVar(&c.End, "end", 9000, "")
	flag.IntVar(&c.Step, "step", 500, "")
	flag.IntVar(&c.FineStep, "fine-step", 1, "")
	flag.IntVar(&c.FinePivot, "fine-pivot", 1500, "")
	flag.IntVar(&c.MaxHops, "max-hops", 30, "")
	flag.IntVar(&c.TimeoutMs, "timeout-ms", 1500, "")
	flag.IntVar(&c.Retries, "retries", 2, "")
	flag.StringVar(&c.Iface, "iface", "", "")
	flag.BoolVar(&c.NoColor, "no-color", false, "")
	flag.BoolVar(&c.NoSave, "no-save", false, "")
	flag.StringVar(&c.OutDir, "out-dir", ".", "")
	flag.StringVar(&c.OutExt, "out-ext", "log", "")
	flag.BoolVar(&c.Version, "version", false, "")
	flag.BoolVar(&c.Version, "V", false, "")
	flag.BoolVar(&c.Help, "help", false, "")
	flag.BoolVar(&c.Help, "h", false, "")
	flag.Parse()
	c.Targets = flag.Args()

	if c.Help {
		showUsage()
		return
	}
	if c.Version {
		fmt.Printf("mtu_path_test %s\n", Version)
		return
	}

	// Color setup — disable for non-TTY stdout or --no-color.
	stdoutFi, _ := os.Stdout.Stat()
	stdoutIsTTY := stdoutFi != nil && (stdoutFi.Mode()&os.ModeCharDevice) != 0
	setColors(stdoutIsTTY && !c.NoColor)

	if c.Start < 64 || c.End > 65500 || c.Start >= c.End || c.Step < 1 || c.FineStep < 1 {
		fmt.Fprintln(os.Stderr, "Invalid -start / -end / -step / -fine-step combination")
		os.Exit(2)
	}

	if _, err := exec.LookPath(pingExe); err != nil {
		fmt.Fprintf(os.Stderr, "%sError:%s required tool %q not found on PATH\n", col.Red, col.Reset, pingExe)
		os.Exit(2)
	}
	if _, err := exec.LookPath(trExe); err != nil {
		fmt.Fprintf(os.Stderr, "%sError:%s required tool %q not found on PATH\n", col.Red, col.Reset, trExe)
		os.Exit(2)
	}

	// Resolve --iface to an IPv4 source address.
	ifaceAddr, err := resolveIfaceIPv4(c.Iface)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if ifaceAddr != "" && c.Iface != ifaceAddr {
		fmt.Printf("%sIface '%s' → source %s%s\n", col.Dim, c.Iface, ifaceAddr, col.Reset)
	}

	// Build targets list.
	targets := append([]string{}, c.Targets...)
	if c.File != "" {
		extra, err := loadTargetsFromFile(c.File)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Cannot read -file %q: %s\n", c.File, err)
			os.Exit(2)
		}
		targets = append(targets, extra...)
	}
	// De-dup, preserve order.
	seen := map[string]bool{}
	dedup := []string{}
	for _, t := range targets {
		if !seen[t] {
			seen[t] = true
			dedup = append(dedup, t)
		}
	}
	if len(dedup) == 0 {
		fmt.Fprintln(os.Stderr, "No targets given. Pass one or more positional targets, or -file.")
		showUsage()
		os.Exit(2)
	}

	// Output dir.
	if !c.NoSave {
		if err := os.MkdirAll(c.OutDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "Could not create -out-dir %q: %s — disabling save.\n", c.OutDir, err)
			c.NoSave = true
		}
	}

	runTS := time.Now().Format("20060102_150405")
	savedFiles := []string{}
	results := []targetResult{}

	for _, t := range dedup {
		var logFile *os.File
		if !c.NoSave {
			ext := strings.TrimPrefix(c.OutExt, ".")
			fname := fmt.Sprintf("%s_%s.%s", sanitizeTarget(t), runTS, ext)
			path := filepath.Join(c.OutDir, fname)
			f, err := os.Create(path)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Cannot open log %q: %s\n", path, err)
			} else {
				logFile = f
				fmt.Printf("%s↳ saving to:%s %s\n", col.Dim, col.Reset, path)
				setLogFile(f)
				savedFiles = append(savedFiles, path)
			}
		}
		hops := runOneTarget(t, c, ifaceAddr)
		results = append(results, targetResult{Target: t, Hops: hops})
		if logFile != nil {
			setLogFile(nil)
			logFile.Close()
		}
	}

	renderMultiSummary(results)

	if len(savedFiles) > 0 {
		fmt.Printf("%sSaved logs:%s\n", col.Bold, col.Reset)
		for _, p := range savedFiles {
			fmt.Printf("  %s\n", p)
		}
		fmt.Println()
	}
}
