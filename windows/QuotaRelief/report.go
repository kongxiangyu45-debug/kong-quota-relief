package main

import (
	"fmt"
	"html"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func writeReport(snapshot Snapshot) (string, error) {
	path := filepath.Join(os.TempDir(), "kong-quota-relief-report.html")
	content := buildReportHTML(snapshot)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

func buildReportHTML(snapshot Snapshot) string {
	var codexWindows strings.Builder
	for _, window := range snapshot.Codex.Windows {
		fmt.Fprintf(&codexWindows,
			"<tr><td>%s</td><td><b>%d%%</b></td><td>%s</td></tr>",
			html.EscapeString(window.Name), window.Remaining, html.EscapeString(resetText(window.ResetAt)))
	}
	if codexWindows.Len() == 0 {
		codexWindows.WriteString("<tr><td colspan='3'>暂时没有读到 Codex 额度</td></tr>")
	}

	var codexTasks strings.Builder
	for _, task := range snapshot.Codex.Tasks {
		status := "近期"
		if task.Running {
			status = "运行中"
		}
		fmt.Fprintf(&codexTasks,
			"<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
			html.EscapeString(status), html.EscapeString(task.Title), html.EscapeString(tokenText(task.Tokens)), html.EscapeString(ageText(task.UpdatedAt)))
	}
	if codexTasks.Len() == 0 {
		codexTasks.WriteString("<tr><td colspan='4'>暂时没有读到 Codex 任务</td></tr>")
	}

	var workBuddyTasks strings.Builder
	for _, task := range snapshot.WorkBuddy.Tasks {
		fmt.Fprintf(&workBuddyTasks,
			"<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
			html.EscapeString(task.Title), html.EscapeString(creditText(task.LastCredits)), html.EscapeString(creditText(task.AllCredits)), html.EscapeString(ageText(task.UpdatedAt)))
	}
	if workBuddyTasks.Len() == 0 {
		workBuddyTasks.WriteString("<tr><td colspan='4'>暂时没有读到 WorkBuddy 任务</td></tr>")
	}

	remaining := "--"
	total := "--"
	if snapshot.WorkBuddy.Remaining != nil {
		remaining = creditText(*snapshot.WorkBuddy.Remaining)
	}
	if snapshot.WorkBuddy.Total != nil {
		total = creditText(*snapshot.WorkBuddy.Total)
	}
	updated := snapshot.UpdatedAt
	if updated.IsZero() {
		updated = time.Now()
	}

	return fmt.Sprintf(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>kong的额度焦虑缓解器 - 用量报告</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif;margin:0;background:#f4f7f5;color:#17201c;line-height:1.6}
main{max-width:960px;margin:0 auto;padding:36px 20px 60px}h1{font-size:30px;margin:0}h2{font-size:21px;margin:36px 0 12px}.sub{color:#66716c;margin:4px 0 28px}
.card{background:white;border:1px solid #dce3df;border-radius:8px;padding:20px;margin-bottom:18px}.stats{display:flex;gap:28px;flex-wrap:wrap}.stat b{display:block;font-size:28px;color:#087a4b}.stat span{color:#66716c}
table{width:100%%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #edf1ef}th{font-size:13px;color:#66716c}.note{color:#66716c;font-size:14px}
@media(max-width:640px){main{padding:24px 14px}table{font-size:14px;display:block;overflow-x:auto}.card{padding:14px}}
</style></head><body><main>
<h1>kong的额度焦虑缓解器</h1><p class="sub">Windows 本机用量报告 · %s</p>
<h2>Codex 额度</h2><div class="card"><table><thead><tr><th>窗口</th><th>剩余</th><th>重置倒计时</th></tr></thead><tbody>%s</tbody></table>%s</div>
<h2>Codex 近期任务</h2><div class="card"><table><thead><tr><th>状态</th><th>任务</th><th>Token</th><th>时间</th></tr></thead><tbody>%s</tbody></table></div>
<h2>WorkBuddy</h2><div class="card"><div class="stats"><div class="stat"><b>%s</b><span>剩余总积分</span></div><div class="stat"><b>%s</b><span>当前总额度</span></div></div></div>
<div class="card"><table><thead><tr><th>近期任务</th><th>最近一次</th><th>任务累计</th><th>时间</th></tr></thead><tbody>%s</tbody></table></div>
<p class="note">额度与余额来自对应平台的官方接口；任务标题、Token 和积分明细来自本机记录。Token 处理量不等于账单金额。</p>
</main></body></html>`,
		updated.Format("2006-01-02 15:04"),
		codexWindows.String(),
		reportError(snapshot.Codex.Error),
		codexTasks.String(),
		remaining,
		total,
		workBuddyTasks.String())
}

func reportError(message string) string {
	if message == "" {
		return ""
	}
	return "<p class='note'>" + html.EscapeString(message) + "</p>"
}
