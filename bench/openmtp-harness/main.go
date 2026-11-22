// openmtp-bench drives OpenMTP's transfer engine (go-mtpx, the library behind OpenMTP's "Kalam"
// native module) without the Electron UI, and records per-file progress timestamps.
//
// It mirrors the call sequence of OpenMTP's Kalam FFI (ffi/kalam/native/kalam.go + helpers.go):
//
//	Initialize -> FetchDeviceInfo (Kalam's Initialize does this) -> FetchStorages ->
//	MakeDirectory -> UploadFiles / DownloadFiles (preprocessFiles = true, OpenMTP's default) -> Dispose
//
// Kalam's verifyMtpSession calls FetchDeviceInfo before every operation, so this does too.
//
// Usage:
//
//	openmtp-bench candidates
//	openmtp-bench storages [-vendor 0x17ef -match SERIAL]
//	openmtp-bench upload   [-vendor ...] -log run.jsonl -storage 0x10001 -mkdir /Download/x/openmtp -dest /Download/x/openmtp <local sources...>
//	openmtp-bench download [-vendor ...] -log run.jsonl -storage 0x10001 -dest /tmp/pull/openmtp <device sources...>
//
// Without -vendor the device is opened with go-mtpx's own Initialize, exactly as OpenMTP does; that
// needs exactly one MTP device on the bus. See README.md.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	mtpx "github.com/ganeshrvel/go-mtpx"
)

var start = time.Now()

func since(t time.Time) float64 { return t.Sub(start).Seconds() }
func now() float64              { return since(time.Now()) }

type fileRec struct {
	Path  string  `json:"path"`
	Size  int64   `json:"size"`
	First float64 `json:"first"` // first progress callback (s since process start)
	Done  float64 `json:"done"`  // callback with sent == total
}

type tracker struct {
	mu       sync.Mutex
	files    []*fileRec
	byPath   map[string]*fileRec
	last     time.Time
	enc      *json.Encoder
	logFile  *os.File
	finished bool
}

func newTracker(path string) *tracker {
	t := &tracker{byPath: map[string]*fileRec{}, last: time.Now()}
	if path != "" {
		f, err := os.Create(path)
		if err != nil {
			fail("log", err)
		}
		t.logFile = f
		t.enc = json.NewEncoder(f)
	}
	return t
}

func (t *tracker) event(kind string, extra map[string]interface{}) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.emit(kind, extra)
}

func (t *tracker) emit(kind string, extra map[string]interface{}) {
	if t.enc == nil {
		return
	}
	m := map[string]interface{}{"ev": kind, "t": now()}
	for k, v := range extra {
		m[k] = v
	}
	_ = t.enc.Encode(m)
}

func (t *tracker) progress(p *mtpx.ProgressInfo, err error) error {
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	ts := time.Now()
	t.last = ts
	if p.Status == mtpx.Completed {
		t.emit("completed", map[string]interface{}{"filesSent": p.FilesSent, "bulkSent": p.BulkFileSize.Sent})
		return nil
	}
	if p.FileInfo == nil || p.ActiveFileSize == nil {
		return nil
	}
	key := p.FileInfo.FullPath
	r := t.byPath[key]
	if r == nil {
		r = &fileRec{Path: key, Size: p.ActiveFileSize.Total, First: since(ts), Done: -1}
		t.byPath[key] = r
		t.files = append(t.files, r)
	}
	if p.ActiveFileSize.Total > 0 && p.ActiveFileSize.Sent >= p.ActiveFileSize.Total && r.Done < 0 {
		r.Done = since(ts)
		t.emit("file_done", map[string]interface{}{"path": r.Path, "size": r.Size, "first": r.First, "done": r.Done})
	}
	return nil
}

// watchdog: abort if no progress for [idle].
func (t *tracker) watchdog(idle time.Duration) {
	go func() {
		for {
			time.Sleep(5 * time.Second)
			t.mu.Lock()
			stalled := !t.finished && time.Since(t.last) > idle
			t.mu.Unlock()
			if stalled {
				fmt.Fprintf(os.Stderr, "HANG: no progress for %s\n", idle)
				t.event("hang", nil)
				os.Exit(3)
			}
		}
	}()
}

func (t *tracker) touch() {
	t.mu.Lock()
	t.last = time.Now()
	t.mu.Unlock()
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "ERROR %s: %T: %v\n", step, err, err)
	os.Exit(2)
}

func parseStorage(s string) uint32 {
	v, err := strconv.ParseUint(strings.TrimPrefix(strings.ToLower(s), "0x"), 16, 32)
	if err != nil {
		fail("storage", err)
	}
	return uint32(v)
}

// Device selection. With -vendor unset (the SP3000 run), open() calls go-mtpx's Initialize as
// OpenMTP does. go-mtpx Initialize uses SelectDeviceWithDebugging("") which picks "the" device and
// fails with "more than 1 device" when two are present; a name pattern does not help because
// upstream selectDevice opens+claims every candidate before matching. So with -vendor set (the
// Lenovo run, with a second MTP device connected) this is mtpx.Initialize with exactly one change:
// the vendor-filtered selector from third_party/go-mtpfs (filters on the cached USB descriptor
// before opening). Timeout/Configure are as in mtpx.Initialize.
var (
	wantVendor uint16 // 0 = use mtpx.Initialize
	wantMatch  string // regexp on "manufacturer product serial"; with -vendor only
)

const mtpxDevTimeout = 15000 // go-mtpx const.go devTimeout

var mtpDebug bool

func open(t *tracker) *mtp.Device {
	t.event("init_start", nil)
	if wantVendor == 0 {
		dev, err := mtpx.Initialize(mtpx.Init{DebugMode: false})
		if err != nil {
			fail("Initialize", err)
		}
		if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
			fail("FetchDeviceInfo", err)
		}
		t.event("init_done", nil)
		return dev
	}
	dev, err := mtp.SelectDeviceByVendorWithDebugging(wantVendor, wantMatch, false)
	if err != nil {
		fail("Initialize(select)", err)
	}
	ui, err := dev.GetUsbInfo()
	if err != nil {
		fail("GetUsbInfo", err)
	}
	if ui.IdVendor != wantVendor {
		dev.Close()
		fail("verify device", fmt.Errorf("selected %04x:%04x %q %q, want vendor %04x",
			ui.IdVendor, ui.IdProduct, ui.Manufacturer, ui.Product, wantVendor))
	}
	dev.MTPDebug, dev.DataDebug, dev.USBDebug = mtpDebug, false, mtpDebug
	dev.Timeout = mtpxDevTimeout
	if err := dev.Configure(); err != nil {
		fail("Initialize(Configure)", err)
	}
	if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
		fail("FetchDeviceInfo", err)
	}
	t.event("init_done", map[string]interface{}{"usb": fmt.Sprintf("%04x:%04x %s %s", ui.IdVendor, ui.IdProduct, ui.Manufacturer, ui.Product)})
	return dev
}

func storages(dev *mtp.Device) []mtpx.StorageData {
	if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
		fail("FetchDeviceInfo", err)
	}
	s, err := mtpx.FetchStorages(dev)
	if err != nil {
		fail("FetchStorages", err)
	}
	return s
}

func summarize(t *tracker, opStart, opEnd float64, filesSent, bytesSent int64) {
	t.mu.Lock()
	files := append([]*fileRec(nil), t.files...)
	t.mu.Unlock()
	sort.Slice(files, func(i, j int) bool { return files[i].Done < files[j].Done })
	var intervals, data, gaps []float64
	prev := opStart
	lastDone := opStart
	for _, f := range files {
		if f.Done < 0 {
			continue
		}
		intervals = append(intervals, f.Done-prev)
		data = append(data, f.Done-f.First)
		gaps = append(gaps, f.First-prev)
		prev = f.Done
		lastDone = f.Done
	}
	avg := func(v []float64) float64 {
		if len(v) == 0 {
			return 0
		}
		s := 0.0
		for _, x := range v {
			s += x
		}
		return s / float64(len(v))
	}
	med := func(v []float64) float64 {
		if len(v) == 0 {
			return 0
		}
		c := append([]float64(nil), v...)
		sort.Float64s(c)
		return c[len(c)/2]
	}
	firstLast := func(v []float64, n int) (float64, float64) {
		if len(v) < n {
			return avg(v), avg(v)
		}
		return avg(v[:n]), avg(v[len(v)-n:])
	}
	f10, l10 := firstLast(intervals, 10)
	transfer := lastDone - opStart
	s := map[string]interface{}{
		"files_sent":             filesSent,
		"bytes_sent":             bytesSent,
		"files_with_done":        len(intervals),
		"op_start_s":             opStart,
		"last_file_done_s":       lastDone,
		"op_return_s":            opEnd,
		"transfer_s":             transfer,
		"transfer_MBps":          float64(bytesSent) / 1e6 / transfer,
		"avg_s_per_file":         avg(intervals),
		"median_s_per_file":      med(intervals),
		"avg_data_s_per_file":    avg(data),
		"avg_gap_s_per_file":     avg(gaps),
		"avg_first10_s_per_file": f10,
		"avg_last10_s_per_file":  l10,
	}
	t.event("summary", s)
	b, _ := json.MarshalIndent(s, "", "  ")
	fmt.Println(string(b))
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: openmtp-bench storages|upload|download ...")
		os.Exit(1)
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	logPath := fs.String("log", "", "JSONL event log")
	storage := fs.String("storage", "", "storage id (hex)")
	dest := fs.String("dest", "", "destination folder")
	mkdir := fs.String("mkdir", "", "device folder to create with MakeDirectory first (upload)")
	idle := fs.Duration("idle", 15*time.Minute, "abort if no progress for this long")
	fs.BoolVar(&mtpDebug, "mtpdebug", false, "log MTP request/response codes (go-mtpfs MTPDebug) and USB calls (USBDebug); no data dumps; -vendor only")
	vendor := fs.String("vendor", "", "USB idVendor (hex) to select without opening other MTP devices; empty = go-mtpx Initialize")
	fs.StringVar(&wantMatch, "match", "", "with -vendor: regexp on \"manufacturer product serial\"")
	_ = fs.Parse(os.Args[2:])
	if *vendor != "" {
		v, err := strconv.ParseUint(strings.TrimPrefix(strings.ToLower(*vendor), "0x"), 16, 16)
		if err != nil || v == 0 {
			fail("vendor", fmt.Errorf("bad -vendor %q", *vendor))
		}
		wantVendor = uint16(v)
	}
	sources := fs.Args()
	t := newTracker(*logPath)
	defer func() {
		if t.logFile != nil {
			t.logFile.Close()
		}
	}()

	switch cmd {
	case "candidates":
		c, err := mtp.ListCandidates()
		if err != nil {
			fail("ListCandidates", err)
		}
		for _, v := range c {
			fmt.Printf("candidate %04x:%04x\n", v[0], v[1])
		}
	case "storages":
		dev := open(t)
		if di, err := mtpx.FetchDeviceInfo(dev); err == nil {
			fmt.Printf("device: manufacturer=%q model=%q version=%q serial=%q ext=%q\n", di.Manufacturer, di.Model, di.DeviceVersion, di.SerialNumber, di.MTPExtension)
		}
		for _, s := range storages(dev) {
			fmt.Printf("%#010x\t%s\t%d free of %d\n", s.Sid, s.Info.StorageDescription, s.Info.FreeSpaceInBytes, s.Info.MaxCapability)
		}
		if info, err := dev.GetUsbInfo(); err == nil {
			fmt.Printf("usb: %+v\n", *info)
		}
		mtpx.Dispose(dev)
	case "upload":
		sid := parseStorage(*storage)
		t.watchdog(*idle)
		dev := open(t)
		found := false
		for _, s := range storages(dev) {
			found = found || s.Sid == sid
		}
		if !found {
			fail("FetchStorages", fmt.Errorf("storage %#x not found", sid))
		}
		opStart := now()
		if *mkdir != "" {
			if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
				fail("FetchDeviceInfo", err)
			}
			t.event("mkdir_start", map[string]interface{}{"path": *mkdir})
			if _, err := mtpx.MakeDirectory(dev, sid, *mkdir); err != nil {
				fail("MakeDirectory", err)
			}
			t.event("mkdir_done", nil)
		}
		t.touch()
		if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
			fail("FetchDeviceInfo", err)
		}
		t.event("upload_start", map[string]interface{}{"dest": *dest, "sources": sources})
		_, n, b, err := mtpx.UploadFiles(dev, sid, sources, *dest, true,
			func(fi *os.FileInfo, fullPath string, err error) error { return err },
			t.progress)
		opEnd := now()
		t.mu.Lock()
		t.finished = true
		t.mu.Unlock()
		if err != nil {
			t.event("error", map[string]interface{}{"step": "UploadFiles", "error": err.Error(), "files": n, "bytes": b})
			summarize(t, opStart, opEnd, n, b)
			fail("UploadFiles", err)
		}
		t.event("upload_done", map[string]interface{}{"files": n, "bytes": b})
		summarize(t, opStart, opEnd, n, b)
		mtpx.Dispose(dev)
		t.event("disposed", nil)
	case "download":
		sid := parseStorage(*storage)
		t.watchdog(*idle)
		dev := open(t)
		storages(dev)
		opStart := now()
		t.touch()
		if _, err := mtpx.FetchDeviceInfo(dev); err != nil {
			fail("FetchDeviceInfo", err)
		}
		t.event("download_start", map[string]interface{}{"dest": *dest, "sources": sources})
		n, b, err := mtpx.DownloadFiles(dev, sid, sources, *dest, true,
			func(fi *mtpx.FileInfo, err error) error { t.touch(); return err },
			t.progress)
		opEnd := now()
		t.mu.Lock()
		t.finished = true
		t.mu.Unlock()
		if err != nil {
			t.event("error", map[string]interface{}{"step": "DownloadFiles", "error": err.Error(), "files": n, "bytes": b})
			summarize(t, opStart, opEnd, n, b)
			fail("DownloadFiles", err)
		}
		t.event("download_done", map[string]interface{}{"files": n, "bytes": b})
		summarize(t, opStart, opEnd, n, b)
		mtpx.Dispose(dev)
		t.event("disposed", nil)
	default:
		fmt.Fprintln(os.Stderr, "unknown command", cmd)
		os.Exit(1)
	}
}
