package main

import (
	"flag"
	"log"
	"net/http"
)

var (
	addr       = flag.String("addr", "127.0.0.1:8080", "listen address")
	captureBin = flag.String("capture", "/usr/local/bin/sdg-rdp-capture", "path to capture binary")
	clientDir  = flag.String("client", "/usr/local/share/sdg-rdp", "path to client files directory")
)

func main() {
	flag.Parse()

	hub := newHub()
	go hub.run()

	cap := newCaptureProcess(*captureBin, hub)
	go cap.run()

	go pollClipboard(hub)

	http.Handle("/", http.FileServer(http.Dir(*clientDir)))
	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveWS(hub, cap, w, r)
	})

	log.Printf("sdg-rdp listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, nil))
}
