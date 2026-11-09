//go:build darwin

// Pristine fork: analyze --json fixes for a GUI's disk view.
// Fork-only file; see CHANGES-FORK.md ("Hook inventory").
//
//   - The overview's User Library row gets a longer du bound. Upstream gives
//     every overview du duTimeout (30 s) and reports a Library that takes
//     longer as unavailable with size 0, so a machine-wide total misses what is
//     often its largest folder (96 GB taking 30.5 s on one Mac).
//   - --refresh measures everything again: the overview skips its stored
//     sizes (kept for overviewCacheTTL with no change check) and a directory
//     scan bypasses the per-folder cache, like the TUI's refresh.

package main

import (
	"context"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

var pristineRefresh = flag.Bool("refresh", false, "measure again instead of reusing stored sizes")

// pristineLibraryDuTimeout bounds the User Library's single du traversal. It
// stays one traversal (hardlinks across its folders count once); only the
// bound is longer. A Library that still takes longer reports as upstream does.
const pristineLibraryDuTimeout = 3 * time.Minute

type pristineDuBudgetKey struct{}

// pristineDuTimeout is the bound for one du run: upstream's duTimeout unless
// the measurement was started through pristineMeasureOverviewSize for a row
// that is allowed longer.
func pristineDuTimeout(ctx context.Context) time.Duration {
	if budget, ok := ctx.Value(pristineDuBudgetKey{}).(time.Duration); ok && budget > duTimeout {
		return budget
	}
	return duTimeout
}

func pristineIsUserLibrary(path string) bool {
	home := os.Getenv("HOME")
	return home != "" && filepath.Clean(path) == filepath.Join(home, "Library")
}

// pristineOverviewContext gives the User Library row its longer du bound.
func pristineOverviewContext(ctx context.Context, path string) context.Context {
	if pristineIsUserLibrary(path) {
		return context.WithValue(ctx, pristineDuBudgetKey{}, pristineLibraryDuTimeout)
	}
	return ctx
}

// pristineMeasureOverviewSize measures one overview row (JSON mode).
//
// Upstream stores a row only when every failure was a permission denial. A
// User Library often also holds a cloud folder du can never read (File
// Provider's "Resource deadlock avoided" in ~/Library/CloudStorage), so its
// size was never stored and every overview spent another full traversal on the
// same answer. A Library du that finished with a size is stored as partial;
// one cut off by its bound is not, and --refresh measures it again.
func pristineMeasureOverviewSize(ctx context.Context, path string) (int64, error) {
	size, err := measureOverviewSize(pristineOverviewContext(ctx, path), path)
	if err != nil && size > 0 && pristineIsUserLibrary(path) && !overviewMeasurementStorable(size, err) &&
		ctx.Err() == nil && !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		_ = storeOverviewMeasurement(path, size, true)
	}
	return size, err
}

// pristineCachedOverviewMeasurement is the stored size of an overview row,
// or an error under --refresh so the row is measured again (and re-stored).
func pristineCachedOverviewMeasurement(path string) (int64, scanState, error) {
	if *pristineRefresh {
		return 0, scanComplete, errPristineRefresh
	}
	return loadOverviewCachedMeasurement(path)
}

// pristineScanDirectoryForJSON is upstream's JSON directory scan, bypassing
// the per-folder cache under --refresh.
func pristineScanDirectoryForJSON(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	if !*pristineRefresh {
		return scanPathConcurrentAllEntries(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath)
	}
	return scanPathConcurrentWithLimiter(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, true, 0, nil, scanCacheBypass, newScanPublication(ctx, nil))
}

var errPristineRefresh = errors.New("refresh requested")
