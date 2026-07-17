//go:build !windows

package main

import "errors"

func querySQLite(_, _ string, _ int) ([][]string, error) {
	return nil, errors.New("SQLite Windows 读取器只能在 Windows 上运行")
}
