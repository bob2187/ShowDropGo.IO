package main

import (
	"encoding/json"
	"sync"

	"github.com/gorilla/websocket"
)

type wsMessage struct {
	msgType int
	data    []byte
}

type Hub struct {
	mu         sync.RWMutex
	clients    map[*Client]bool
	register   chan *Client
	unregister chan *Client
	video      chan []byte // binary H.264 frames
	text       chan []byte // JSON control messages
}

func newHub() *Hub {
	return &Hub{
		clients:    make(map[*Client]bool),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		video:      make(chan []byte, 16),
		text:       make(chan []byte, 16),
	}
}

func (h *Hub) run() {
	for {
		select {
		case c := <-h.register:
			h.mu.Lock()
			h.clients[c] = true
			h.mu.Unlock()

		case c := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[c]; ok {
				delete(h.clients, c)
				close(c.send)
			}
			h.mu.Unlock()

		case frame := <-h.video:
			h.broadcast(wsMessage{websocket.BinaryMessage, frame})

		case msg := <-h.text:
			h.broadcast(wsMessage{websocket.TextMessage, msg})
		}
	}
}

func (h *Hub) broadcast(msg wsMessage) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.clients {
		select {
		case c.send <- msg:
		default:
			// slow client: drop frame rather than block
		}
	}
}

func (h *Hub) broadcastVideo(frame []byte) {
	// non-blocking: skip if channel is full
	select {
	case h.video <- frame:
	default:
	}
}

func (h *Hub) broadcastClipboard(text string) {
	msg, _ := json.Marshal(map[string]string{"type": "clipboard", "text": text})
	select {
	case h.text <- msg:
	default:
	}
}
