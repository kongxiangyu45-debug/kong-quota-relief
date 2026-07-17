//go:build windows

package main

import (
	"errors"
	"net/http"
	"net/url"
	"syscall"
	"unsafe"
)

const (
	winHTTPAccessTypeNoProxy     = 1
	winHTTPAccessTypeNamedProxy  = 3
	winHTTPAutoProxyAutoDetect   = 0x00000001
	winHTTPAutoProxyConfigURL    = 0x00000002
	winHTTPAutoDetectTypeDHCP    = 0x00000001
	winHTTPAutoDetectTypeDNSName = 0x00000002
)

var (
	winHTTPDLL              = syscall.NewLazyDLL("winhttp.dll")
	winHTTPGetIEProxyConfig = winHTTPDLL.NewProc("WinHttpGetIEProxyConfigForCurrentUser")
	winHTTPOpen             = winHTTPDLL.NewProc("WinHttpOpen")
	winHTTPGetProxyForURL   = winHTTPDLL.NewProc("WinHttpGetProxyForUrl")
	winHTTPCloseHandle      = winHTTPDLL.NewProc("WinHttpCloseHandle")
	kernel32ProxyDLL        = syscall.NewLazyDLL("kernel32.dll")
	globalFree              = kernel32ProxyDLL.NewProc("GlobalFree")
)

type winHTTPCurrentUserIEProxyConfig struct {
	AutoDetect    uint32
	Padding       uint32
	AutoConfigURL *uint16
	Proxy         *uint16
	ProxyBypass   *uint16
}

type winHTTPAutoProxyOptions struct {
	Flags                 uint32
	AutoDetectFlags       uint32
	AutoConfigURL         *uint16
	Reserved              uintptr
	ReservedValue         uint32
	AutoLogonIfChallenged int32
}

type winHTTPProxyInfo struct {
	AccessType  uint32
	Padding     uint32
	Proxy       *uint16
	ProxyBypass *uint16
}

type windowsIEProxyConfig struct {
	AutoDetect    bool
	AutoConfigURL string
	Proxy         string
}

func platformProxy(request *http.Request) (*url.URL, error) {
	proxy, err := http.ProxyFromEnvironment(request)
	if err != nil || proxy != nil {
		return proxy, err
	}
	return windowsProxyForURL(request.URL)
}

func windowsProxyForURL(target *url.URL) (*url.URL, error) {
	config, err := currentWindowsIEProxyConfig()
	if err != nil {
		return nil, nil
	}
	if config.AutoDetect || config.AutoConfigURL != "" {
		proxy, resolved, autoErr := resolveWindowsAutoProxy(target, config)
		if autoErr == nil && resolved {
			return proxy, nil
		}
	}
	return parseWindowsProxySpec(config.Proxy, target.Scheme)
}

func currentWindowsIEProxyConfig() (windowsIEProxyConfig, error) {
	var raw winHTTPCurrentUserIEProxyConfig
	result, _, callErr := winHTTPGetIEProxyConfig.Call(uintptr(unsafe.Pointer(&raw)))
	if result == 0 {
		return windowsIEProxyConfig{}, callErr
	}
	defer freeGlobalUTF16(raw.AutoConfigURL)
	defer freeGlobalUTF16(raw.Proxy)
	defer freeGlobalUTF16(raw.ProxyBypass)
	return windowsIEProxyConfig{
		AutoDetect:    raw.AutoDetect != 0,
		AutoConfigURL: utf16PointerString(raw.AutoConfigURL),
		Proxy:         utf16PointerString(raw.Proxy),
	}, nil
}

func resolveWindowsAutoProxy(target *url.URL, config windowsIEProxyConfig) (*url.URL, bool, error) {
	userAgent, _ := syscall.UTF16PtrFromString("kong-quota-relief")
	session, _, callErr := winHTTPOpen.Call(
		uintptr(unsafe.Pointer(userAgent)),
		winHTTPAccessTypeNoProxy,
		0,
		0,
		0,
	)
	if session == 0 {
		return nil, false, callErr
	}
	defer winHTTPCloseHandle.Call(session)

	options := winHTTPAutoProxyOptions{AutoLogonIfChallenged: 1}
	var autoConfigURL *uint16
	if config.AutoDetect {
		options.Flags |= winHTTPAutoProxyAutoDetect
		options.AutoDetectFlags = winHTTPAutoDetectTypeDHCP | winHTTPAutoDetectTypeDNSName
	}
	if config.AutoConfigURL != "" {
		autoConfigURL, _ = syscall.UTF16PtrFromString(config.AutoConfigURL)
		options.Flags |= winHTTPAutoProxyConfigURL
		options.AutoConfigURL = autoConfigURL
	}
	if options.Flags == 0 {
		return nil, false, errors.New("没有自动代理设置")
	}

	targetURL, _ := syscall.UTF16PtrFromString(target.String())
	var info winHTTPProxyInfo
	result, _, callErr := winHTTPGetProxyForURL.Call(
		session,
		uintptr(unsafe.Pointer(targetURL)),
		uintptr(unsafe.Pointer(&options)),
		uintptr(unsafe.Pointer(&info)),
	)
	if result == 0 {
		return nil, false, callErr
	}
	defer freeGlobalUTF16(info.Proxy)
	defer freeGlobalUTF16(info.ProxyBypass)
	if info.AccessType != winHTTPAccessTypeNamedProxy || info.Proxy == nil {
		return nil, true, nil
	}
	proxy, err := parseWindowsProxySpec(utf16PointerString(info.Proxy), target.Scheme)
	return proxy, true, err
}

func utf16PointerString(value *uint16) string {
	if value == nil {
		return ""
	}
	units := make([]uint16, 0, 128)
	for index := uintptr(0); index < 32*1024; index++ {
		unit := *(*uint16)(unsafe.Add(unsafe.Pointer(value), index*2))
		if unit == 0 {
			break
		}
		units = append(units, unit)
	}
	return syscall.UTF16ToString(units)
}

func freeGlobalUTF16(value *uint16) {
	if value != nil {
		globalFree.Call(uintptr(unsafe.Pointer(value)))
	}
}
