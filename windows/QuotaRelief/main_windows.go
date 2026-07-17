//go:build windows

package main

func main() {
	if err := runTrayApplication(); err != nil {
		showError(err.Error())
	}
}
