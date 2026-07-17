package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var providerHTTPClient = newProviderHTTPClient()

type codexAuthFile struct {
	AuthMode string `json:"auth_mode"`
	Tokens   struct {
		AccessToken string `json:"access_token"`
		AccountID   string `json:"account_id"`
	} `json:"tokens"`
}

type codexWindowPayload struct {
	UsedPercent       float64 `json:"used_percent"`
	LimitWindowSecond int64   `json:"limit_window_seconds"`
	ResetAt           int64   `json:"reset_at"`
}

type codexRateLimitPayload struct {
	Primary   *codexWindowPayload `json:"primary_window"`
	Secondary *codexWindowPayload `json:"secondary_window"`
}

type codexUsagePayload struct {
	PlanType string                   `json:"plan_type"`
	Rate     codexRateLimitPayload    `json:"rate_limit"`
	Extra    []codexExtraLimitPayload `json:"additional_rate_limits"`
}

type codexExtraLimitPayload struct {
	Name string                `json:"limit_name"`
	Rate codexRateLimitPayload `json:"rate_limit"`
}

type workBuddyAuthFile struct {
	Auth struct {
		AccessToken string `json:"accessToken"`
		Domain      string `json:"domain"`
	} `json:"auth"`
	Account struct {
		UID          string `json:"uid"`
		EnterpriseID string `json:"enterpriseId"`
	} `json:"account"`
}

func loadSnapshot(ctx context.Context) Snapshot {
	var result Snapshot
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		result.Codex = loadCodexState(ctx)
	}()
	go func() {
		defer wg.Done()
		result.WorkBuddy = loadWorkBuddyState(ctx)
	}()
	wg.Wait()
	result.UpdatedAt = time.Now()
	return result
}

func loadCodexState(ctx context.Context) CodexState {
	state := CodexState{}
	windows, plan, err := fetchCodexWindows(ctx)
	if err != nil {
		state.Error = err.Error()
	} else {
		state.Windows = windows
		state.Plan = plan
	}
	tasks, taskErr := fetchCodexTasks(5)
	if taskErr == nil {
		state.Tasks = tasks
	} else if state.Error == "" {
		state.Error = taskErr.Error()
	}
	return state
}

func fetchCodexWindows(ctx context.Context) ([]QuotaWindow, string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, "", err
	}
	data, err := os.ReadFile(filepath.Join(home, ".codex", "auth.json"))
	if err != nil {
		return nil, "", errors.New("请先登录 Codex")
	}
	var auth codexAuthFile
	if err := json.Unmarshal(data, &auth); err != nil || auth.Tokens.AccessToken == "" {
		return nil, "", errors.New("Codex 登录信息不可用")
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://chatgpt.com/backend-api/wham/usage", nil)
	if err != nil {
		return nil, "", err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+auth.Tokens.AccessToken)
	if auth.Tokens.AccountID != "" {
		request.Header.Set("ChatGPT-Account-Id", auth.Tokens.AccountID)
	}
	response, err := providerHTTPClient.Do(request)
	if err != nil {
		return nil, "", errors.New("Codex 额度连接失败，请检查系统代理")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("Codex 额度接口返回 %d", response.StatusCode)
	}
	var payload codexUsagePayload
	if err := json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(&payload); err != nil {
		return nil, "", errors.New("Codex 额度格式无法识别")
	}
	return parseCodexUsage(payload), payload.PlanType, nil
}

func parseCodexUsage(payload codexUsagePayload) []QuotaWindow {
	windows := make([]QuotaWindow, 0, 4)
	appendRate := func(prefix string, rate codexRateLimitPayload) {
		if rate.Primary != nil {
			windows = append(windows, quotaWindow(prefix, *rate.Primary))
		}
		if rate.Secondary != nil {
			windows = append(windows, quotaWindow(prefix, *rate.Secondary))
		}
	}
	appendRate("Codex", payload.Rate)
	for _, extra := range payload.Extra {
		name := "其他额度"
		if strings.Contains(strings.ToLower(extra.Name), "spark") {
			name = "Spark"
		} else if strings.TrimSpace(extra.Name) != "" {
			name = extra.Name
		}
		appendRate(name, extra.Rate)
	}
	return windows
}

func quotaWindow(prefix string, value codexWindowPayload) QuotaWindow {
	name := prefix + windowName(value.LimitWindowSecond)
	remaining := int(100 - value.UsedPercent + 0.5)
	if remaining < 0 {
		remaining = 0
	}
	if remaining > 100 {
		remaining = 100
	}
	return QuotaWindow{
		Name:      name,
		Remaining: remaining,
		ResetAt:   time.Unix(value.ResetAt, 0),
	}
}

func windowName(seconds int64) string {
	switch {
	case seconds <= 6*60*60:
		return " 5小时"
	case seconds <= 8*24*60*60:
		return " 一周"
	default:
		return " 额度"
	}
}

func fetchCodexTasks(limit int) ([]CodexTask, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	databasePath, err := newestStateDatabase(filepath.Join(home, ".codex"))
	if err != nil {
		return nil, errors.New("未找到 Codex 本地任务")
	}
	query := fmt.Sprintf(`
select
  id,
  coalesce(nullif(trim(title), ''), nullif(trim(preview), ''), '未命名任务'),
  cast(coalesce(tokens_used, 0) as text),
  cast(coalesce(nullif(recency_at_ms, 0), nullif(updated_at_ms, 0), updated_at * 1000, 0) as text)
from threads
where archived = 0
order by coalesce(nullif(recency_at_ms, 0), nullif(updated_at_ms, 0), updated_at * 1000, 0) desc
limit %d;`, limit)
	rows, err := querySQLite(databasePath, query, 4)
	if err != nil {
		return nil, err
	}
	live := liveCodexThreads(filepath.Join(home, ".codex", "process_manager", "chat_processes.json"))
	result := make([]CodexTask, 0, len(rows))
	for _, row := range rows {
		if len(row) < 4 {
			continue
		}
		tokens, _ := strconv.ParseInt(row[2], 10, 64)
		activityMS, _ := strconv.ParseInt(row[3], 10, 64)
		result = append(result, CodexTask{
			ID:        row[0],
			Title:     shortTitle(row[1]),
			Tokens:    tokens,
			UpdatedAt: time.UnixMilli(activityMS),
			Running:   live[row[0]],
		})
	}
	return result, nil
}

func newestStateDatabase(codexHome string) (string, error) {
	paths, _ := filepath.Glob(filepath.Join(codexHome, "state_*.sqlite"))
	if len(paths) == 0 {
		return "", os.ErrNotExist
	}
	sort.Slice(paths, func(i, j int) bool {
		left, _ := os.Stat(paths[i])
		right, _ := os.Stat(paths[j])
		if left == nil || right == nil {
			return paths[i] > paths[j]
		}
		return left.ModTime().After(right.ModTime())
	})
	return paths[0], nil
}

func liveCodexThreads(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]bool{}
	}
	var entries []struct {
		ConversationID string          `json:"conversationId"`
		OSPID          json.RawMessage `json:"osPid"`
		ProcessID      json.RawMessage `json:"processId"`
	}
	if json.Unmarshal(data, &entries) != nil {
		return map[string]bool{}
	}
	result := map[string]bool{}
	for _, entry := range entries {
		pid := rawInt(entry.OSPID)
		if pid == 0 {
			pid = rawInt(entry.ProcessID)
		}
		if entry.ConversationID != "" && pid > 0 && processExists(pid) {
			result[entry.ConversationID] = true
		}
	}
	return result
}

func rawInt(value json.RawMessage) int {
	if len(value) == 0 || bytes.Equal(value, []byte("null")) {
		return 0
	}
	var number int
	if json.Unmarshal(value, &number) == nil {
		return number
	}
	var text string
	if json.Unmarshal(value, &text) == nil {
		number, _ = strconv.Atoi(text)
	}
	return number
}

func loadWorkBuddyState(ctx context.Context) WorkBuddyState {
	state := WorkBuddyState{}
	remaining, total, err := fetchWorkBuddyBalance(ctx)
	if err != nil {
		state.Error = err.Error()
	} else {
		state.Remaining = &remaining
		state.Total = &total
	}
	tasks, taskErr := fetchWorkBuddyTasks(5)
	if taskErr == nil {
		state.Tasks = tasks
	} else if state.Error == "" {
		state.Error = taskErr.Error()
	}
	return state
}

func fetchWorkBuddyBalance(ctx context.Context) (float64, float64, error) {
	authPath := findWorkBuddyAuthPath()
	if authPath == "" {
		return 0, 0, errors.New("WorkBuddy 未安装或未登录")
	}
	data, err := os.ReadFile(authPath)
	if err != nil {
		return 0, 0, errors.New("WorkBuddy 登录信息不可用")
	}
	var auth workBuddyAuthFile
	if json.Unmarshal(data, &auth) != nil || auth.Auth.AccessToken == "" || auth.Account.UID == "" {
		return 0, 0, errors.New("WorkBuddy 登录信息不可用")
	}
	body, _ := json.Marshal(map[string]any{
		"PageNumber":                 1,
		"PageSize":                   100,
		"ProductCode":                "p_tcaca",
		"Status":                     []int{0, 3},
		"PackageStartTimeRangeBegin": "2024-12-01 21:25:00",
		"PackageStartTimeRangeEnd":   time.Now().Format("2006-01-02 15:04:05"),
	})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://copilot.tencent.com/v2/billing/meter/get-user-resource", bytes.NewReader(body))
	if err != nil {
		return 0, 0, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+auth.Auth.AccessToken)
	request.Header.Set("X-User-Id", auth.Account.UID)
	if auth.Auth.Domain != "" {
		request.Header.Set("X-Domain", auth.Auth.Domain)
	}
	if auth.Account.EnterpriseID != "" {
		request.Header.Set("X-Enterprise-Id", auth.Account.EnterpriseID)
		request.Header.Set("X-Tenant-Id", auth.Account.EnterpriseID)
	}
	response, err := providerHTTPClient.Do(request)
	if err != nil {
		return 0, 0, errors.New("WorkBuddy 余额刷新失败")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return 0, 0, fmt.Errorf("WorkBuddy 余额接口返回 %d", response.StatusCode)
	}
	var payload struct {
		Data struct {
			Response struct {
				Data struct {
					Accounts []map[string]any `json:"Accounts"`
				} `json:"Data"`
			} `json:"Response"`
		} `json:"data"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 4<<20))
	decoder.UseNumber()
	if decoder.Decode(&payload) != nil {
		return 0, 0, errors.New("WorkBuddy 余额格式无法识别")
	}
	remaining := 0.0
	total := 0.0
	for _, account := range payload.Data.Response.Data.Accounts {
		remaining += anyFloat(account["CycleCapacityRemainPrecise"])
		total += anyFloat(account["CycleCapacitySizePrecise"])
	}
	return remaining, total, nil
}

func fetchWorkBuddyTasks(limit int) ([]WorkBuddyTask, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	databasePath := filepath.Join(home, ".workbuddy", "workbuddy.db")
	if _, err := os.Stat(databasePath); err != nil {
		return nil, errors.New("未找到 WorkBuddy 本地任务")
	}
	query := fmt.Sprintf(`
select
  s.id,
  coalesce(nullif(trim(s.custom_title), ''), nullif(trim(s.title), ''), '未命名任务'),
  coalesce(u.credit_json, '{}'),
  cast(coalesce(nullif(u.updated_at, 0), nullif(s.last_activity_at, 0), s.updated_at, 0) as text)
from sessions s
left join session_usage u on u.session_id = s.id
where s.deleted_at is null
order by coalesce(nullif(u.updated_at, 0), nullif(s.last_activity_at, 0), s.updated_at, 0) desc
limit %d;`, limit)
	rows, err := querySQLite(databasePath, query, 4)
	if err != nil {
		return nil, err
	}
	result := make([]WorkBuddyTask, 0, len(rows))
	for _, row := range rows {
		if len(row) < 4 {
			continue
		}
		lastCredits, allCredits := parseCreditJSON(row[2])
		activityMS, _ := strconv.ParseInt(row[3], 10, 64)
		result = append(result, WorkBuddyTask{
			ID:          row[0],
			Title:       shortTitle(row[1]),
			LastCredits: lastCredits,
			AllCredits:  allCredits,
			UpdatedAt:   time.UnixMilli(activityMS),
		})
	}
	return result, nil
}

func parseCreditJSON(value string) (last float64, total float64) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return 0, 0
	}
	for decoder.More() {
		if _, err := decoder.Token(); err != nil {
			return last, total
		}
		var amount any
		if decoder.Decode(&amount) != nil {
			return last, total
		}
		last = anyFloat(amount)
		total += last
	}
	return last, total
}

func findWorkBuddyAuthPath() string {
	candidates := []string{}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, "AppData", "Local", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"))
	}
	if appData := os.Getenv("APPDATA"); appData != "" {
		candidates = append(candidates, filepath.Join(appData, "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"))
	}
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		candidates = append(candidates, filepath.Join(localAppData, "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"))
	}
	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}

func anyFloat(value any) float64 {
	switch typed := value.(type) {
	case json.Number:
		result, _ := typed.Float64()
		return result
	case float64:
		return typed
	case string:
		result, _ := strconv.ParseFloat(typed, 64)
		return result
	default:
		return 0
	}
}
