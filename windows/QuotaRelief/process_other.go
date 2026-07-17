//go:build !windows

package main

func processExists(_ int) bool { return false }
