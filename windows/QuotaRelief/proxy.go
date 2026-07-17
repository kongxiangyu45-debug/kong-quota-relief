package main

import (
	"net/http"
	"net/url"
	"strings"
	"time"
)

func newProviderHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = platformProxy
	return &http.Client{
		Timeout:   15 * time.Second,
		Transport: transport,
	}
}

func parseWindowsProxySpec(raw, targetScheme string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	targetScheme = strings.ToLower(strings.TrimSpace(targetScheme))
	keyed := map[string]string{}
	unkeyed := make([]string, 0, 2)
	for _, part := range strings.Split(raw, ";") {
		part = strings.TrimSpace(part)
		if part == "" || strings.EqualFold(part, "DIRECT") {
			continue
		}
		if key, value, ok := strings.Cut(part, "="); ok {
			keyed[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
			continue
		}
		unkeyed = append(unkeyed, part)
	}

	value := keyed[targetScheme]
	isSOCKS := false
	if value == "" {
		for _, key := range []string{"socks", "socks5"} {
			if keyed[key] != "" {
				value = keyed[key]
				isSOCKS = true
				break
			}
		}
	}
	if value == "" && len(unkeyed) > 0 {
		value = unkeyed[0]
	}
	if value == "" {
		return nil, nil
	}

	upper := strings.ToUpper(value)
	for _, prefix := range []string{"PROXY ", "HTTP ", "HTTPS "} {
		if strings.HasPrefix(upper, prefix) {
			value = strings.TrimSpace(value[len(prefix):])
			upper = strings.ToUpper(value)
			break
		}
	}
	for _, prefix := range []string{"SOCKS5 ", "SOCKS "} {
		if strings.HasPrefix(upper, prefix) {
			value = strings.TrimSpace(value[len(prefix):])
			isSOCKS = true
			break
		}
	}
	if strings.EqualFold(value, "DIRECT") || value == "" {
		return nil, nil
	}
	if !strings.Contains(value, "://") {
		if isSOCKS {
			value = "socks5://" + value
		} else {
			value = "http://" + value
		}
	}
	return url.Parse(value)
}
