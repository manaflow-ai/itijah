const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test_filter", "Run only tests whose names contain this substring");
    const shared_uucode = b.option(bool, "shared_uucode", "Expect caller to inject a prebuilt 'uucode' module into itijah") orelse false;

    const fields: []const []const u8 = &.{
        "bidi_class",
        "bidi_paired_bracket",
        "joining_type",
        "is_bidi_mirrored",
    };
    const uucode = if (!shared_uucode)
        b.dependency("uucode", .{
            .target = target,
            .optimize = optimize,
            .fields = fields,
        }).module("uucode")
    else
        null;

    const mod = b.addModule("itijah", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (uucode) |u| mod.addImport("uucode", u);

    const internal_mod = mod;

    const tests = b.addTest(.{
        .root_module = internal_mod,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    if (b.lazyDependency("ucd", .{})) |ucd| {
        tests.root_module.addAnonymousImport("BidiTest", .{
            .root_source_file = ucd.path("BidiTest.txt"),
        });
        tests.root_module.addAnonymousImport("BidiCharTest", .{
            .root_source_file = ucd.path("BidiCharacterTest.txt"),
        });
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    if (std.Io.Dir.cwd().access(b.graph.io, "src/test/diff_oracle.zig", .{})) |_| {
        const diff_mod = b.createModule(.{
            .root_source_file = b.path("src/test/diff_oracle.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        diff_mod.addImport("itijah", internal_mod);

        const diff_exe = b.addExecutable(.{
            .name = "itijah-test-diff",
            .root_module = diff_mod,
        });
        diff_exe.root_module.linkSystemLibrary("fribidi", .{});

        const run_diff = b.addRunArtifact(diff_exe);
        const diff_step = b.step("test-diff", "Run deterministic differential tests vs FriBidi + ICU");
        diff_step.dependOn(&run_diff.step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "bench/bench.zig", .{})) |_| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        bench_mod.addImport("itijah", internal_mod);

        const bench_exe = b.addExecutable(.{
            .name = "itijah-bench",
            .root_module = bench_mod,
        });
        const run_bench = b.addRunArtifact(bench_exe);
        const bench_step = b.step("bench", "Run benchmarks");
        bench_step.dependOn(&run_bench.step);

        if (std.Io.Dir.cwd().access(b.graph.io, "bench/compare.zig", .{})) |_| {
            const compare_mod = b.createModule(.{
                .root_source_file = b.path("bench/compare.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .link_libc = true,
            });
            compare_mod.addImport("itijah", internal_mod);

            const compare_options = b.addOptions();
            var have_zabadi = false;
            if (std.Io.Dir.cwd().access(b.graph.io, "../zabadi/src/lib.zig", .{})) |_| {
                have_zabadi = true;
                const zabadi_mod = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = "../zabadi/src/lib.zig" },
                    .target = b.graph.host,
                    .optimize = .ReleaseFast,
                });
                const zabadi_uucode_fields: []const []const u8 = &.{
                    "bidi_class",
                    "bidi_paired_bracket",
                };
                const zabadi_uucode = uucode orelse b.dependency("uucode", .{
                    .target = b.graph.host,
                    .optimize = .ReleaseFast,
                    .fields = zabadi_uucode_fields,
                }).module("uucode");
                zabadi_mod.addImport("uucode", zabadi_uucode);
                compare_mod.addImport("zabadi", zabadi_mod);
            } else |_| {}
            compare_options.addOption(bool, "have_zabadi", have_zabadi);
            compare_mod.addImport("itijah_compare_options", compare_options.createModule());

            const compare_exe = b.addExecutable(.{
                .name = "itijah-compare",
                .root_module = compare_mod,
            });
            compare_exe.root_module.linkSystemLibrary("fribidi", .{});
            compare_exe.root_module.addCSourceFile(.{
                .file = b.path("bench/fribidi_memprobe.c"),
            });

            const run_compare = b.addRunArtifact(compare_exe);
            const compare_step = b.step("bench-compare", "Run itijah vs fribidi vs ICU comparison benchmark (optionally zabadi)");
            compare_step.dependOn(&run_compare.step);
        } else |_| {}
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "examples/basic.zig", .{})) |_| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        example_mod.addImport("itijah", internal_mod);

        const example_exe = b.addExecutable(.{
            .name = "itijah-example",
            .root_module = example_mod,
        });
        const run_example = b.addRunArtifact(example_exe);
        const example_step = b.step("example", "Run basic usage example");
        example_step.dependOn(&run_example.step);
    } else |_| {}

    const docs_obj = b.addObject(.{
        .name = "itijah-docs",
        .root_module = internal_mod,
    });
    const docs = docs_obj.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate docs");
    docs_step.dependOn(&install_docs.step);
}
