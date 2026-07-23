# itijah (اتجاه)

Zig-native implementation of the Unicode Bidirectional Algorithm ([UAX #9](https://unicode.org/reports/tr9/)).

Codepoint-based API inspired by FriBidi's design, implemented idiomatically in Zig with no global state and explicit allocator passing. Competitive with FriBidi and ICU; faster on LTR and mixed-direction text, with scratch APIs for allocation-light high-throughput loops.

## Contents

- [Status](#status) — implemented rules and roadmap
- [API](#api) — quick reference with code examples
- [Usage Guide](docs/usage.md) — choosing between owned and scratch APIs, memory ownership, terminal integration
- [Benchmarks](docs/benchmarks.md) — performance comparison vs zabadi, fribidi, ICU
- [Compatibility](docs/compatibility.md) — conformance results and differential testing
- [Building](#building) — build commands and dependencies
- [Examples](examples/basic.zig) — runnable example

## Status

### Implemented

| Rule | Description | Status |
|------|------------|--------|
| P2-P3 | Paragraph direction detection | Done |
| X1-X8 | Explicit embeddings, overrides, isolates | Done |
| X9 | Remove explicit codes (marked BN) | Done |
| W1-W7 | Weak type resolution | Done |
| N0 | Bracket pair resolution | Done (BD16 pairing scoped per IRS) |
| N1-N2 | Neutral type resolution | Done |
| I1-I2 | Implicit level resolution | Done |
| L1 | Reset segment/paragraph separators | Done (parts 1-3) |
| L2 | Reorder by level | Done |

### Not yet implemented

| Rule | Description |
|------|------------|
| L3 | Combining mark (NSM) reordering |
| L4 | Mirroring (data table ready, application pending) |

These are cosmetic refinements that don't affect terminal integration — terminal shapers (HarfBuzz, CoreText) handle combining marks and mirroring at the glyph level.

### Roadmap

- **L3/L4 completion** — combining mark reordering and mirroring application for non-shaper consumers
- **Arabic joining (R1-R7)** — currently out of scope; handled by shaping engines (HarfBuzz, CoreText) in terminal/GUI contexts
- **Arabic shaping (presentation forms)** — useful for environments without a shaper
- **C ABI wrapper** — stable binary interface for non-Zig consumers

## Validation

- Full Unicode conformance: `BidiTest failed=0`, `BidiCharacterTest failed=0`
- FriBidi parity: `11/12 PASS` (known delta: strict BD16 IRS-local pairing in one synthetic case)
- Details: [docs/compatibility.md](docs/compatibility.md) | [docs/benchmarks.md](docs/benchmarks.md)

## N0 Bracket Pairing

`itijah` follows UAX #9 BD16 with IRS-scoped bracket pairing. Pair candidates are collected independently per Isolating Run Sequence. This can diverge from FriBidi on rare synthetic isolate/bracket mixes. Validated by dedicated regression tests and full Unicode conformance.

## API

```zig
const itijah = @import("itijah");

// One-shot: allocates per call, caller frees via deinit(allocator)
var dir: itijah.ParDirection = .auto_ltr;
var emb = try itijah.getParEmbeddingLevels(allocator, codepoints, &dir);
defer emb.deinit(allocator);

var vis = try itijah.reorderLine(allocator, codepoints, emb.levels, dir.toLevel());
defer vis.deinit(allocator);
```

Fast preflight for terminal/editor rows:

```zig
if (!itijah.hasStrongRtl(row_codepoints)) {
    // Host renderer can keep its normal LTR path.
}
```

Scratch APIs reuse buffers across calls — zero allocations after warmup:

```zig
// Create once, reuse across frames/lines
var scratch = itijah.VisualLayoutScratch{};
defer scratch.deinit(allocator);

// Per-line in render loop (zero allocs after warmup)
const layout = try itijah.resolveVisualLayoutScratch(allocator, &scratch, codepoints, .{
    .base_dir = .ltr,
});
// layout.levels, layout.runs, layout.l_to_v, layout.v_to_l — scratch-owned views
```

For the full API surface, ownership model, and integration guide, see [docs/usage.md](docs/usage.md).

## Terminal Integration

Minimal row pipeline (left-anchored terminal row, line-scoped bidi):

```zig
var bidi_scratch = itijah.VisualLayoutScratch{}; // create once, reuse across frames
defer bidi_scratch.deinit(allocator);

const layout = try itijah.resolveVisualLayoutScratch(allocator, &bidi_scratch, row_codepoints, .{
    .base_dir = .ltr,
});

for (layout.runs) |run| {
    // Feed shaper in logical order for this run's contiguous logical slice.
    const logical_start = run.logical_start;
    const logical_end = run.logical_start + run.len;
    var logical_i = logical_start;
    while (logical_i < logical_end) : (logical_i += 1) {
        // Cluster is visual offset inside the run (terminal-critical mapping).
        const cluster = itijah.clusterForLogical(run, logical_i);
        shape_input.append(.{
            .cp = row_codepoints[logical_i],
            .cluster = cluster,
        });
    }

    // After shaping, place glyphs by visual x for this run.
}
```

## API / ABI Stability

`itijah` is currently a Zig source package API (not a stable C ABI).

- Public Zig APIs are intended to be maintainable and allocator-explicit.
- A stable binary ABI across Zig compiler versions is not guaranteed.
- If you need a stable C ABI boundary, expose a dedicated C wrapper layer and version it explicitly.

For now, keep API usage pinned to a tagged release and the documented minimum Zig version.

## Building

```sh
zig build        # build library
zig build test   # run tests
zig build bench  # run itijah benchmark report
zig build bench-compare  # compare itijah vs fribidi vs ICU
zig build test-diff  # differential harness vs fribidi + ICU (deterministic generator)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch policy, required checks, release gate, and performance workflow.

Requires Zig 0.16.0+.

## Dependencies

- [uucode](https://github.com/jacobsandlund/uucode) v0.2.0 — Unicode property lookups
- [UCD](https://www.unicode.org/Public/zipped/16.0.0/UCD.zip) — conformance test data (lazy, test-only)
- For `bench-compare`:
  - system FriBidi headers + library
  - ICU runtime library (`icuuc`) available on host (loaded dynamically)
- For `test-diff`:
  - system FriBidi headers + library
  - ICU runtime library (`icuuc`) available on host (loaded dynamically)

### Shared `uucode` integration

If a host app already creates a `uucode` module (for example to avoid duplicate module instances in a mono-build), depend on `itijah` with:

```zig
const itijah_dep = b.dependency("itijah", .{
    .target = target,
    .optimize = optimize,
    .shared_uucode = true,
});
const itijah_mod = itijah_dep.module("itijah");
itijah_mod.addImport("uucode", shared_uucode_mod);
```

When `shared_uucode = true`, `itijah` exports the library module without creating its own `uucode` import, so the caller can inject a shared one.
For standalone development in this repository, run build/test commands without that flag.

### `bench-compare` setup

macOS (Homebrew):

```sh
brew install fribidi icu4c
```

## Benchmarks

Detailed tables, environment, and methodology: [docs/benchmarks.md](docs/benchmarks.md).

`bench-compare` measures `itijah` vs [`zabadi`](https://git.sr.ht/~asibahi/zabadi), [`fribidi`](https://github.com/fribidi/fribidi), and [ICU](https://unicode-org.github.io/icu/userguide/icu4c/) across `analysis` and `reorder_line` for LTR/RTL/MIXED corpora at `16`, `64`, `256`, `512`, `1024`, with optional huge sizes `262144`, `524288`, and `1048576`.

```sh
zig build bench                                        # itijah-only report
zig build bench-compare                                # itijah vs zabadi vs fribidi vs ICU
ITIJAH_COMPARE_INCLUDE_HUGE=1 zig build bench-compare  # include 262K-1M sizes
```

Benchmark sources (`bench/`) are not exported in package `.paths` — run from source checkout.

## Testing

```sh
zig build test                                         # filtered (fast CI mode)
ITIJAH_CONFORMANCE_MODE=full zig build test             # full Unicode conformance
zig build test-diff                                    # differential vs fribidi + ICU
```

Full conformance: `BidiTest failed=0`, `BidiCharacterTest failed=0`.

See [docs/compatibility.md](docs/compatibility.md) for parity status and differential harness details.

## License

MIT
