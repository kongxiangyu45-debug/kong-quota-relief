//go:build windows

package main

import (
	"context"
	"fmt"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	wmDestroy       = 0x0002
	wmClose         = 0x0010
	wmNull          = 0x0000
	wmLButtonUp     = 0x0202
	wmRButtonUp     = 0x0205
	wmApp           = 0x8000
	trayCallback    = wmApp + 1
	refreshComplete = wmApp + 2

	nimAdd     = 0x00000000
	nimModify  = 0x00000001
	nimDelete  = 0x00000002
	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004

	mfString    = 0x00000000
	mfDisabled  = 0x00000002
	mfGrayed    = 0x00000001
	mfSeparator = 0x00000800

	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100

	swShowNormal   = 1
	idiApplication = 32512
)

const (
	commandRefresh = 10
	commandReport  = 11
	commandCodex   = 12
	commandWB      = 13
	commandExit    = 14
)

type point struct {
	X int32
	Y int32
}

type message struct {
	HWnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   point
	Private uint32
}

type windowClassEx struct {
	Size        uint32
	Style       uint32
	WndProc     uintptr
	ClassExtra  int32
	WindowExtra int32
	Instance    uintptr
	Icon        uintptr
	Cursor      uintptr
	Background  uintptr
	MenuName    *uint16
	ClassName   *uint16
	SmallIcon   uintptr
}

type guid struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

type notifyIconData struct {
	Size             uint32
	Window           uintptr
	ID               uint32
	Flags            uint32
	CallbackMessage  uint32
	Icon             uintptr
	Tip              [128]uint16
	State            uint32
	StateMask        uint32
	Info             [256]uint16
	TimeoutOrVersion uint32
	InfoTitle        [64]uint16
	InfoFlags        uint32
	GUID             guid
	BalloonIcon      uintptr
}

type menuAction struct {
	URL  string
	Exit bool
}

type trayApplication struct {
	window     uintptr
	icon       uintptr
	mu         sync.RWMutex
	snapshot   Snapshot
	refreshing bool
	closed     chan struct{}
	closeOnce  sync.Once
}

var activeTray *trayApplication

var (
	user32              = syscall.NewLazyDLL("user32.dll")
	shell32             = syscall.NewLazyDLL("shell32.dll")
	kernel32Tray        = syscall.NewLazyDLL("kernel32.dll")
	registerClassExW    = user32.NewProc("RegisterClassExW")
	createWindowExW     = user32.NewProc("CreateWindowExW")
	defWindowProcW      = user32.NewProc("DefWindowProcW")
	destroyWindow       = user32.NewProc("DestroyWindow")
	getMessageW         = user32.NewProc("GetMessageW")
	translateMessage    = user32.NewProc("TranslateMessage")
	dispatchMessageW    = user32.NewProc("DispatchMessageW")
	postQuitMessage     = user32.NewProc("PostQuitMessage")
	postMessageW        = user32.NewProc("PostMessageW")
	createPopupMenu     = user32.NewProc("CreatePopupMenu")
	appendMenuW         = user32.NewProc("AppendMenuW")
	destroyMenu         = user32.NewProc("DestroyMenu")
	getCursorPos        = user32.NewProc("GetCursorPos")
	setForegroundWindow = user32.NewProc("SetForegroundWindow")
	trackPopupMenu      = user32.NewProc("TrackPopupMenu")
	loadIconW           = user32.NewProc("LoadIconW")
	messageBoxW         = user32.NewProc("MessageBoxW")
	shellNotifyIconW    = shell32.NewProc("Shell_NotifyIconW")
	shellExecuteW       = shell32.NewProc("ShellExecuteW")
	getModuleHandleW    = kernel32Tray.NewProc("GetModuleHandleW")
)

func runTrayApplication() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	application := &trayApplication{closed: make(chan struct{})}
	activeTray = application
	if err := application.createWindow(); err != nil {
		return err
	}
	defer application.removeTrayIcon()
	application.addTrayIcon()
	go application.refresh()
	go application.refreshLoop()

	var msg message
	for {
		result, _, callErr := getMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(result) == -1 {
			return callErr
		}
		if result == 0 {
			return nil
		}
		translateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		dispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

func (a *trayApplication) createWindow() error {
	instance, _, _ := getModuleHandleW.Call(0)
	className, _ := syscall.UTF16PtrFromString("KongQuotaReliefTrayWindow")
	windowName, _ := syscall.UTF16PtrFromString("kong的额度焦虑缓解器")
	icon, _, _ := loadIconW.Call(0, idiApplication)
	a.icon = icon
	class := windowClassEx{
		Size:      uint32(unsafe.Sizeof(windowClassEx{})),
		WndProc:   syscall.NewCallback(trayWindowProc),
		Instance:  instance,
		Icon:      icon,
		ClassName: className,
		SmallIcon: icon,
	}
	registered, _, _ := registerClassExW.Call(uintptr(unsafe.Pointer(&class)))
	if registered == 0 {
		return fmt.Errorf("无法注册 Windows 托盘窗口")
	}
	window, _, _ := createWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(windowName)),
		0,
		0, 0, 0, 0,
		0, 0, instance, 0)
	if window == 0 {
		return fmt.Errorf("无法创建 Windows 托盘窗口")
	}
	a.window = window
	return nil
}

func trayWindowProc(window uintptr, message uint32, wParam, lParam uintptr) uintptr {
	application := activeTray
	if application == nil {
		result, _, _ := defWindowProcW.Call(window, uintptr(message), wParam, lParam)
		return result
	}
	switch message {
	case trayCallback:
		switch uint32(lParam) {
		case wmLButtonUp, wmRButtonUp:
			application.showMenu()
		}
		return 0
	case refreshComplete:
		application.updateTrayIcon()
		return 0
	case wmClose:
		destroyWindow.Call(window)
		return 0
	case wmDestroy:
		application.closeOnce.Do(func() { close(application.closed) })
		postQuitMessage.Call(0)
		return 0
	default:
		result, _, _ := defWindowProcW.Call(window, uintptr(message), wParam, lParam)
		return result
	}
}

func (a *trayApplication) refreshLoop() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			a.refresh()
		case <-a.closed:
			return
		}
	}
}

func (a *trayApplication) refresh() {
	a.mu.Lock()
	if a.refreshing {
		a.mu.Unlock()
		return
	}
	a.refreshing = true
	a.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 22*time.Second)
	next := loadSnapshot(ctx)
	cancel()

	a.mu.Lock()
	a.snapshot = mergeSnapshot(a.snapshot, next)
	a.refreshing = false
	a.mu.Unlock()
	postMessageW.Call(a.window, refreshComplete, 0, 0)
}

func (a *trayApplication) currentSnapshot() (Snapshot, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.snapshot, a.refreshing
}

func (a *trayApplication) iconData() notifyIconData {
	snapshot, refreshing := a.currentSnapshot()
	tooltip := snapshot.TrayText()
	if refreshing {
		tooltip += "  刷新中"
	}
	data := notifyIconData{
		Window:          a.window,
		ID:              1,
		Flags:           nifMessage | nifIcon | nifTip,
		CallbackMessage: trayCallback,
		Icon:            a.icon,
	}
	data.Size = uint32(unsafe.Sizeof(data))
	copyUTF16(data.Tip[:], tooltip)
	return data
}

func (a *trayApplication) addTrayIcon() {
	data := a.iconData()
	shellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&data)))
}

func (a *trayApplication) updateTrayIcon() {
	data := a.iconData()
	shellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&data)))
}

func (a *trayApplication) removeTrayIcon() {
	data := a.iconData()
	shellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&data)))
}

func (a *trayApplication) showMenu() {
	menu, _, _ := createPopupMenu.Call()
	if menu == 0 {
		return
	}
	defer destroyMenu.Call(menu)
	snapshot, refreshing := a.currentSnapshot()
	actions := map[uint32]menuAction{}
	addDisabledMenu(menu, "kong的额度焦虑缓解器")
	addSeparator(menu)

	showCodex := snapshot.showCodex()
	showWorkBuddy := snapshot.showWorkBuddy()
	providerAdded := false
	if showCodex {
		plan := stringsOr(snapshot.Codex.Plan, "当前账号")
		addDisabledMenu(menu, "Codex · "+plan)
		for _, window := range snapshot.Codex.Windows {
			addDisabledMenu(menu, fmt.Sprintf("  %s  %d%% · %s", window.Name, window.Remaining, resetText(window.ResetAt)))
		}
		if len(snapshot.Codex.Windows) == 0 {
			addDisabledMenu(menu, "  "+stringsOr(snapshot.Codex.Error, "暂时没有额度数据"))
		}
		for index, task := range snapshot.Codex.Tasks {
			command := uint32(1000 + index)
			status := "近"
			if task.Running {
				status = "跑"
			}
			addMenu(menu, command, fmt.Sprintf("%s  %s · %s · %s", status, task.Title, tokenText(task.Tokens), ageText(task.UpdatedAt)), true)
			actions[command] = menuAction{URL: "codex://threads/" + task.ID}
		}
		providerAdded = true
	}

	if showWorkBuddy {
		if providerAdded {
			addSeparator(menu)
		}
		addDisabledMenu(menu, "WorkBuddy")
		if snapshot.WorkBuddy.Remaining != nil {
			balance := "  剩余 " + creditText(*snapshot.WorkBuddy.Remaining) + " 积分"
			if snapshot.WorkBuddy.Total != nil {
				balance += " / 总额度 " + creditText(*snapshot.WorkBuddy.Total)
			}
			addDisabledMenu(menu, balance)
		} else {
			addDisabledMenu(menu, "  "+stringsOr(snapshot.WorkBuddy.Error, "暂时没有余额数据"))
		}
		for index, task := range snapshot.WorkBuddy.Tasks {
			command := uint32(2000 + index)
			addMenu(menu, command, fmt.Sprintf("%s · 最近 %s · 累计 %s", task.Title, creditText(task.LastCredits), creditText(task.AllCredits)), true)
			actions[command] = menuAction{URL: "workbuddy://chat/" + task.ID}
		}
	}

	addSeparator(menu)
	refreshTitle := "刷新"
	if refreshing {
		refreshTitle = "正在刷新..."
	}
	addMenu(menu, commandRefresh, refreshTitle, !refreshing)
	addMenu(menu, commandReport, "生成用量报告", true)
	if showCodex {
		addMenu(menu, commandCodex, "打开 Codex", true)
	}
	if showWorkBuddy {
		addMenu(menu, commandWB, "打开 WorkBuddy", true)
	}
	addSeparator(menu)
	addMenu(menu, commandExit, "退出", true)

	var cursor point
	getCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	setForegroundWindow.Call(a.window)
	selected, _, _ := trackPopupMenu.Call(menu, tpmRightButton|tpmReturnCmd, uintptr(cursor.X), uintptr(cursor.Y), 0, a.window, 0)
	postMessageW.Call(a.window, wmNull, 0, 0)
	a.handleCommand(uint32(selected), actions)
}

func (a *trayApplication) handleCommand(command uint32, actions map[uint32]menuAction) {
	if action, ok := actions[command]; ok {
		openTarget(action.URL)
		return
	}
	switch command {
	case commandRefresh:
		go a.refresh()
	case commandReport:
		snapshot, _ := a.currentSnapshot()
		path, err := writeReport(snapshot)
		if err != nil {
			showError("生成报告失败：" + err.Error())
			return
		}
		openTarget(path)
	case commandCodex:
		openTarget("codex://")
	case commandWB:
		openTarget("workbuddy://home")
	case commandExit:
		postMessageW.Call(a.window, wmClose, 0, 0)
	}
}

func addMenu(menu uintptr, command uint32, title string, enabled bool) {
	flags := uintptr(mfString)
	if !enabled {
		flags |= mfDisabled | mfGrayed
	}
	titlePointer, _ := syscall.UTF16PtrFromString(title)
	appendMenuW.Call(menu, flags, uintptr(command), uintptr(unsafe.Pointer(titlePointer)))
}

func addDisabledMenu(menu uintptr, title string) {
	addMenu(menu, 0, title, false)
}

func addSeparator(menu uintptr) {
	appendMenuW.Call(menu, mfSeparator, 0, 0)
}

func openTarget(target string) {
	operation, _ := syscall.UTF16PtrFromString("open")
	value, _ := syscall.UTF16PtrFromString(filepath.Clean(target))
	if stringsHasScheme(target) {
		value, _ = syscall.UTF16PtrFromString(target)
	}
	shellExecuteW.Call(0, uintptr(unsafe.Pointer(operation)), uintptr(unsafe.Pointer(value)), 0, 0, swShowNormal)
}

func stringsHasScheme(value string) bool {
	for index, char := range value {
		if char == ':' {
			return index > 0
		}
		if char == '/' || char == '\\' {
			return false
		}
	}
	return false
}

func stringsOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func copyUTF16(destination []uint16, value string) {
	encoded := utf16.Encode([]rune(value))
	if len(encoded) >= len(destination) {
		encoded = encoded[:len(destination)-1]
	}
	copy(destination, encoded)
}

func showError(message string) {
	title, _ := syscall.UTF16PtrFromString("kong的额度焦虑缓解器")
	text, _ := syscall.UTF16PtrFromString(message)
	messageBoxW.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
}
