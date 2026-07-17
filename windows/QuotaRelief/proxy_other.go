//go:build !windows

package main

import (
	"net/http"
	"net/url"
)

func platformProxy(request *http.Request) (*url.URL, error) {
	return http.ProxyFromEnvironment(request)
}
