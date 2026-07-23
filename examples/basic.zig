const std = @import("std");
const itijah = @import("itijah");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // --- One-shot API ---
    // Simple and ergonomic. Allocates per call, caller frees via deinit(allocator).
    // Best for: single calls, tools, tests, anywhere allocation cost doesn't matter.

    const text = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', 0x05E2, 0x05D5, 0x05DC, 0x05DD }; // "Hello עולם"

    var dir: itijah.ParDirection = .auto_ltr;
    var emb = try itijah.getParEmbeddingLevels(allocator, &text, &dir);
    defer emb.deinit(allocator);

    std.debug.print("Resolved direction: {s}\n", .{@tagName(emb.resolved_par_dir)});
    std.debug.print("Levels: ", .{});
    for (emb.levels) |l| std.debug.print("{d} ", .{l});
    std.debug.print("\n", .{});

    var vis = try itijah.reorderLine(allocator, &text, emb.levels, dir.toLevel());
    defer vis.deinit(allocator);

    std.debug.print("Visual order: ", .{});
    for (vis.visual) |cp| std.debug.print("U+{X:0>4} ", .{cp});
    std.debug.print("\n\n", .{});

    // --- Scratch API ---
    // Reuses internal buffers across calls. Zero allocations after warmup.
    // Best for: render loops, terminals, editors — anything calling bidi per frame/line.

    var layout_scratch = itijah.VisualLayoutScratch{};
    defer layout_scratch.deinit(allocator);

    const lines = [_][]const u21{
        &text,
        &[_]u21{ 0x0645, 0x0631, 0x062D, 0x0628, 0x0627 }, // "مرحبا"
        &[_]u21{ 'Z', 'i', 'g', ' ', 'i', 's', ' ', 'f', 'a', 's', 't' }, // "Zig is fast"
    };

    for (lines, 0..) |line, i| {
        const view = try itijah.resolveVisualLayoutScratch(
            allocator,
            &layout_scratch,
            line,
            .{ .base_dir = .auto_ltr },
        );

        std.debug.print("Line {d}: {d} runs, base_level={d}\n", .{ i, view.runs.len, view.base_level });
        for (view.runs) |run| {
            std.debug.print("  run: visual[{d}..{d}] logical[{d}..{d}] {s}\n", .{
                run.visual_start,
                run.visualEnd(),
                run.logical_start,
                run.logicalEnd(),
                if (run.is_rtl) "RTL" else "LTR",
            });
        }
    }
}
