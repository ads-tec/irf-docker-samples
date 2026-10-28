// capture-web - serves the webshark-ng UI and the capture directory.
//
// Copyright (c) 2026, ads-tec Industrial IT GmbH
// SPDX-License-Identifier: BSD-2-Clause
//
// webshark-ng (https://github.com/hepictel/webshark) dissects in the browser
// (Wireshark as WASM); its Node.js API only does file I/O. This replaces
// that API with the same endpoints in a small static binary, so the image
// does not need Node.js:
//
//	GET  /webshark/json?method=files            list captures
//	GET  /webshark/json?method=download&...     capture as attachment
//	GET  /webshark/captures/<name>              raw capture for the worker
//	GET  /webshark/watch?capture=<name>         SSE, follows growing files
//	POST /webshark/upload[/now]                 multipart upload
//	GET  /webshark/...                          static UI
//
// plus the live capture page and API under /capture/ (live.go).
package main

import (
	"compress/gzip"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	capturesDir = envOr("CAPTURES_PATH", "/captures")
	webRoot     = envOr("WEB_ROOT", "/usr/share/webshark")
	listen      = envOr("WEB_LISTEN", "127.0.0.1:8085")
	authUser    = envOr("WEB_USER", "cap")
	authPass    = os.Getenv("WEB_PASSWORD")
	uploadMax   = envInt("UPLOAD_MAX_BYTES", 2<<30)
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int64) int64 {
	if v, err := strconv.ParseInt(os.Getenv(k), 10, 64); err == nil && v > 0 {
		return v
	}
	return def
}

var captureExt = []string{".pcapng", ".pcap", ".cap"}

// isCapture: known extension or pcap/pcapng magic, like webshark's API.
func isCapture(name, full string) bool {
	lower := strings.ToLower(name)
	for _, e := range captureExt {
		if strings.HasSuffix(lower, e) {
			return true
		}
	}
	return hasCaptureMagic(full)
}

func hasCaptureMagic(full string) bool {
	f, err := os.Open(full)
	if err != nil {
		return false
	}
	defer f.Close()
	var b [4]byte
	if _, err := io.ReadFull(f, b[:]); err != nil {
		return false
	}
	switch binary.LittleEndian.Uint32(b[:]) {
	case 0xa1b2c3d4, 0xd4c3b2a1, 0xa1b23c4d, 0x4d3cb2a1, 0x0a0d0d0a:
		return true
	}
	return false
}

// resolve maps a client supplied name to a regular capture file directly in
// capturesDir. No subdirectories, no hidden files, no symlinks.
func resolve(name string) (string, string, bool) {
	base := filepath.Base(name)
	if name == "" || base != name || base == "." || base == ".." ||
		strings.HasPrefix(base, ".") || strings.ContainsAny(base, "/\\\x00") {
		return "", "", false
	}
	full := filepath.Join(capturesDir, base)
	st, err := os.Lstat(full)
	if err != nil || !st.Mode().IsRegular() || !isCapture(base, full) {
		return "", "", false
	}
	return base, full, true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"err": 1, "errstr": msg})
}

type fileEntry struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}

func listFiles(w http.ResponseWriter) {
	entries, err := os.ReadDir(capturesDir)
	if err != nil {
		errJSON(w, 500, "cannot read captures")
		return
	}
	files := []fileEntry{}
	for _, e := range entries {
		if !e.Type().IsRegular() {
			continue
		}
		if _, full, ok := resolve(e.Name()); ok {
			if st, err := os.Stat(full); err == nil {
				files = append(files, fileEntry{e.Name(), st.Size()})
			}
		}
	}
	writeJSON(w, 200, map[string]any{"files": files, "pwd": "."})
}

func sendCapture(w http.ResponseWriter, r *http.Request, name string, attachment bool) {
	base, full, ok := resolve(name)
	if !ok {
		errJSON(w, 404, "not found")
		return
	}
	f, err := os.Open(full)
	if err != nil {
		errJSON(w, 404, "not found")
		return
	}
	defer f.Close()
	if attachment {
		w.Header().Set("Content-Disposition", `attachment; filename="`+base+`"`)
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	// Plain copy instead of ServeContent: a growing file is sent as far as
	// it is written, the watch endpoint tells the UI to reload.
	io.Copy(w, f)
}

func handleJSON(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	switch q.Get("method") {
	case "files":
		listFiles(w)
	case "download":
		if q.Get("token") != "self" {
			errJSON(w, 400, "download tokens are handled in the browser")
			return
		}
		sendCapture(w, r, q.Get("capture"), true)
	case "":
		w.WriteHeader(204)
	default:
		errJSON(w, 400, "method not allowed: "+q.Get("method"))
	}
}

func handleWatch(w http.ResponseWriter, r *http.Request) {
	_, full, ok := resolve(r.URL.Query().Get("capture"))
	if !ok {
		errJSON(w, 404, "not found")
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		errJSON(w, 500, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(200)

	send := func(event string, data any) {
		b, _ := json.Marshal(data)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
		fl.Flush()
	}
	prev := int64(-1)
	tick := func() {
		st, err := os.Stat(full)
		if err != nil {
			return
		}
		kind := "none"
		switch {
		case prev < 0:
			kind = "init"
		case st.Size() < prev:
			kind = "full"
		case st.Size() > prev:
			kind = "append"
		}
		if kind == "none" {
			return
		}
		prev = st.Size()
		send("capture-changed", map[string]any{"size": st.Size(), "mtime": st.ModTime().UnixMilli(), "kind": kind})
	}

	tick()
	poll := time.NewTicker(400 * time.Millisecond)
	heartbeat := time.NewTicker(15 * time.Second)
	defer poll.Stop()
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-poll.C:
			tick()
		case <-heartbeat.C:
			send("heartbeat", map[string]any{"t": time.Now().UnixMilli()})
		}
	}
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		errJSON(w, 405, "method not allowed")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, uploadMax)
	mr, err := r.MultipartReader()
	if err != nil {
		errJSON(w, 400, "multipart expected")
		return
	}
	var stored []fileEntry
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			errJSON(w, 400, "upload failed")
			return
		}
		if part.FileName() == "" {
			continue
		}
		base := filepath.Base(part.FileName())
		if base == "." || base == ".." || strings.HasPrefix(base, ".") || strings.ContainsAny(base, "/\\\x00") {
			errJSON(w, 400, "invalid filename")
			return
		}
		dest := filepath.Join(capturesDir, base)
		// Write to a temp file and rename: an existing capture (or one
		// being recorded) is replaced atomically, never written through.
		tmp, err := os.CreateTemp(capturesDir, ".upload-*")
		if err != nil {
			errJSON(w, 500, "upload failed")
			return
		}
		n, err := io.Copy(tmp, part)
		tmp.Close()
		if err == nil && !hasCaptureMagic(tmp.Name()) {
			err = errors.New("not a capture file")
		}
		if err == nil {
			err = os.Rename(tmp.Name(), dest)
		}
		if err != nil {
			os.Remove(tmp.Name())
			log.Printf("upload %q: %v", base, err)
			errJSON(w, 400, "upload failed: "+err.Error())
			return
		}
		log.Printf("upload %q: %d bytes from %s", base, n, r.RemoteAddr)
		stored = append(stored, fileEntry{base, n})
	}
	writeJSON(w, 200, map[string]any{"files": stored})
}

// serveStatic serves the UI. Larger files are only in the image as .gz (the
// Wireshark WASM alone is 66 MB, 19 MB compressed); they are sent with
// Content-Encoding: gzip, or decompressed for the rare client without gzip.
// No directory listings.
func serveStatic(w http.ResponseWriter, r *http.Request) {
	rel := path.Clean("/" + strings.TrimPrefix(r.URL.Path, "/webshark/"))
	full := filepath.Join(webRoot, filepath.FromSlash(rel))
	if st, err := os.Stat(full); err == nil && st.IsDir() {
		full = filepath.Join(full, "index.html")
	}
	if f, err := os.Open(full); err == nil {
		defer f.Close()
		if st, err := f.Stat(); err == nil && st.Mode().IsRegular() {
			http.ServeContent(w, r, full, st.ModTime(), f)
			return
		}
	}
	gz, err := os.Open(full + ".gz")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer gz.Close()
	st, err := gz.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	ctype := mime.TypeByExtension(filepath.Ext(full))
	if ctype == "" {
		ctype = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Add("Vary", "Accept-Encoding")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		h.Set("Content-Encoding", "gzip")
		r.Header.Del("Range")
		http.ServeContent(w, r, full, st.ModTime(), gz)
		return
	}
	zr, err := gzip.NewReader(gz)
	if err != nil {
		http.Error(w, "broken asset", 500)
		return
	}
	io.Copy(w, zr)
}

// isolation headers enable SharedArrayBuffer (RTP playback) on a secure
// origin; plain HTTP to a LAN address is not one, so they are only sent for
// localhost (the SSH tunnel) and HTTPS behind a proxy, like webshark's API.
func trustworthy(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}
	if host == "localhost" || host == "127.0.0.1" || host == "::1" {
		return true
	}
	return strings.EqualFold(strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0]), "https")
}

func withCommon(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if authPass != "" {
			u, p, ok := r.BasicAuth()
			if !ok || subtle.ConstantTimeCompare([]byte(u), []byte(authUser)) != 1 ||
				subtle.ConstantTimeCompare([]byte(p), []byte(authPass)) != 1 {
				w.Header().Set("WWW-Authenticate", `Basic realm="irf-capture", charset="UTF-8"`)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		if trustworthy(r) {
			h.Set("Cross-Origin-Opener-Policy", "same-origin")
			h.Set("Cross-Origin-Embedder-Policy", "credentialless")
			h.Set("Cross-Origin-Resource-Policy", "cross-origin")
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	index := filepath.Join(webRoot, "index.html")
	sendIndex := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, index)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/capture/", http.StatusFound)
	})
	mux.HandleFunc("GET /webshark", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/webshark/", http.StatusFound)
	})
	mux.HandleFunc("GET /webshark/{$}", sendIndex)
	mux.HandleFunc("GET /webshark/embed", sendIndex)
	mux.HandleFunc("GET /webshark/embed/{view}", sendIndex)
	mux.HandleFunc("GET /webshark/json", handleJSON)
	mux.HandleFunc("GET /webshark/captures/{name}", func(w http.ResponseWriter, r *http.Request) {
		sendCapture(w, r, r.PathValue("name"), false)
	})
	mux.HandleFunc("GET /webshark/watch", handleWatch)
	mux.HandleFunc("POST /webshark/upload", handleUpload)
	mux.HandleFunc("POST /webshark/upload/now", handleUpload)
	mux.HandleFunc("GET /webshark/", serveStatic)
	registerLive(mux)
	registerFiles(mux)

	srv := &http.Server{
		Addr:              listen,
		Handler:           withCommon(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("live capture on http://%s/capture/, webshark UI on /webshark/, captures in %s", listen, capturesDir)
	log.Fatal(srv.ListenAndServe())
}
