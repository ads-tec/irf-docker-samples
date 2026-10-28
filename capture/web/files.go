// Capture files and disk space: list, delete, and a guard that keeps the
// Docker partition from running full.
//
// Copyright (c) 2026, ads-tec Industrial IT GmbH
// SPDX-License-Identifier: BSD-2-Clause
//
// The captures volume lives on the IRF's Docker partition, together with
// the images and every other container. CAPTURE_MIN_FREE_BYTES (computed by
// the entrypoint from CAPTURE_MIN_FREE, default 15 % of the partition) stays
// free:
//
//   - a capture only starts if its size limit fits above the reserve
//   - below the reserve every capture is stopped at once (live captures and
//     SSH recordings: all rpcapcat processes); capture-retention then
//     deletes the oldest finished files until the reserve is free again
//
// Endpoints:
//
//	GET  /capture/api/files     files, disk, limits
//	POST /capture/api/delete    {names: [...]}
package main

import (
	"log"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"
)

var (
	minFree      = envInt("CAPTURE_MIN_FREE_BYTES", 0)
	capturesMax  = envInt("CAPTURE_MAX_SIZE_BYTES", 0)
	guardMu      sync.Mutex
	guardTripped time.Time
)

// files written within this time are treated as open (an SSH recording)
const activeWindow = 60 * time.Second

type diskInfo struct {
	Total   int64 `json:"total"`
	Free    int64 `json:"free"`
	MinFree int64 `json:"min_free"`
	Tmpfs   bool  `json:"tmpfs"`
}

const tmpfsMagic = 0x01021994

func disk() (diskInfo, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(capturesDir, &st); err != nil {
		return diskInfo{}, err
	}
	bs := int64(st.Bsize)
	return diskInfo{Total: int64(st.Blocks) * bs, Free: int64(st.Bavail) * bs, MinFree: minFree,
		Tmpfs: int64(st.Type) == tmpfsMagic}, nil
}

// spaceFor: error text if a capture of maxBytes would eat into the reserve
func spaceFor(maxBytes int64) string {
	d, err := disk()
	if err != nil || minFree <= 0 {
		return ""
	}
	if d.Free-maxBytes < d.MinFree {
		where := "the IRF's Docker partition"
		if d.Tmpfs {
			where = "the capture RAM disk"
		}
		return "not enough space: " + humanBytes(d.Free) + " free, " + humanBytes(d.MinFree) +
			" reserved on " + where + ". Delete captures or lower the size limit."
	}
	return ""
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return strconv.FormatInt(n, 10) + " B"
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return strconv.FormatFloat(float64(n)/float64(div), 'f', 1, 64) + " " + string("KMGTPE"[exp]) + "iB"
}

// diskGuard stops every capture when the free space drops below the
// reserve. Checked every 2 s: at 10 MB/s that is 20 MB past the line.
func diskGuard() {
	if minFree <= 0 {
		return
	}
	for range time.Tick(2 * time.Second) {
		d, err := disk()
		if err != nil || d.Free >= d.MinFree {
			continue
		}
		running := 0
		liveMu.Lock()
		for _, c := range captures {
			if c.Running {
				running++
				c.stopReason = "stopped: disk space low"
			}
		}
		liveMu.Unlock()
		// all rpcapcat processes of this user: live captures and SSH
		// recordings; tshark sees the end of the pipe and closes its file
		out, _ := exec.Command("pkill", "-TERM", "-x", "rpcapcat").CombinedOutput()
		guardMu.Lock()
		if time.Since(guardTripped) > time.Minute {
			log.Printf("disk guard: %s free, below the reserve of %s: captures stopped (%d live) %s",
				humanBytes(d.Free), humanBytes(d.MinFree), running, out)
		}
		guardTripped = time.Now()
		guardMu.Unlock()
	}
}

type fileInfo struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	Active   bool      `json:"active"`
}

// liveFiles: files of running live captures
func liveFiles() map[string]bool {
	liveMu.Lock()
	defer liveMu.Unlock()
	m := map[string]bool{}
	for _, c := range captures {
		if c.Running {
			m[c.File] = true
		}
	}
	return m
}

func handleFiles(w http.ResponseWriter, r *http.Request) {
	entries, err := os.ReadDir(capturesDir)
	if err != nil {
		errJSON(w, 500, "cannot read captures")
		return
	}
	live := liveFiles()
	files := []fileInfo{}
	var total int64
	for _, e := range entries {
		if !e.Type().IsRegular() {
			continue
		}
		if _, full, ok := resolve(e.Name()); ok {
			st, err := os.Stat(full)
			if err != nil {
				continue
			}
			total += st.Size()
			files = append(files, fileInfo{e.Name(), st.Size(), st.ModTime(),
				live[e.Name()] || time.Since(st.ModTime()) < activeWindow})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Modified.After(files[j].Modified) })
	d, _ := disk()
	guardMu.Lock()
	tripped := !guardTripped.IsZero() && time.Since(guardTripped) < 10*time.Minute
	guardMu.Unlock()
	writeJSON(w, 200, map[string]any{
		"files": files, "total": total, "max_size": capturesMax,
		"disk": d, "guard_tripped": tripped,
	})
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Names []string `json:"names"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Names) == 0 || len(req.Names) > 1000 {
		errJSON(w, 400, "no files")
		return
	}
	live := liveFiles()
	type failure struct {
		Name string `json:"name"`
		Err  string `json:"err"`
	}
	deleted := []string{}
	failed := []failure{}
	for _, name := range req.Names {
		base, full, ok := resolve(name)
		if !ok {
			failed = append(failed, failure{name, "not found"})
			continue
		}
		if live[base] {
			failed = append(failed, failure{base, "capture is running, stop it first"})
			continue
		}
		if st, err := os.Stat(full); err == nil && time.Since(st.ModTime()) < activeWindow {
			failed = append(failed, failure{base, "written to right now (SSH recording?), stop it first"})
			continue
		}
		if err := os.Remove(full); err != nil {
			failed = append(failed, failure{base, "cannot delete"})
			continue
		}
		deleted = append(deleted, base)
	}
	if len(deleted) > 0 {
		log.Printf("deleted %d capture file(s) from %s: %v", len(deleted), r.RemoteAddr, deleted)
	}
	writeJSON(w, 200, map[string]any{"deleted": deleted, "failed": failed})
}

func registerFiles(mux *http.ServeMux) {
	mux.HandleFunc("GET /capture/api/files", handleFiles)
	mux.HandleFunc("POST /capture/api/delete", handleDelete)
	go diskGuard()
}
