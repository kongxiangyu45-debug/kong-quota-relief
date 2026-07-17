package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestParseWindowsProxySpec(t *testing.T) {
	tests := []struct {
		name   string
		raw    string
		scheme string
		want   string
	}{
		{name: "generic", raw: "127.0.0.1:7890", scheme: "https", want: "http://127.0.0.1:7890"},
		{name: "protocol mapping", raw: "http=127.0.0.1:8080;https=127.0.0.1:7890", scheme: "https", want: "http://127.0.0.1:7890"},
		{name: "socks", raw: "socks=127.0.0.1:1080", scheme: "https", want: "socks5://127.0.0.1:1080"},
		{name: "pac style", raw: "PROXY 127.0.0.1:7890; DIRECT", scheme: "https", want: "http://127.0.0.1:7890"},
		{name: "direct", raw: "DIRECT", scheme: "https", want: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			proxy, err := parseWindowsProxySpec(test.raw, test.scheme)
			if err != nil {
				t.Fatal(err)
			}
			got := ""
			if proxy != nil {
				got = proxy.String()
			}
			if got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestParseCodexUsage(t *testing.T) {
	data := `{
      "plan_type":"pro",
      "rate_limit":{"primary_window":{"used_percent":11,"limit_window_seconds":604800,"reset_at":1784666562}},
      "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1784695320}}}]
    }`
	var payload codexUsagePayload
	if err := json.Unmarshal([]byte(data), &payload); err != nil {
		t.Fatal(err)
	}
	windows := parseCodexUsage(payload)
	if len(windows) != 2 {
		t.Fatalf("expected 2 windows, got %d", len(windows))
	}
	if windows[0].Name != "Codex 一周" || windows[0].Remaining != 89 {
		t.Fatalf("unexpected Codex window: %#v", windows[0])
	}
	if windows[1].Name != "Spark 一周" || windows[1].Remaining != 100 {
		t.Fatalf("unexpected Spark window: %#v", windows[1])
	}
}

func TestFormattingAndReport(t *testing.T) {
	if tokenText(1_561_950) != "1.6M tok" {
		t.Fatalf("unexpected token text: %s", tokenText(1_561_950))
	}
	if creditText(85.40) != "85.4" {
		t.Fatalf("unexpected credit text: %s", creditText(85.40))
	}
	remaining := 4515.0
	total := 8915.0
	report := buildReportHTML(Snapshot{
		Codex:     CodexState{Windows: []QuotaWindow{{Name: "Codex 一周", Remaining: 89, ResetAt: time.Now().Add(time.Hour)}}},
		WorkBuddy: WorkBuddyState{Remaining: &remaining, Total: &total},
		UpdatedAt: time.Now(),
	})
	for _, expected := range []string{"kong的额度焦虑缓解器", "Codex 一周", "4515", "8915"} {
		if !strings.Contains(report, expected) {
			t.Fatalf("report missing %q", expected)
		}
	}
}

func TestWorkBuddyOnlyHidesCodex(t *testing.T) {
	remaining := 1839.89
	snapshot := Snapshot{
		Codex: CodexState{Error: "请先登录 Codex"},
		WorkBuddy: WorkBuddyState{
			Detected:  true,
			Remaining: &remaining,
			Tasks:     []WorkBuddyTask{{Title: "测试任务", LastCredits: 8.06, AllCredits: 146.79}},
		},
	}
	if snapshot.showCodex() {
		t.Fatal("WorkBuddy-only mode should hide Codex")
	}
	if !snapshot.showWorkBuddy() {
		t.Fatal("WorkBuddy-only mode should show WorkBuddy")
	}
	report := buildReportHTML(snapshot)
	if strings.Contains(report, "<h2>Codex") {
		t.Fatal("WorkBuddy-only report should not contain a Codex section")
	}
	for _, expected := range []string{"<h2>WorkBuddy", "1839.89", "测试任务"} {
		if !strings.Contains(report, expected) {
			t.Fatalf("WorkBuddy-only report missing %q", expected)
		}
	}
}

func TestCodexOnlyHidesWorkBuddy(t *testing.T) {
	snapshot := Snapshot{
		Codex:     CodexState{Detected: true, Windows: []QuotaWindow{{Name: "Codex 一周", Remaining: 80}}},
		WorkBuddy: WorkBuddyState{Error: "WorkBuddy 未安装或未登录"},
	}
	if !snapshot.showCodex() {
		t.Fatal("Codex-only mode should show Codex")
	}
	if snapshot.showWorkBuddy() {
		t.Fatal("Codex-only mode should hide WorkBuddy")
	}
	report := buildReportHTML(snapshot)
	if strings.Contains(report, "<h2>WorkBuddy") {
		t.Fatal("Codex-only report should not contain a WorkBuddy section")
	}
}

func TestNoProvidersShowsBothSetupHints(t *testing.T) {
	snapshot := Snapshot{}
	if !snapshot.showCodex() || !snapshot.showWorkBuddy() {
		t.Fatal("empty setup should keep both provider hints visible")
	}
}

func TestParseCreditJSONPreservesLastTurn(t *testing.T) {
	last, total := parseCreditJSON(`{"first":61.54,"second":"86.40"}`)
	if last != 86.40 {
		t.Fatalf("expected last turn 86.40, got %.2f", last)
	}
	if total < 147.939 || total > 147.941 {
		t.Fatalf("expected total 147.94, got %.2f", total)
	}
}
