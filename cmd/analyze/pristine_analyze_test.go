//go:build darwin

// Pristine fork tests for pristine_analyze.go. Fork-only file.

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func setPristineRefresh(t *testing.T, on bool) {
	t.Helper()
	previous := *pristineRefresh
	*pristineRefresh = on
	t.Cleanup(func() { *pristineRefresh = previous })
}

func TestPristineDuTimeoutIsLongerOnlyForUserLibrary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if got := pristineDuTimeout(context.Background()); got != duTimeout {
		t.Fatalf("plain context: got %v, want upstream %v", got, duTimeout)
	}
	library := pristineOverviewContext(context.Background(), filepath.Join(home, "Library"))
	if got := pristineDuTimeout(library); got != pristineLibraryDuTimeout {
		t.Fatalf("User Library: got %v, want %v", got, pristineLibraryDuTimeout)
	}
	// The bound survives the timeout contexts upstream wraps around it.
	wrapped, cancel := context.WithTimeout(library, duTimeout)
	defer cancel()
	if got := pristineDuTimeout(wrapped); got != pristineLibraryDuTimeout {
		t.Fatalf("wrapped User Library context: got %v, want %v", got, pristineLibraryDuTimeout)
	}
	for _, path := range []string{home, filepath.Join(home, "Library", "Caches"), "/Library", "/Applications"} {
		if got := pristineDuTimeout(pristineOverviewContext(context.Background(), path)); got != duTimeout {
			t.Fatalf("%s: got %v, want upstream %v", path, got, duTimeout)
		}
	}
}

func TestPristineMeasureOverviewSizeMeasuresUserLibrary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)
	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(library, "Caches", "cache.dat"), 64*1024)

	size, err := pristineMeasureOverviewSize(context.Background(), library)
	if err != nil {
		t.Fatalf("pristineMeasureOverviewSize: %v", err)
	}
	if size < 64*1024 {
		t.Fatalf("expected the Library's bytes, got %d", size)
	}
}

func TestPristineRefreshSkipsStoredOverviewSize(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)
	target := filepath.Join(home, "Applications")
	writeFileWithSize(t, filepath.Join(target, "app.dat"), 4096)
	if err := storeOverviewMeasurement(target, 12345, false); err != nil {
		t.Fatalf("storeOverviewMeasurement: %v", err)
	}

	setPristineRefresh(t, false)
	if size, _, err := pristineCachedOverviewMeasurement(target); err != nil || size != 12345 {
		t.Fatalf("without --refresh: got %d, %v; want the stored 12345", size, err)
	}
	setPristineRefresh(t, true)
	if size, _, err := pristineCachedOverviewMeasurement(target); err == nil {
		t.Fatalf("with --refresh: got stored size %d, want a miss", size)
	}
}

func TestPristineRefreshRescansDirectoryInsteadOfReusingFolderCache(t *testing.T) {
	home := scanHome(t)
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	sub := filepath.Join(root, "sub")
	writeFileWithSize(t, filepath.Join(sub, "file.dat"), 4096)
	// A stored result for sub that no longer matches it: sub's own listing is
	// unchanged, so upstream's change check accepts it.
	if err := saveCacheToDisk(sub, scanResult{TotalSize: 1 << 30, TotalFiles: 1}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	scan := func() int64 {
		var files, dirs, bytes int64
		current := &atomic.Value{}
		current.Store("")
		result, err := pristineScanDirectoryForJSON(context.Background(), root, &files, &dirs, &bytes, current)
		if err != nil {
			t.Fatalf("pristineScanDirectoryForJSON: %v", err)
		}
		return result.TotalSize
	}

	setPristineRefresh(t, false)
	if got := scan(); got < 1<<30 {
		t.Fatalf("without --refresh: expected the stored folder size to be reused, got %d", got)
	}
	setPristineRefresh(t, true)
	if got := scan(); got >= 1<<20 {
		t.Fatalf("with --refresh: expected the folder to be measured again, got %d", got)
	}
}

// Merge guard: every du bound in scanner.go goes through pristineDuTimeout, or
// the User Library row silently returns to 30 s. If an upstream merge adds a
// new one, route it (a "// pristine-fork" hook line) or decide it stays short.
func TestPristineDuBoundsInScannerAreHooked(t *testing.T) {
	source, err := os.ReadFile("scanner.go")
	if err != nil {
		t.Fatalf("read scanner.go: %v", err)
	}
	text := string(source)
	if n := strings.Count(text, "WithTimeout(ctx, duTimeout)"); n != 0 {
		t.Fatalf("scanner.go has %d du bound(s) not routed through pristineDuTimeout", n)
	}
	if n := strings.Count(text, "pristineDuTimeout(ctx)"); n != 2 {
		t.Fatalf("expected the 2 hooked du bounds in scanner.go, found %d", n)
	}
}

// du exits 1 when one folder can't be read for a reason other than permission
// (a File Provider folder answers "Resource deadlock avoided"); the Library's
// size is still stored so the next overview doesn't measure it again.
func TestPristineUserLibraryWithUnreadableCloudFolderIsStored(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)
	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(library, "Caches", "cache.dat"), 4096)

	binDir := t.TempDir()
	stub := "#!/bin/sh\n" +
		"for operand; do :; done\n" +
		"printf 'du: %s/CloudStorage/Drive: Resource deadlock avoided\\n' \"$operand\" >&2\n" +
		"printf '2048\\t%s\\n' \"$operand\"\n" +
		"exit 1\n"
	if err := os.WriteFile(filepath.Join(binDir, "du"), []byte(stub), 0o755); err != nil {
		t.Fatalf("write du stub: %v", err)
	}
	useDuStub(t, filepath.Join(binDir, "du"))

	size, err := pristineMeasureOverviewSize(context.Background(), library)
	if size != 2048*1024 || err == nil {
		t.Fatalf("got %d, %v; want 2 MB with the du failure kept", size, err)
	}
	stored, state, err := loadStoredOverviewMeasurement(library)
	if err != nil || stored != 2048*1024 || state != scanPartial {
		t.Fatalf("stored: got %d, %v, %v; want 2 MB, partial", stored, state, err)
	}

	// Other rows keep upstream's rule: a non-permission failure isn't stored.
	other := filepath.Join(home, "Other")
	writeFileWithSize(t, filepath.Join(other, "file.dat"), 4096)
	if _, err := pristineMeasureOverviewSize(context.Background(), other); err == nil {
		t.Fatalf("expected the du failure for %s", other)
	}
	if _, _, err := loadStoredOverviewMeasurement(other); err == nil {
		t.Fatalf("expected no stored size for %s", other)
	}
}
