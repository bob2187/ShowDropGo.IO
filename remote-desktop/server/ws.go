package main

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024 * 256,
	CheckOrigin:    func(r *http.Request) bool { return true },
}

type Client struct {
	hub  *Hub
	conn *websocket.Conn
	send chan wsMessage
}

type controlMsg struct {
	Type    string  `json:"type"`
	X       float64 `json:"x"`
	Y       float64 `json:"y"`
	DX      float64 `json:"dx"`
	DY      float64 `json:"dy"`
	Buttons int     `json:"buttons"`
	Keycode int     `json:"keycode"`
	Down    bool    `json:"down"`
	Flags   int     `json:"flags"`
	Text    string  `json:"text"`
}

func serveWS(hub *Hub, cap *CaptureProcess, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("ws upgrade:", err)
		return
	}
	client := &Client{hub: hub, conn: conn, send: make(chan wsMessage, 128)}
	hub.register <- client
	go client.writePump()
	go client.readPump(cap)
}

func (c *Client) writePump() {
	defer func() {
		c.conn.Close()
	}()
	for msg := range c.send {
		if err := c.conn.WriteMessage(msg.msgType, msg.data); err != nil {
			return
		}
	}
}

func (c *Client) readPump(cap *CaptureProcess) {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()
	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		var msg controlMsg
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case "mouse", "key", "clipboard":
			cap.sendInput(raw)
		case "ping":
			// keepalive, no-op
		}
	}
}
