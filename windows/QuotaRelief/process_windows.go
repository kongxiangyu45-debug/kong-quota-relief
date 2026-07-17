//go:build windows

package main

import "syscall"

const processQueryLimitedInformation = 0x1000

var (
	kernel32Process = syscall.NewLazyDLL("kernel32.dll")
	openProcess     = kernel32Process.NewProc("OpenProcess")
	closeHandle     = kernel32Process.NewProc("CloseHandle")
)

func processExists(pid int) bool {
	handle, _, _ := openProcess.Call(processQueryLimitedInformation, 0, uintptr(pid))
	if handle == 0 {
		return false
	}
	closeHandle.Call(handle)
	return true
}
