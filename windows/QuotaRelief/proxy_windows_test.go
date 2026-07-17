//go:build windows

package main

import (
	"net/url"
	"testing"
)

func TestWindowsProxyDiscovery(t *testing.T) {
	target, err := url.Parse("https://chatgpt.com/backend-api/wham/usage")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := windowsProxyForURL(target); err != nil {
		t.Fatalf("Windows 系统代理无法解析: %v", err)
	}
}
