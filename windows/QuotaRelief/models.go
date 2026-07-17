package main

import (
	"fmt"
	"math"
	"strings"
	"time"
)

type QuotaWindow struct {
	Name      string
	Remaining int
	ResetAt   time.Time
}

type CodexTask struct {
	ID        string
	Title     string
	Tokens    int64
	UpdatedAt time.Time
	Running   bool
}

type WorkBuddyTask struct {
	ID          string
	Title       string
	LastCredits float64
	AllCredits  float64
	UpdatedAt   time.Time
}

type CodexState struct {
	Plan    string
	Windows []QuotaWindow
	Tasks   []CodexTask
	Error   string
}

type WorkBuddyState struct {
	Remaining *float64
	Total     *float64
	Tasks     []WorkBuddyTask
	Error     string
}

type Snapshot struct {
	Codex     CodexState
	WorkBuddy WorkBuddyState
	UpdatedAt time.Time
}

func (s Snapshot) TrayText() string {
	parts := make([]string, 0, 4)
	if s.WorkBuddy.Remaining != nil {
		parts = append(parts, "WB余"+creditText(*s.WorkBuddy.Remaining))
	}
	for _, window := range s.Codex.Windows {
		if strings.HasPrefix(window.Name, "Spark") {
			parts = append(parts, fmt.Sprintf("S%d%%", window.Remaining))
			continue
		}
		parts = append(parts, fmt.Sprintf("Cx%d%%", window.Remaining))
		break
	}
	running := 0
	for _, task := range s.Codex.Tasks {
		if task.Running {
			running++
		}
	}
	if running > 0 {
		parts = append(parts, fmt.Sprintf("跑%d", running))
	}
	if len(parts) == 0 {
		return "kong的额度焦虑缓解器"
	}
	return strings.Join(parts, "  ")
}

func mergeSnapshot(previous, next Snapshot) Snapshot {
	if len(next.Codex.Windows) == 0 && len(previous.Codex.Windows) > 0 {
		next.Codex.Windows = previous.Codex.Windows
	}
	if len(next.Codex.Tasks) == 0 && len(previous.Codex.Tasks) > 0 {
		next.Codex.Tasks = previous.Codex.Tasks
	}
	if next.WorkBuddy.Remaining == nil {
		next.WorkBuddy.Remaining = previous.WorkBuddy.Remaining
	}
	if next.WorkBuddy.Total == nil {
		next.WorkBuddy.Total = previous.WorkBuddy.Total
	}
	if len(next.WorkBuddy.Tasks) == 0 && len(previous.WorkBuddy.Tasks) > 0 {
		next.WorkBuddy.Tasks = previous.WorkBuddy.Tasks
	}
	return next
}

func shortTitle(value string) string {
	value = strings.Join(strings.Fields(value), " ")
	if value == "" {
		return "未命名任务"
	}
	runes := []rune(value)
	if len(runes) <= 22 {
		return value
	}
	return string(runes[:22]) + "..."
}

func tokenText(tokens int64) string {
	switch {
	case tokens >= 1_000_000:
		value := float64(tokens) / 1_000_000
		if value >= 10 {
			return fmt.Sprintf("%.0fM tok", value)
		}
		return fmt.Sprintf("%.1fM tok", value)
	case tokens >= 1_000:
		value := float64(tokens) / 1_000
		if value >= 10 {
			return fmt.Sprintf("%.0fK tok", value)
		}
		return fmt.Sprintf("%.1fK tok", value)
	default:
		return fmt.Sprintf("%d tok", tokens)
	}
}

func creditText(value float64) string {
	if math.Abs(value-math.Round(value)) < 0.005 {
		return fmt.Sprintf("%.0f", value)
	}
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.2f", value), "0"), ".")
}

func resetText(resetAt time.Time) string {
	if resetAt.IsZero() {
		return "重置时间未知"
	}
	d := time.Until(resetAt)
	if d <= 0 {
		return "即将重置"
	}
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	minutes := int(d.Minutes()) % 60
	if days > 0 {
		return fmt.Sprintf("%d天%d小时", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%d小时%d分", hours, minutes)
	}
	return fmt.Sprintf("%d分", max(1, minutes))
}

func ageText(updatedAt time.Time) string {
	if updatedAt.IsZero() {
		return "时间未知"
	}
	d := time.Since(updatedAt)
	if d < time.Hour {
		return fmt.Sprintf("%d分前", max(1, int(d.Minutes())))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("%d小时前", int(d.Hours()))
	}
	return fmt.Sprintf("%d天前", int(d.Hours()/24))
}
