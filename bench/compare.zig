const std = @import("std");
const itijah = @import("itijah");
const compare_options = @import("itijah_compare_options");
const have_zabadi = compare_options.have_zabadi;
const zbd = if (have_zabadi) @import("zabadi") else struct {};

const c = @cImport({
    @cInclude("fribidi.h");
});

extern fn itijah_fribidi_probe_available() c_int;
extern fn itijah_fribidi_probe_begin() void;
extern fn itijah_fribidi_probe_finish(alloc_count: *u64, allocated_bytes: *u64, peak_bytes: *u64) void;

const Allocator = std.mem.Allocator;

const Op = enum {
    analysis,
    reorder_line,
};

const Impl = enum {
    itijah,
    zabadi,
    fribidi,
    icu,
};

const Metrics = struct {
    ns: u64,
    alloc_count: usize,
    allocated_bytes: usize,
    peak_bytes: usize,
};

const Aggregate = struct {
    iterations: usize = 0,
    total_ns: u128 = 0,
    total_alloc_count: u128 = 0,
    total_allocated_bytes: u128 = 0,
    total_peak_bytes: u128 = 0,

    fn add(self: *Aggregate, m: Metrics) void {
        self.iterations += 1;
        self.total_ns += m.ns;
        self.total_alloc_count += m.alloc_count;
        self.total_allocated_bytes += m.allocated_bytes;
        self.total_peak_bytes += m.peak_bytes;
    }

    fn meanNs(self: Aggregate) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iterations));
    }

    fn meanAllocCount(self: Aggregate) f64 {
        return @as(f64, @floatFromInt(self.total_alloc_count)) / @as(f64, @floatFromInt(self.iterations));
    }

    fn meanAllocatedBytes(self: Aggregate) f64 {
        return @as(f64, @floatFromInt(self.total_allocated_bytes)) / @as(f64, @floatFromInt(self.iterations));
    }

    fn meanPeakBytes(self: Aggregate) f64 {
        return @as(f64, @floatFromInt(self.total_peak_bytes)) / @as(f64, @floatFromInt(self.iterations));
    }
};

const MeasuringAllocator = struct {
    parent: Allocator,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocation_count: usize = 0,
    allocated_bytes: usize = 0,

    fn init(parent: Allocator) MeasuringAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *MeasuringAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn onGrow(self: *MeasuringAllocator, amount: usize) void {
        self.current_bytes += amount;
        self.allocated_bytes += amount;
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MeasuringAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) {
            self.allocation_count += 1;
            self.onGrow(len);
        }
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MeasuringAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.parent.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            self.allocation_count += 1;
            if (new_len > buf.len) {
                self.onGrow(new_len - buf.len);
            } else {
                self.current_bytes -= (buf.len - new_len);
            }
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MeasuringAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr);
        if (ptr != null) {
            self.allocation_count += 1;
            if (new_len > buf.len) {
                self.onGrow(new_len - buf.len);
            } else {
                self.current_bytes -= (buf.len - new_len);
            }
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MeasuringAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
        self.current_bytes -= buf.len;
    }

    const IterationState = struct {
        start_current_bytes: usize,
    };

    fn beginIteration(self: *MeasuringAllocator) IterationState {
        const state = IterationState{ .start_current_bytes = self.current_bytes };
        self.allocation_count = 0;
        self.allocated_bytes = 0;
        self.peak_bytes = self.current_bytes;
        return state;
    }

    fn endIteration(self: *MeasuringAllocator, state: IterationState, ns: u64) Metrics {
        return .{
            .ns = ns,
            .alloc_count = self.allocation_count,
            .allocated_bytes = self.allocated_bytes,
            .peak_bytes = self.peak_bytes -| state.start_current_bytes,
        };
    }
};

const ItijahScratchContext = struct {
    embedding: itijah.EmbeddingScratch = .{},
    reorder: itijah.ReorderScratch = .{},

    fn deinit(self: *ItijahScratchContext, allocator: Allocator) void {
        self.embedding.deinit(allocator);
        self.reorder.deinit(allocator);
    }
};

const Case = struct {
    name: []const u8,
    cps: []const u21,
};

const FribidiResult = struct {
    len: usize,
    levels: [1024]c.FriBidiLevel,
    v_to_l: [1024]u32,
};

const Mismatch = struct {
    kind: enum { levels, v_to_l },
    index: usize,
    expected: u32,
    actual: u32,
};

const UBiDi = opaque {};
const UChar = u16;
const UBiDiLevel = u8;
const UErrorCode = c_int;
const U_ZERO_ERROR: UErrorCode = 0;
const UBIDI_DEFAULT_LTR: UBiDiLevel = 0xFE;
const huge_lengths = [_]usize{ 262_144, 524_288, 1_048_576 };
const CorpusKind = enum {
    ltr,
    rtl,
    mixed,
};

const IcuApi = struct {
    lib: std.DynLib,
    major: u8,
    openSized: *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi,
    close: *const fn (*UBiDi) callconv(.c) void,
    setPara: *const fn (*UBiDi, [*]const UChar, c_int, UBiDiLevel, ?[*]UBiDiLevel, *UErrorCode) callconv(.c) void,
    getLevels: *const fn (*UBiDi, *UErrorCode) callconv(.c) [*]const UBiDiLevel,
    getVisualMap: *const fn (*UBiDi, [*]c_int, *UErrorCode) callconv(.c) void,

    fn deinit(self: *IcuApi) void {
        self.lib.close();
    }
};

const FribidiBuffers = struct {
    chars: []c.FriBidiChar = &.{},
    types: []c.FriBidiCharType = &.{},
    brackets: []c.FriBidiBracketType = &.{},
    levels: []c.FriBidiLevel = &.{},
    visual: []c.FriBidiChar = &.{},
    map: []c.FriBidiStrIndex = &.{},

    fn init(allocator: Allocator, len: usize) !FribidiBuffers {
        var buffers: FribidiBuffers = .{};
        buffers.chars = try allocator.alloc(c.FriBidiChar, len);
        errdefer allocator.free(buffers.chars);
        buffers.types = try allocator.alloc(c.FriBidiCharType, len);
        errdefer allocator.free(buffers.types);
        buffers.brackets = try allocator.alloc(c.FriBidiBracketType, len);
        errdefer allocator.free(buffers.brackets);
        buffers.levels = try allocator.alloc(c.FriBidiLevel, len);
        errdefer allocator.free(buffers.levels);
        buffers.visual = try allocator.alloc(c.FriBidiChar, len);
        errdefer allocator.free(buffers.visual);
        buffers.map = try allocator.alloc(c.FriBidiStrIndex, len);
        return buffers;
    }

    fn deinit(self: *FribidiBuffers, allocator: Allocator) void {
        allocator.free(self.map);
        allocator.free(self.visual);
        allocator.free(self.levels);
        allocator.free(self.brackets);
        allocator.free(self.types);
        allocator.free(self.chars);
        self.* = .{};
    }
};

const IcuBuffers = struct {
    map: []c_int = &.{},

    fn init(allocator: Allocator, len: usize) !IcuBuffers {
        return .{
            .map = try allocator.alloc(c_int, len),
        };
    }

    fn deinit(self: *IcuBuffers, allocator: Allocator) void {
        allocator.free(self.map);
        self.* = .{};
    }
};

fn generateLtrCorpus(comptime n: usize) [n]u21 {
    @setEvalBranchQuota(500_000);
    var buf: [n]u21 = undefined;
    for (0..n) |i| buf[i] = @intCast('A' + (i % 26));
    return buf;
}

fn generateRtlCorpus(comptime n: usize) [n]u21 {
    @setEvalBranchQuota(500_000);
    var buf: [n]u21 = undefined;
    for (0..n) |i| buf[i] = @intCast(0x05D0 + (i % 27));
    return buf;
}

fn generateMixedCorpus(comptime n: usize) [n]u21 {
    @setEvalBranchQuota(500_000);
    var buf: [n]u21 = undefined;
    for (0..n) |i| {
        if (i % 4 == 0) {
            buf[i] = @intCast(0x05D0 + (i % 27));
        } else if (i % 5 == 0) {
            buf[i] = @intCast('0' + (i % 10));
        } else if (i % 7 == 0) {
            buf[i] = '(';
        } else if (i % 9 == 0) {
            buf[i] = ')';
        } else if (i % 11 == 0) {
            buf[i] = 0x2067;
        } else if (i % 13 == 0) {
            buf[i] = 0x2069;
        } else if (i % 17 == 0) {
            buf[i] = ' ';
        } else {
            buf[i] = @intCast('a' + (i % 26));
        }
    }
    return buf;
}

fn corpusKindName(kind: CorpusKind) []const u8 {
    return switch (kind) {
        .ltr => "LTR",
        .rtl => "RTL",
        .mixed => "MIXED",
    };
}

fn generateCorpusOwned(allocator: Allocator, kind: CorpusKind, n: usize) ![]u21 {
    const cps = try allocator.alloc(u21, n);
    for (0..n) |i| {
        cps[i] = switch (kind) {
            .ltr => @intCast('A' + (i % 26)),
            .rtl => @intCast(0x05D0 + (i % 27)),
            .mixed => blk: {
                if (i % 4 == 0) break :blk @as(u21, @intCast(0x05D0 + (i % 27)));
                if (i % 5 == 0) break :blk @as(u21, @intCast('0' + (i % 10)));
                if (i % 7 == 0) break :blk '(';
                if (i % 9 == 0) break :blk ')';
                if (i % 11 == 0) break :blk 0x2067;
                if (i % 13 == 0) break :blk 0x2069;
                if (i % 17 == 0) break :blk ' ';
                break :blk @as(u21, @intCast('a' + (i % 26)));
            },
        };
    }
    return cps;
}

const ltr_16 = generateLtrCorpus(16);
const ltr_64 = generateLtrCorpus(64);
const ltr_256 = generateLtrCorpus(256);
const ltr_512 = generateLtrCorpus(512);
const ltr_1024 = generateLtrCorpus(1024);
const rtl_16 = generateRtlCorpus(16);
const rtl_64 = generateRtlCorpus(64);
const rtl_256 = generateRtlCorpus(256);
const rtl_512 = generateRtlCorpus(512);
const rtl_1024 = generateRtlCorpus(1024);
const mixed_16 = generateMixedCorpus(16);
const mixed_64 = generateMixedCorpus(64);
const mixed_256 = generateMixedCorpus(256);
const mixed_512 = generateMixedCorpus(512);
const mixed_1024 = generateMixedCorpus(1024);
const ltr_2048 = generateLtrCorpus(2048);
const ltr_4096 = generateLtrCorpus(4096);
const ltr_8192 = generateLtrCorpus(8192);
const ltr_16384 = generateLtrCorpus(16_384);
const rtl_2048 = generateRtlCorpus(2048);
const rtl_4096 = generateRtlCorpus(4096);
const rtl_8192 = generateRtlCorpus(8192);
const rtl_16384 = generateRtlCorpus(16_384);
const mixed_2048 = generateMixedCorpus(2048);
const mixed_4096 = generateMixedCorpus(4096);
const mixed_8192 = generateMixedCorpus(8192);
const mixed_16384 = generateMixedCorpus(16_384);

const parity_cases = [_]Case{
    .{ .name = "LTR-16", .cps = &ltr_16 },
    .{ .name = "LTR-64", .cps = &ltr_64 },
    .{ .name = "LTR-256", .cps = &ltr_256 },
    .{ .name = "LTR-1024", .cps = &ltr_1024 },
    .{ .name = "RTL-16", .cps = &rtl_16 },
    .{ .name = "RTL-64", .cps = &rtl_64 },
    .{ .name = "RTL-256", .cps = &rtl_256 },
    .{ .name = "RTL-1024", .cps = &rtl_1024 },
    .{ .name = "MIXED-16", .cps = &mixed_16 },
    .{ .name = "MIXED-64", .cps = &mixed_64 },
    .{ .name = "MIXED-256", .cps = &mixed_256 },
    .{ .name = "MIXED-1024", .cps = &mixed_1024 },
};

const bench_cases = [_]Case{
    .{ .name = "LTR-16", .cps = &ltr_16 },
    .{ .name = "LTR-64", .cps = &ltr_64 },
    .{ .name = "LTR-256", .cps = &ltr_256 },
    .{ .name = "LTR-512", .cps = &ltr_512 },
    .{ .name = "LTR-1024", .cps = &ltr_1024 },

    .{ .name = "RTL-16", .cps = &rtl_16 },
    .{ .name = "RTL-64", .cps = &rtl_64 },
    .{ .name = "RTL-256", .cps = &rtl_256 },
    .{ .name = "RTL-512", .cps = &rtl_512 },
    .{ .name = "RTL-1024", .cps = &rtl_1024 },

    .{ .name = "MIXED-16", .cps = &mixed_16 },
    .{ .name = "MIXED-64", .cps = &mixed_64 },
    .{ .name = "MIXED-256", .cps = &mixed_256 },
    .{ .name = "MIXED-512", .cps = &mixed_512 },
    .{ .name = "MIXED-1024", .cps = &mixed_1024 },
};

fn encodeUtf16(allocator: Allocator, cps: []const u21) ![]u16 {
    var out: std.ArrayListUnmanaged(u16) = .empty;
    errdefer out.deinit(allocator);

    for (cps) |cp| {
        if (cp <= 0xFFFF) {
            try out.append(allocator, @intCast(cp));
        } else {
            const x = cp - 0x10000;
            try out.append(allocator, @intCast(0xD800 + (x >> 10)));
            try out.append(allocator, @intCast(0xDC00 + (x & 0x3FF)));
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn encodeUtf8(allocator: Allocator, cps: []const u21) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var scratch: [4]u8 = undefined;
    for (cps) |cp| {
        const len = try std.unicode.utf8Encode(cp, &scratch);
        try out.appendSlice(allocator, scratch[0..len]);
    }

    return try out.toOwnedSlice(allocator);
}

fn iterationsForLen(len: usize) usize {
    if (len <= 16) return 60_000;
    if (len <= 64) return 40_000;
    if (len <= 256) return 12_000;
    if (len <= 512) return 6_000;
    if (len <= 1024) return 3_000;
    if (len <= 2048) return 1_500;
    if (len <= 4096) return 800;
    if (len <= 8_192) return 250;
    if (len <= 16_384) return 120;
    if (len <= 32_768) return 60;
    if (len <= 65_536) return 30;
    if (len <= 131_072) return 15;
    if (len <= 262_144) return 8;
    if (len <= 524_288) return 4;
    if (len <= 1_048_576) return 2;
    return 1;
}

fn warmupForLen(len: usize) usize {
    if (len <= 64) return 100;
    if (len <= 256) return 60;
    if (len <= 512) return 40;
    if (len <= 1024) return 30;
    if (len <= 4096) return 15;
    if (len <= 8_192) return 8;
    if (len <= 16_384) return 5;
    if (len <= 32_768) return 3;
    if (len <= 65_536) return 2;
    return 1;
}

fn lookupVersioned(lib: *std.DynLib, comptime T: type, base: []const u8, major: u8) ?T {
    var symbol_buf: [64]u8 = undefined;
    const symbol = std.fmt.bufPrintZ(&symbol_buf, "{s}_{d}", .{ base, major }) catch return null;
    return lib.lookup(T, symbol);
}

fn detectIcuMajor(lib: *std.DynLib) ?u8 {
    var major: usize = 50;
    while (major < 100) : (major += 1) {
        if (lookupVersioned(lib, *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi, "ubidi_openSized", @intCast(major)) != null) {
            return @intCast(major);
        }
    }
    return null;
}

fn loadIcuApi() !IcuApi {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/icu4c/lib/libicuuc.dylib",
        "libicuuc.dylib",
        "libicuuc.so",
        "libicuuc.so.78",
        "libicuuc.so.77",
        "libicuuc.so.76",
        "icuuc.dll",
    };

    for (candidates) |candidate| {
        var lib = std.DynLib.open(candidate) catch continue;
        errdefer lib.close();

        const major = detectIcuMajor(&lib) orelse continue;

        const openSized = lookupVersioned(&lib, *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi, "ubidi_openSized", major) orelse continue;
        const close = lookupVersioned(&lib, *const fn (*UBiDi) callconv(.c) void, "ubidi_close", major) orelse continue;
        const setPara = lookupVersioned(&lib, *const fn (*UBiDi, [*]const UChar, c_int, UBiDiLevel, ?[*]UBiDiLevel, *UErrorCode) callconv(.c) void, "ubidi_setPara", major) orelse continue;
        const getLevels = lookupVersioned(&lib, *const fn (*UBiDi, *UErrorCode) callconv(.c) [*]const UBiDiLevel, "ubidi_getLevels", major) orelse continue;
        const getVisualMap = lookupVersioned(&lib, *const fn (*UBiDi, [*]c_int, *UErrorCode) callconv(.c) void, "ubidi_getVisualMap", major) orelse continue;

        return .{
            .lib = lib,
            .major = major,
            .openSized = openSized,
            .close = close,
            .setPara = setPara,
            .getLevels = getLevels,
            .getVisualMap = getVisualMap,
        };
    }

    return error.IcuLibraryNotFound;
}

fn runItijah(allocator: Allocator, op: Op, cps: []const u21) !void {
    var dir: itijah.ParDirection = .auto_ltr;
    var emb = try itijah.getParEmbeddingLevels(allocator, cps, &dir);
    defer emb.deinit(allocator);

    switch (op) {
        .analysis => {},
        .reorder_line => {
            const visual = try itijah.reorderVisualOnly(allocator, cps, emb.levels, dir.toLevel());
            allocator.free(visual);
        },
    }
}

fn runItijahScratch(
    allocator: Allocator,
    ctx: *ItijahScratchContext,
    op: Op,
    cps: []const u21,
) !void {
    switch (op) {
        .analysis => {
            var dir: itijah.ParDirection = .auto_ltr;
            _ = try itijah.getParEmbeddingLevelsScratchView(allocator, &ctx.embedding, cps, &dir);
        },
        .reorder_line => {
            var dir: itijah.ParDirection = .auto_ltr;
            const emb = try itijah.getParEmbeddingLevelsScratchView(allocator, &ctx.embedding, cps, &dir);
            _ = try itijah.reorderVisualOnlyScratch(allocator, &ctx.reorder, cps, emb.levels, dir.toLevel());
        },
    }
}

fn runZabadi(allocator: Allocator, op: Op, utf8: []const u8) !void {
    if (!have_zabadi) return error.ZabadiUnavailable;

    var info = try zbd.BidiInfo.new(
        allocator,
        utf8,
        zbd.data.hardcoded_data(),
        null,
    );
    defer info.deinit(allocator);

    if (op == .reorder_line) {
        for (info.paragraphs) |para| {
            const reordered = try info.reorder_line(allocator, para, para.range);
            defer if (reordered) |owned| allocator.free(owned);
        }
    }
}

fn runFribidi(op: Op, cps: []const u21, buffers: *FribidiBuffers) !void {
    if (cps.len > buffers.chars.len) return error.InputTooLong;

    const len: c.FriBidiStrIndex = @intCast(cps.len);
    const chars = buffers.chars[0..cps.len];
    const types = buffers.types[0..cps.len];
    const brackets = buffers.brackets[0..cps.len];
    const levels = buffers.levels[0..cps.len];
    const visual = buffers.visual[0..cps.len];
    const map = buffers.map[0..cps.len];

    for (cps, 0..) |cp, i| {
        chars[i] = @intCast(cp);
        map[i] = @intCast(i);
    }

    c.fribidi_get_bidi_types(chars.ptr, len, types.ptr);
    c.fribidi_get_bracket_types(chars.ptr, len, types.ptr, brackets.ptr);

    var par_dir: c.FriBidiParType = c.FRIBIDI_PAR_ON;
    const max_level = c.fribidi_get_par_embedding_levels_ex(types.ptr, brackets.ptr, len, &par_dir, levels.ptr);
    if (max_level == 0) return error.FribidiFailed;

    if (op == .reorder_line) {
        for (cps, 0..) |cp, i| visual[i] = @intCast(cp);
        const reordered_level = c.fribidi_reorder_line(
            c.FRIBIDI_FLAGS_DEFAULT,
            types.ptr,
            len,
            0,
            par_dir,
            levels.ptr,
            visual.ptr,
            map.ptr,
        );
        if (reordered_level == 0) return error.FribidiFailed;
    }
}

fn runIcu(icu: *const IcuApi, op: Op, utf16: []const u16, buffers: *IcuBuffers) !void {
    if (utf16.len > buffers.map.len) return error.InputTooLong;

    var status: UErrorCode = U_ZERO_ERROR;
    const bidi = icu.openSized(@intCast(utf16.len), 0, &status) orelse return error.IcuFailed;
    defer icu.close(bidi);
    if (status != U_ZERO_ERROR) return error.IcuFailed;

    status = U_ZERO_ERROR;
    icu.setPara(bidi, utf16.ptr, @intCast(utf16.len), UBIDI_DEFAULT_LTR, null, &status);
    if (status != U_ZERO_ERROR) return error.IcuFailed;

    status = U_ZERO_ERROR;
    _ = icu.getLevels(bidi, &status);
    if (status != U_ZERO_ERROR) return error.IcuFailed;

    if (op == .reorder_line) {
        const map = buffers.map[0..utf16.len];
        status = U_ZERO_ERROR;
        icu.getVisualMap(bidi, map.ptr, &status);
        if (status != U_ZERO_ERROR) return error.IcuFailed;
    }
}

fn computeFribidi(cps: []const u21) !FribidiResult {
    if (cps.len > 1024) return error.InputTooLong;

    const len: c.FriBidiStrIndex = @intCast(cps.len);
    var chars: [1024]c.FriBidiChar = undefined;
    var types: [1024]c.FriBidiCharType = undefined;
    var brackets: [1024]c.FriBidiBracketType = undefined;
    var levels: [1024]c.FriBidiLevel = undefined;
    var levels_before_reorder: [1024]c.FriBidiLevel = undefined;
    var visual: [1024]c.FriBidiChar = undefined;
    var map: [1024]c.FriBidiStrIndex = undefined;
    var v_to_l: [1024]u32 = undefined;

    for (cps, 0..) |cp, i| {
        chars[i] = @intCast(cp);
        visual[i] = @intCast(cp);
        map[i] = @intCast(i);
        v_to_l[i] = @intCast(i);
    }

    c.fribidi_get_bidi_types(&chars, len, &types);
    c.fribidi_get_bracket_types(&chars, len, &types, &brackets);

    var par_dir: c.FriBidiParType = c.FRIBIDI_PAR_ON;
    const max_level = c.fribidi_get_par_embedding_levels_ex(&types, &brackets, len, &par_dir, &levels);
    if (max_level == 0) return error.FribidiFailed;
    @memcpy(levels_before_reorder[0..cps.len], levels[0..cps.len]);

    var reorder_levels: [1024]c.FriBidiLevel = undefined;
    @memcpy(reorder_levels[0..cps.len], levels_before_reorder[0..cps.len]);

    const reordered_level = c.fribidi_reorder_line(
        c.FRIBIDI_FLAGS_DEFAULT,
        &types,
        len,
        0,
        par_dir,
        &reorder_levels,
        &visual,
        &map,
    );
    if (reordered_level == 0) return error.FribidiFailed;

    for (0..cps.len) |i| {
        v_to_l[i] = @intCast(map[i]);
    }

    return .{
        .len = cps.len,
        .levels = levels_before_reorder,
        .v_to_l = v_to_l,
    };
}

fn fribidiParityCase(allocator: Allocator, case: Case) !?Mismatch {
    const fri = try computeFribidi(case.cps);

    var layout = try itijah.resolveVisualLayout(allocator, case.cps, .{ .base_dir = .auto_ltr });
    defer layout.deinit(allocator);

    if (layout.levels.len != fri.len) return .{
        .kind = .levels,
        .index = 0,
        .expected = @intCast(fri.len),
        .actual = @intCast(layout.levels.len),
    };
    for (layout.levels, 0..) |lvl, i| {
        const expected: u32 = @intCast(fri.levels[i]);
        const actual: u32 = lvl;
        if (actual != expected) {
            return .{
                .kind = .levels,
                .index = i,
                .expected = expected,
                .actual = actual,
            };
        }
    }

    if (layout.v_to_l.len != fri.len) return .{
        .kind = .v_to_l,
        .index = 0,
        .expected = @intCast(fri.len),
        .actual = @intCast(layout.v_to_l.len),
    };
    for (layout.v_to_l, 0..) |idx, i| {
        const expected = fri.v_to_l[i];
        const actual = idx;
        if (actual != expected) {
            return .{
                .kind = .v_to_l,
                .index = i,
                .expected = expected,
                .actual = actual,
            };
        }
    }

    // Terminal-focused parity: run-derived mapping must reconstruct v_to_l.
    var rebuilt: std.ArrayListUnmanaged(u32) = .empty;
    defer rebuilt.deinit(allocator);
    try rebuilt.ensureTotalCapacity(allocator, layout.v_to_l.len);
    for (layout.runs) |run| {
        if (run.is_rtl) {
            var i = run.len;
            while (i > 0) {
                i -= 1;
                try rebuilt.append(allocator, run.logical_start + i);
            }
        } else {
            for (0..run.len) |i| {
                try rebuilt.append(allocator, run.logical_start + @as(u32, @intCast(i)));
            }
        }
    }
    for (rebuilt.items, 0..) |logical_idx, i| {
        if (logical_idx != layout.v_to_l[i]) {
            return .{
                .kind = .v_to_l,
                .index = i,
                .expected = layout.v_to_l[i],
                .actual = logical_idx,
            };
        }
    }

    return null;
}

fn parityOnlyMode(environ: std.process.Environ) bool {
    const flag = environ.getAlloc(std.heap.page_allocator, "ITIJAH_COMPARE_ONLY_PARITY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(flag);
    return std.mem.eql(u8, flag, "1") or std.ascii.eqlIgnoreCase(flag, "true");
}

fn includeHugeMode(environ: std.process.Environ) bool {
    const flag = environ.getAlloc(std.heap.page_allocator, "ITIJAH_COMPARE_INCLUDE_HUGE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(flag);
    return std.mem.eql(u8, flag, "1") or std.ascii.eqlIgnoreCase(flag, "true");
}

fn printCaseCps(writer: *std.Io.Writer, cps: []const u21) !void {
    for (cps, 0..) |cp, i| {
        try writer.print("{X:0>4}", .{cp});
        if (i + 1 != cps.len) try writer.writeAll(" ");
    }
    try writer.writeAll("\n");
}

fn printLevelMismatchContext(
    writer: *std.Io.Writer,
    allocator: Allocator,
    case: Case,
    mismatch_idx: usize,
) !void {
    const fri = try computeFribidi(case.cps);

    var dir: itijah.ParDirection = .auto_ltr;
    var emb = try itijah.getParEmbeddingLevels(allocator, case.cps, &dir);
    defer emb.deinit(allocator);

    const start = mismatch_idx -| 8;
    const end = @min(mismatch_idx + 9, case.cps.len);
    try writer.writeAll("    level-context (idx cp expected actual):\n");
    for (start..end) |i| {
        try writer.print(
            "      {d:>4} U+{X:0>4} {d:>3} {d:>3}\n",
            .{ i, case.cps[i], @as(u32, @intCast(fri.levels[i])), @as(u32, emb.levels[i]) },
        );
    }
}

fn measureOne(
    impl: Impl,
    op: Op,
    cps: []const u21,
    utf8: []const u8,
    utf16: []const u16,
    icu: *const IcuApi,
    fribidi_buffers: ?*FribidiBuffers,
    icu_buffers: ?*IcuBuffers,
) !Metrics {
    switch (impl) {
        .itijah => {
            var m = MeasuringAllocator.init(std.heap.c_allocator);
            const alloc = m.allocator();

            var timer = try std.time.Timer.start();
            try runItijah(alloc, op, cps);
            return .{
                .ns = timer.read(),
                .alloc_count = m.allocation_count,
                .allocated_bytes = m.allocated_bytes,
                .peak_bytes = m.peak_bytes,
            };
        },
        .zabadi => {
            if (!have_zabadi) return error.ZabadiUnavailable;

            var m = MeasuringAllocator.init(std.heap.c_allocator);
            const alloc = m.allocator();

            var timer = try std.time.Timer.start();
            try runZabadi(alloc, op, utf8);
            return .{
                .ns = timer.read(),
                .alloc_count = m.allocation_count,
                .allocated_bytes = m.allocated_bytes,
                .peak_bytes = m.peak_bytes,
            };
        },
        .fribidi, .icu => {
            if (itijah_fribidi_probe_available() == 0) return error.MemoryProbeUnavailable;

            var alloc_count: u64 = 0;
            var allocated_bytes: u64 = 0;
            var peak_bytes: u64 = 0;

            itijah_fribidi_probe_begin();
            errdefer itijah_fribidi_probe_finish(&alloc_count, &allocated_bytes, &peak_bytes);

            var timer = try std.time.Timer.start();
            switch (impl) {
                .fribidi => try runFribidi(op, cps, fribidi_buffers orelse return error.MissingBenchBuffers),
                .icu => try runIcu(icu, op, utf16, icu_buffers orelse return error.MissingBenchBuffers),
                .itijah => unreachable,
                .zabadi => unreachable,
            }
            const ns = timer.read();
            itijah_fribidi_probe_finish(&alloc_count, &allocated_bytes, &peak_bytes);

            return .{
                .ns = ns,
                .alloc_count = @intCast(alloc_count),
                .allocated_bytes = @intCast(allocated_bytes),
                .peak_bytes = @intCast(peak_bytes),
            };
        },
    }
}

fn benchItijahScratch(writer: *std.Io.Writer, case: Case, op: Op) !void {
    const warmup = warmupForLen(case.cps.len);
    var m = MeasuringAllocator.init(std.heap.c_allocator);
    const alloc = m.allocator();
    var scratch_ctx = ItijahScratchContext{};
    defer scratch_ctx.deinit(alloc);

    for (0..warmup) |_| {
        try runItijahScratch(alloc, &scratch_ctx, op, case.cps);
    }

    const iterations = iterationsForLen(case.cps.len);
    var agg = Aggregate{};
    for (0..iterations) |_| {
        const iter_state = m.beginIteration();
        var timer = try std.time.Timer.start();
        try runItijahScratch(alloc, &scratch_ctx, op, case.cps);
        agg.add(m.endIteration(iter_state, timer.read()));
    }

    const mean_ns = agg.meanNs();
    const ns_per_cp = mean_ns / @as(f64, @floatFromInt(case.cps.len));
    try writer.print(
        "{s:<10} {s:<12} {s:<8} {d:>8} {d:>10.2} {d:>10.2} {d:>12.2} {d:>12.2} {d:>12.2}\n",
        .{
            case.name,
            @tagName(op),
            @tagName(Impl.itijah),
            iterations,
            mean_ns,
            ns_per_cp,
            agg.meanAllocCount(),
            agg.meanAllocatedBytes(),
            agg.meanPeakBytes(),
        },
    );
}

fn bench(
    writer: *std.Io.Writer,
    case: Case,
    impl: Impl,
    op: Op,
    utf8: []const u8,
    utf16: []const u16,
    icu: *const IcuApi,
) !void {
    if (impl == .itijah) {
        return benchItijahScratch(writer, case, op);
    }

    var fribidi_buffers: ?FribidiBuffers = null;
    defer if (fribidi_buffers) |*buf| buf.deinit(std.heap.page_allocator);
    if (impl == .fribidi) {
        fribidi_buffers = try FribidiBuffers.init(std.heap.page_allocator, case.cps.len);
    }

    var icu_buffers: ?IcuBuffers = null;
    defer if (icu_buffers) |*buf| buf.deinit(std.heap.page_allocator);
    if (impl == .icu) {
        icu_buffers = try IcuBuffers.init(std.heap.page_allocator, utf16.len);
    }

    const warmup = warmupForLen(case.cps.len);
    for (0..warmup) |_| {
        _ = try measureOne(
            impl,
            op,
            case.cps,
            utf8,
            utf16,
            icu,
            if (fribidi_buffers) |*buf| buf else null,
            if (icu_buffers) |*buf| buf else null,
        );
    }

    const iterations = iterationsForLen(case.cps.len);
    var agg = Aggregate{};
    for (0..iterations) |_| {
        const m = try measureOne(
            impl,
            op,
            case.cps,
            utf8,
            utf16,
            icu,
            if (fribidi_buffers) |*buf| buf else null,
            if (icu_buffers) |*buf| buf else null,
        );
        agg.add(m);
    }

    const mean_ns = agg.meanNs();
    const ns_per_cp = mean_ns / @as(f64, @floatFromInt(case.cps.len));

    try writer.print(
        "{s:<10} {s:<12} {s:<8} {d:>8} {d:>10.2} {d:>10.2} {d:>12.2} {d:>12.2} {d:>12.2}\n",
        .{
            case.name,
            @tagName(op),
            @tagName(impl),
            iterations,
            mean_ns,
            ns_per_cp,
            agg.meanAllocCount(),
            agg.meanAllocatedBytes(),
            agg.meanPeakBytes(),
        },
    );
}

fn runBenchCase(
    writer: *std.Io.Writer,
    allocator: Allocator,
    case: Case,
    icu: *const IcuApi,
) !void {
    const utf8 = if (have_zabadi) try encodeUtf8(allocator, case.cps) else &[_]u8{};
    defer if (have_zabadi) allocator.free(utf8);

    const utf16 = try encodeUtf16(allocator, case.cps);
    defer allocator.free(utf16);

    try bench(writer, case, .itijah, .analysis, utf8, utf16, icu);
    if (have_zabadi) {
        try bench(writer, case, .zabadi, .analysis, utf8, utf16, icu);
    }
    try bench(writer, case, .fribidi, .analysis, utf8, utf16, icu);
    try bench(writer, case, .icu, .analysis, utf8, utf16, icu);

    try bench(writer, case, .itijah, .reorder_line, utf8, utf16, icu);
    if (have_zabadi) {
        try bench(writer, case, .zabadi, .reorder_line, utf8, utf16, icu);
    }
    try bench(writer, case, .fribidi, .reorder_line, utf8, utf16, icu);
    try bench(writer, case, .icu, .reorder_line, utf8, utf16, icu);
}

pub fn main(init: std.process.Init) !void {
    if (itijah_fribidi_probe_available() == 0) {
        return error.MemoryProbeUnavailable;
    }

    var icu = try loadIcuApi();
    defer icu.deinit();

    const alloc = std.heap.c_allocator;
    var buf: [16384]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;

    if (have_zabadi) {
        try writer.writeAll("comparison benchmark (itijah vs zabadi vs fribidi vs icu)\n");
    } else {
        try writer.writeAll("comparison benchmark (itijah vs fribidi vs icu)\n");
        try writer.writeAll("note: zabadi not found at ../zabadi/src/lib.zig; skipping zabadi rows\n");
    }
    try writer.writeAll("feature parity check vs fribidi (exact levels + visual map):\n");
    var parity_ok: usize = 0;
    for (parity_cases) |case| {
        const mismatch = try fribidiParityCase(alloc, case);
        if (mismatch) |m| {
            try writer.print(
                "  {s:<10} FAIL kind={s} idx={d} expected={d} actual={d}\n",
                .{ case.name, @tagName(m.kind), m.index, m.expected, m.actual },
            );
            if (m.kind == .levels) {
                try printLevelMismatchContext(writer, alloc, case, m.index);
            }
            try writer.writeAll("    cps: ");
            try printCaseCps(writer, case.cps);
        } else {
            parity_ok += 1;
            try writer.print("  {s:<10} PASS\n", .{case.name});
        }
    }
    try writer.print("  summary: {d}/{d} PASS\n", .{ parity_ok, parity_cases.len });

    if (parityOnlyMode(init.minimal.environ)) {
        try writer.flush();
        return;
    }

    try writer.writeAll("mode: itijah scratch-only paths enabled\n");
    const include_huge = includeHugeMode(init.minimal.environ);
    if (include_huge) {
        try writer.writeAll("mode: huge corpus set enabled (ITIJAH_COMPARE_INCLUDE_HUGE=1)\n");
    }

    try writer.writeAll("columns: case op impl iterations mean_ns ns_per_cp alloc_count allocated_bytes peak_bytes\n");
    try writer.writeAll("-----------------------------------------------------------------------------------------------\n");

    for (bench_cases) |case| {
        try runBenchCase(writer, alloc, case, &icu);
    }

    if (include_huge) {
        const kinds = [_]CorpusKind{ .ltr, .rtl, .mixed };
        for (huge_lengths) |len| {
            for (kinds) |kind| {
                const cps = try generateCorpusOwned(alloc, kind, len);
                defer alloc.free(cps);

                var name_buf: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ corpusKindName(kind), len });
                const case = Case{
                    .name = name,
                    .cps = cps,
                };
                try runBenchCase(writer, alloc, case, &icu);
            }
        }
    }

    try writer.flush();
}
