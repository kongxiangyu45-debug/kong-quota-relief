//go:build windows

package main

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

const (
	sqliteOK       = 0
	sqliteRow      = 100
	sqliteDone     = 101
	sqliteOpenRead = 0x00000001
)

var (
	winsqliteDLL     = syscall.NewLazyDLL("winsqlite3.dll")
	sqliteOpenV2     = winsqliteDLL.NewProc("sqlite3_open_v2")
	sqliteClose      = winsqliteDLL.NewProc("sqlite3_close")
	sqlitePrepareV2  = winsqliteDLL.NewProc("sqlite3_prepare_v2")
	sqliteStep       = winsqliteDLL.NewProc("sqlite3_step")
	sqliteFinalize   = winsqliteDLL.NewProc("sqlite3_finalize")
	sqliteColumnText = winsqliteDLL.NewProc("sqlite3_column_text")
)

func querySQLite(path, query string, columnCount int) ([][]string, error) {
	pathBytes, err := syscall.BytePtrFromString(path)
	if err != nil {
		return nil, err
	}
	var database uintptr
	code, _, _ := sqliteOpenV2.Call(
		uintptr(unsafe.Pointer(pathBytes)),
		uintptr(unsafe.Pointer(&database)),
		sqliteOpenRead,
		0)
	if int(code) != sqliteOK || database == 0 {
		return nil, fmt.Errorf("无法打开本地数据库（%d）", code)
	}
	defer sqliteClose.Call(database)

	queryBytes, err := syscall.BytePtrFromString(query)
	if err != nil {
		return nil, err
	}
	var statement uintptr
	code, _, _ = sqlitePrepareV2.Call(
		database,
		uintptr(unsafe.Pointer(queryBytes)),
		^uintptr(0),
		uintptr(unsafe.Pointer(&statement)),
		0)
	if int(code) != sqliteOK || statement == 0 {
		return nil, fmt.Errorf("无法读取本地数据库（%d）", code)
	}
	defer sqliteFinalize.Call(statement)

	rows := [][]string{}
	for {
		code, _, _ = sqliteStep.Call(statement)
		switch int(code) {
		case sqliteRow:
			row := make([]string, columnCount)
			for index := range row {
				pointer, _, _ := sqliteColumnText.Call(statement, uintptr(index))
				row[index] = utf8CString(pointer)
			}
			rows = append(rows, row)
		case sqliteDone:
			return rows, nil
		default:
			return nil, errors.New("读取本地数据库失败")
		}
	}
}

func utf8CString(pointer uintptr) string {
	if pointer == 0 {
		return ""
	}
	bytes := make([]byte, 0, 128)
	for offset := uintptr(0); offset < 4<<20; offset++ {
		value := *(*byte)(unsafe.Add(unsafe.Pointer(pointer), offset))
		if value == 0 {
			break
		}
		bytes = append(bytes, value)
	}
	return string(bytes)
}
