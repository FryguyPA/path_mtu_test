package main

import (
	"reflect"
	"strings"
	"testing"
)

// ----- buildSizes ------------------------------------------------------------

func TestBuildSizes_Default(t *testing.T) {
	got := buildSizes(1300, 9000, 500, 1, 1500)
	if len(got) != 216 {
		t.Fatalf("expected 216 samples, got %d", len(got))
	}
	if got[0] != 1300 || got[len(got)-1] != 9000 {
		t.Fatalf("endpoints wrong: first=%d last=%d", got[0], got[len(got)-1])
	}
	// Fine zone is byte-by-byte from 1300 through 1500.
	for i := 1300; i <= 1500; i++ {
		if got[i-1300] != i {
			t.Fatalf("fine zone wrong at index %d: got %d want %d", i-1300, got[i-1300], i)
		}
	}
}

func TestBuildSizes_NoFineZone(t *testing.T) {
	got := buildSizes(1500, 9000, 500, 1, 1500)
	if len(got) != 16 {
		t.Fatalf("expected 16 samples, got %d", len(got))
	}
	if got[0] != 1500 || got[len(got)-1] != 9000 {
		t.Fatalf("endpoints wrong: %v", got)
	}
}

func TestBuildSizes_OnlyFineZone(t *testing.T) {
	got := buildSizes(1300, 1500, 500, 1, 1500)
	if len(got) != 201 || got[0] != 1300 || got[200] != 1500 {
		t.Fatalf("only-fine zone wrong: len=%d first=%d last=%d", len(got), got[0], got[len(got)-1])
	}
}

func TestBuildSizes_CustomFineStep(t *testing.T) {
	got := buildSizes(1300, 9000, 250, 10, 1500)
	if len(got) != 51 {
		t.Fatalf("expected 51 samples, got %d", len(got))
	}
	if got[0] != 1300 || got[1] != 1310 {
		t.Fatalf("custom fine step wrong: %v", got[:5])
	}
}

func TestBuildSizes_EndOffStep(t *testing.T) {
	got := buildSizes(1400, 9216, 500, 1, 1500)
	last := got[len(got)-1]
	if last != 9216 {
		t.Fatalf("end-off-step not appended: last=%d", last)
	}
	// Coarse zone should still hit normal multiples.
	want9000 := false
	for _, v := range got {
		if v == 9000 {
			want9000 = true
			break
		}
	}
	if !want9000 {
		t.Fatalf("9000 missing from coarse zone")
	}
}

// ----- parseFragNeeded -------------------------------------------------------

const macOSFragOut = `PING 8.8.8.8 (8.8.8.8): 4972 data bytes
36 bytes from 10.0.0.5: frag needed and DF set (MTU 1500)

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 0 packets received, 100.0% packet loss
`

const linuxFragOut = `PING 8.8.8.8 (8.8.8.8) 4972(5000) bytes of data.
From 10.0.0.5 icmp_seq=1 Frag needed and DF set (mtu = 1500)

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 0 received, +1 errors, 100% packet loss, time 0ms
`

const winFragOut = `Pinging 8.8.8.8 with 4972 bytes of data:
Reply from 10.0.0.5: Packet needs to be fragmented but DF set.

Ping statistics for 8.8.8.8:
    Packets: Sent = 1, Received = 0, Lost = 1 (100% loss),
`

func TestParseFragNeeded_macOS(t *testing.T) {
	r, m, ok := parseFragNeeded(macOSFragOut)
	if !ok || r != "10.0.0.5" || m != 1500 {
		t.Fatalf("macOS: ok=%v router=%q mtu=%d", ok, r, m)
	}
}

func TestParseFragNeeded_Linux(t *testing.T) {
	r, m, ok := parseFragNeeded(linuxFragOut)
	if !ok || r != "10.0.0.5" || m != 1500 {
		t.Fatalf("Linux: ok=%v router=%q mtu=%d", ok, r, m)
	}
}

func TestParseFragNeeded_Windows(t *testing.T) {
	r, m, ok := parseFragNeeded(winFragOut)
	if !ok {
		t.Fatalf("windows: should match")
	}
	if r != "10.0.0.5" {
		t.Fatalf("windows router wrong: %q", r)
	}
	if m != 0 {
		t.Fatalf("windows MTU should be 0 (not reported); got %d", m)
	}
}

func TestParseFragNeeded_NoMatch(t *testing.T) {
	out := "PING 8.8.8.8: 64 data bytes\n64 bytes from 8.8.8.8: icmp_seq=0 ttl=117 time=12 ms\n"
	if _, _, ok := parseFragNeeded(out); ok {
		t.Fatalf("normal echo reply should not match frag-needed")
	}
}

// ----- successPattern --------------------------------------------------------

func TestSuccessPattern(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{"bsd", "1 packets transmitted, 1 packets received, 0% loss", true},
		{"iputils-short", "1 packets transmitted, 1 received, 0% loss", true},
		{"bytes-from", "64 bytes from 8.8.8.8: icmp_seq=0", true},
		{"windows", "Reply from 8.8.8.8: bytes=32 time=12ms TTL=117", true},
		{"win-frag", "Reply from 10.0.0.5: Packet needs to be fragmented but DF set.", false},
		{"timeout", "Request timeout for icmp_seq 0", false},
		{"empty", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := successPattern(c.in); got != c.want {
				t.Fatalf("got %v want %v for %q", got, c.want, c.in)
			}
		})
	}
}

// ----- bar -------------------------------------------------------------------

func TestBar_ZeroEmpty(t *testing.T) {
	got := bar(0, 1500, 9000, 10)
	if got != strings.Repeat("░", 10) {
		t.Fatalf("zero bar wrong: %q", got)
	}
}

func TestBar_FullFilled(t *testing.T) {
	got := bar(9000, 1500, 9000, 10)
	if got != strings.Repeat("█", 10) {
		t.Fatalf("full bar wrong: %q", got)
	}
}

func TestBar_AboveMaxClamps(t *testing.T) {
	got := bar(20000, 1500, 9000, 10)
	if got != strings.Repeat("█", 10) {
		t.Fatalf("above-max clamp wrong: %q", got)
	}
}

func TestBar_HalfRoughlyHalf(t *testing.T) {
	got := bar(5250, 1500, 9000, 10)
	full := strings.Count(got, "█")
	empty := strings.Count(got, "░")
	if full != 5 || empty != 5 {
		t.Fatalf("half bar wrong: full=%d empty=%d", full, empty)
	}
}

func TestBar_InvalidRange(t *testing.T) {
	got := bar(5000, 1500, 1500, 10)
	if got != strings.Repeat("░", 10) {
		t.Fatalf("invalid range bar wrong: %q", got)
	}
}

// ----- helpers ---------------------------------------------------------------

func TestSanitizeTarget(t *testing.T) {
	cases := map[string]string{
		"8.8.8.8":         "8.8.8.8",
		"www.example.com": "www.example.com",
		"fe80::1%eth0":    "fe80__1_eth0",
		"weird /path?bad": "weird__path_bad",
		"under_score-ok":  "under_score-ok",
		"":                "",
	}
	for in, want := range cases {
		if got := sanitizeTarget(in); got != want {
			t.Fatalf("sanitizeTarget(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStripANSI(t *testing.T) {
	in := "\x1b[1;31mhello\x1b[0m world\n\x1b[Kfoo"
	want := "hello world\nfoo"
	if got := stripANSI(in); got != want {
		t.Fatalf("stripANSI: got %q want %q", got, want)
	}
}

// ----- traceroute parser -----------------------------------------------------

const macOSTracerouteOut = `traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 60 byte packets
 1  router.local (192.168.1.1)  1.234 ms  1.456 ms  1.567 ms
 2  10.0.0.1 (10.0.0.1)  10.123 ms  10.234 ms  10.345 ms
 3  * * *
 4  8.8.8.8 (8.8.8.8)  25.001 ms  24.999 ms  25.123 ms
`

const winTracertOut = `Tracing route to 8.8.8.8 over a maximum of 30 hops

  1     1 ms     1 ms     1 ms  192.168.1.1
  2    10 ms     8 ms    11 ms  10.0.0.1
  3     *        *        *     Request timed out.
  4    25 ms    24 ms    23 ms  8.8.8.8

Trace complete.
`

func TestParseTraceroute_macOS(t *testing.T) {
	hops := parseTraceroute(macOSTracerouteOut)
	want := []Hop{
		{Number: 1, IP: "192.168.1.1", Hostname: "router.local"},
		{Number: 2, IP: "10.0.0.1"},
		{Number: 3, IP: "*", Unreachable: true},
		{Number: 4, IP: "8.8.8.8"},
	}
	if !reflect.DeepEqual(hops, want) {
		t.Fatalf("macOS traceroute parse mismatch:\n got: %#v\nwant: %#v", hops, want)
	}
}

func TestParseTraceroute_Windows(t *testing.T) {
	hops := parseTraceroute(winTracertOut)
	want := []Hop{
		{Number: 1, IP: "192.168.1.1"},
		{Number: 2, IP: "10.0.0.1"},
		{Number: 3, IP: "*", Unreachable: true},
		{Number: 4, IP: "8.8.8.8"},
	}
	if !reflect.DeepEqual(hops, want) {
		t.Fatalf("Windows tracert parse mismatch:\n got: %#v\nwant: %#v", hops, want)
	}
}
