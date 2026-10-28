// Live capture from the web: interface list, capture filter, start/stop.
//
// Copyright (c) 2026, ads-tec Industrial IT GmbH
// SPDX-License-Identifier: BSD-2-Clause
//
// A capture is "rpcapcat -f <filter> <iface> | tshark -i - -w <file>" into
// one growing pcapng file in the captures directory, with an auto-stop at a
// size and a duration. webshark opens that file and follows it live over
// /webshark/watch, so no change to the webshark UI is needed:
//
//	GET  /capture/                  start page
//	GET  /capture/api/interfaces    [{name, up}] from the IRF's rpcapd
//	GET  /capture/api/list          running and finished captures
//	POST /capture/api/start         {iface, filter, hide_own, max_mb, max_minutes}
//	POST /capture/api/stop          {id}
//
// The file list, delete and the disk space guard are in files.go.
package main

import (
	"bufio"
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed live.html
var livePage []byte

const (
	maxRunning    = 4
	defaultMB     = 100
	limitMB       = 1000
	defaultMinute = 60
	limitMinute   = 24 * 60
)

var ifaceName = regexp.MustCompile(`^[A-Za-z0-9_.:@-]{1,32}$`)

type liveCapture struct {
	ID       string    `json:"id"`
	Iface    string    `json:"iface"`
	Filter   string    `json:"filter"`
	File     string    `json:"capture"`
	Started  time.Time `json:"started"`
	MaxMB    int       `json:"max_mb"`
	MaxMin   int       `json:"max_minutes"`
	Running  bool      `json:"running"`
	Ended    time.Time `json:"ended,omitzero"`
	Size     int64     `json:"size"`
	ExitInfo string    `json:"exit,omitempty"`

	src, sink       *exec.Cmd
	srcErr, sinkErr *lockedBuffer
	done            chan struct{}
	stopReason      string
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buf.Len() < 16<<10 {
		b.buf.Write(p)
	}
	return len(p), nil
}

// lastLine: the most useful line of rpcapcat/tshark stderr for the UI
func (b *lockedBuffer) lastLine() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var last string
	sc := bufio.NewScanner(bytes.NewReader(b.buf.Bytes()))
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "Capturing on") || strings.Contains(l, "packets captured") {
			continue
		}
		last = l
	}
	return last
}

var (
	liveMu   sync.Mutex
	captures = map[string]*liveCapture{}
)

// ownPorts: SSH and web UI port; their traffic on the LAN interface is the
// capture viewer itself and would feed back into the capture
func ownPorts() []string {
	ports := []string{}
	// behind nginx, the port the viewer uses is not the one we listen on
	if p := os.Getenv("WEB_PUBLIC_PORT"); p != "" {
		ports = append(ports, p)
	} else if _, p, ok := strings.Cut(listen, ":"); ok && p != "" {
		ports = append(ports, p)
	}
	if p := os.Getenv("SSH_PORT"); p != "" {
		ports = append(ports, p)
	}
	return ports
}

func handleInterfaces(w http.ResponseWriter, r *http.Request) {
	out, err := exec.CommandContext(r.Context(), "rpcapcat", "-l").CombinedOutput()
	if err != nil {
		errJSON(w, 502, strings.TrimSpace(string(out)))
		return
	}
	type iface struct {
		Name string `json:"name"`
		Up   bool   `json:"up"`
	}
	list := []iface{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) >= 1 && ifaceName.MatchString(f[0]) {
			list = append(list, iface{f[0], len(f) > 1 && f[1] == "up"})
		}
	}
	writeJSON(w, 200, map[string]any{"interfaces": list, "own_ports": ownPorts()})
}

func snapshot() []*liveCapture {
	liveMu.Lock()
	defer liveMu.Unlock()
	list := make([]*liveCapture, 0, len(captures))
	for _, c := range captures {
		if st, err := os.Stat(filepath.Join(capturesDir, c.File)); err == nil {
			c.Size = st.Size()
		}
		list = append(list, c)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Started.After(list[j].Started) })
	return list
}

func handleList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"captures": snapshot()})
}

type startRequest struct {
	Iface      string `json:"iface"`
	Filter     string `json:"filter"`
	HideOwn    bool   `json:"hide_own"`
	MaxMB      int    `json:"max_mb"`
	MaxMinutes int    `json:"max_minutes"`
}

// decodeJSON accepts only application/json: a cross-site HTML form cannot
// send that without a CORS preflight, which this server never answers
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		errJSON(w, 415, "application/json expected")
		return false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(v); err != nil {
		errJSON(w, 400, "invalid request")
		return false
	}
	return true
}

func clamp(v, def, max int) int {
	if v <= 0 {
		return def
	}
	if v > max {
		return max
	}
	return v
}

func handleStart(w http.ResponseWriter, r *http.Request) {
	var req startRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if !ifaceName.MatchString(req.Iface) {
		errJSON(w, 400, "invalid interface")
		return
	}
	filter := strings.TrimSpace(req.Filter)
	if len(filter) > 2000 || strings.ContainsAny(filter, "\x00\n\r") {
		errJSON(w, 400, "invalid filter")
		return
	}
	if req.HideOwn {
		own := []string{}
		for _, p := range ownPorts() {
			own = append(own, "port "+p)
		}
		if len(own) > 0 {
			excl := "not (" + strings.Join(own, " or ") + ")"
			if filter != "" {
				filter = "(" + filter + ") and " + excl
			} else {
				filter = excl
			}
		}
	}
	maxMB := clamp(req.MaxMB, defaultMB, limitMB)
	maxMin := clamp(req.MaxMinutes, defaultMinute, limitMinute)
	if msg := spaceFor(int64(maxMB) * 1000 * 1000); msg != "" {
		errJSON(w, 507, msg)
		return
	}

	liveMu.Lock()
	running := 0
	for _, c := range captures {
		if c.Running {
			running++
		}
	}
	liveMu.Unlock()
	if running >= maxRunning {
		errJSON(w, 409, fmt.Sprintf("%d captures are running, stop one first", running))
		return
	}

	now := time.Now()
	id := fmt.Sprintf("%s_%s", strings.NewReplacer(":", "_", "@", "_").Replace(req.Iface), now.Format("20060102-150405"))
	file := "live_" + id + ".pcapng"
	full := filepath.Join(capturesDir, file)
	if _, err := os.Stat(full); err == nil {
		errJSON(w, 409, "a capture with this name exists, try again in a second")
		return
	}

	c := &liveCapture{ID: id, Iface: req.Iface, Filter: filter, File: file, Started: now,
		MaxMB: maxMB, MaxMin: maxMin, Running: true,
		srcErr: &lockedBuffer{}, sinkErr: &lockedBuffer{}, done: make(chan struct{})}
	if err := c.start(full); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	liveMu.Lock()
	captures[id] = c
	liveMu.Unlock()
	go c.wait()

	// Filter errors, unknown interfaces and an unreachable rpcapd show up
	// within a moment: report them instead of a capture that never grows.
	select {
	case <-c.done:
		os.Remove(full)
		liveMu.Lock()
		delete(captures, id)
		liveMu.Unlock()
		msg := c.message()
		if msg == "" {
			msg = "capture ended immediately"
		}
		errJSON(w, 400, msg)
		return
	case <-time.After(2 * time.Second):
	}
	log.Printf("live capture %s started: %s %q", id, req.Iface, filter)
	writeJSON(w, 200, c)
}

func (c *liveCapture) start(full string) error {
	pr, pw, err := os.Pipe()
	if err != nil {
		return err
	}
	defer pr.Close()
	defer pw.Close()

	c.src = exec.Command("rpcapcat", "-f", c.Filter, c.Iface)
	c.src.Stdout = pw
	c.src.Stderr = c.srcErr
	// -a: auto-stop; tshark ends, rpcapcat gets EPIPE and ends too
	c.sink = exec.Command("tshark", "-i", "-", "-q", "-w", full,
		"-a", "filesize:"+strconv.Itoa(c.MaxMB*1000),
		"-a", "duration:"+strconv.Itoa(c.MaxMin*60))
	c.sink.Stdin = pr
	c.sink.Stderr = c.sinkErr
	for _, cmd := range []*exec.Cmd{c.src, c.sink} {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
	if err := c.sink.Start(); err != nil {
		return err
	}
	if err := c.src.Start(); err != nil {
		c.sink.Process.Kill()
		c.sink.Wait()
		return err
	}
	return nil
}

// message: rpcapcat's error or statistics first, tshark only reports the
// consequence (a closed pipe)
func (c *liveCapture) message() string {
	if m := c.srcErr.lastLine(); m != "" {
		return m
	}
	return c.sinkErr.lastLine()
}

func (c *liveCapture) wait() {
	// the source ending (stop, rpcapd gone) closes the pipe, tshark then
	// writes the rest and exits; tshark ending (auto-stop) breaks the pipe
	srcDone := make(chan struct{})
	go func() { c.src.Wait(); close(srcDone) }()
	c.sink.Wait()
	select {
	case <-srcDone:
	case <-time.After(3 * time.Second):
		c.src.Process.Signal(syscall.SIGTERM)
		<-srcDone
	}
	liveMu.Lock()
	c.Running = false
	c.Ended = time.Now()
	c.ExitInfo = c.message()
	if c.stopReason != "" {
		c.ExitInfo = c.stopReason + ", " + c.ExitInfo
	}
	liveMu.Unlock()
	close(c.done)
	log.Printf("live capture %s ended: %s", c.ID, c.ExitInfo)
}

func handleStop(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID string `json:"id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	liveMu.Lock()
	c := captures[req.ID]
	liveMu.Unlock()
	if c == nil {
		errJSON(w, 404, "no such capture")
		return
	}
	// stop the source: tshark sees the end of the pipe and closes the file
	c.src.Process.Signal(syscall.SIGTERM)
	select {
	case <-c.done:
	case <-time.After(8 * time.Second):
		c.sink.Process.Signal(syscall.SIGTERM)
		<-c.done
	}
	writeJSON(w, 200, c)
}

func handleLivePage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'")
	w.Write(livePage)
}

// forget finished captures after a day, the files stay
func pruneCaptures() {
	for range time.Tick(time.Hour) {
		liveMu.Lock()
		for id, c := range captures {
			if !c.Running && time.Since(c.Ended) > 24*time.Hour {
				delete(captures, id)
			}
		}
		liveMu.Unlock()
	}
}

func registerLive(mux *http.ServeMux) {
	mux.HandleFunc("GET /capture", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/capture/", http.StatusFound)
	})
	mux.HandleFunc("GET /capture/{$}", handleLivePage)
	mux.HandleFunc("GET /capture/api/interfaces", handleInterfaces)
	mux.HandleFunc("GET /capture/api/list", handleList)
	mux.HandleFunc("POST /capture/api/start", handleStart)
	mux.HandleFunc("POST /capture/api/stop", handleStop)
	go pruneCaptures()
}
