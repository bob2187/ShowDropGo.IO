package main

import (
	"os/exec"
	"time"
)

// pollClipboard watches the macOS pasteboard every 500ms and broadcasts
// changes to all connected WebSocket clients as a JSON text message.
func pollClipboard(hub *Hub) {
	var last string
	for range time.Tick(500 * time.Millisecond) {
		out, err := exec.Command("pbpaste").Output()
		if err != nil {
			continue
		}
		if s := string(out); s != last {
			last = s
			if s != "" {
				hub.broadcastClipboard(s)
			}
		}
	}
}
