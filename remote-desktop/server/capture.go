package main

import (
	"encoding/binary"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"
)

// Frame wire format from Swift binary (stdout):
//   [4 bytes big-endian payload length][1 byte flags: 0x01=keyframe][payload bytes]
//
// Frame wire format to WebSocket clients:
//   [1 byte flags][payload bytes]  (binary message)

type CaptureProcess struct {
	bin   string
	hub   *Hub
	mu    sync.Mutex
	stdin io.WriteCloser
}

func newCaptureProcess(bin string, hub *Hub) *CaptureProcess {
	return &CaptureProcess{bin: bin, hub: hub}
}

func (c *CaptureProcess) run() {
	for {
		if err := c.startAndRead(); err != nil {
			log.Printf("capture: %v — restarting in 3s", err)
		}
		time.Sleep(3 * time.Second)
	}
}

func (c *CaptureProcess) startAndRead() error {
	cmd := exec.Command(c.bin)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = log.Writer()

	if err := cmd.Start(); err != nil {
		return err
	}
	log.Printf("capture: started pid %d", cmd.Process.Pid)

	c.mu.Lock()
	c.stdin = stdin
	c.mu.Unlock()

	defer func() {
		c.mu.Lock()
		c.stdin = nil
		c.mu.Unlock()
		cmd.Process.Kill()
		cmd.Wait()
	}()

	for {
		var length uint32
		if err := binary.Read(stdout, binary.BigEndian, &length); err != nil {
			return err
		}
		var flags uint8
		if err := binary.Read(stdout, binary.BigEndian, &flags); err != nil {
			return err
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(stdout, payload); err != nil {
			return err
		}

		// Prepend flags byte so the browser client knows if this is a keyframe
		frame := make([]byte, 1+len(payload))
		frame[0] = flags
		copy(frame[1:], payload)
		c.hub.broadcastVideo(frame)
	}
}

func (c *CaptureProcess) sendInput(data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stdin == nil {
		return
	}
	// JSON lines protocol: one event per line
	line := append(data, '\n')
	if _, err := c.stdin.Write(line); err != nil {
		log.Println("capture: stdin write:", err)
	}
}
