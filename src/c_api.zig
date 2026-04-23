//! C ABI wrappers for the libsie public surface.
//!
//! These `export fn` declarations are what give the produced shared library
//! (libsie.so / sie.dll / libsie.dylib) actual exported symbols, so that
//! Julia's `ccall` (and any other FFI consumer) can find something to bind to.
//!
//! Conventions
//! -----------
//! * All handles are opaque `*anyopaque` pointers. There are two flavors:
//!   - **Owned** handles: created by `*_open` / `*_attach` / `*_new` and
//!     freed by the matching `*_close` / `*_free` function.
//!   - **Borrowed** handles: returned from accessors like `sie_file_channel`
//!     and `sie_spigot_get`. Caller must NOT free them; they remain valid
//!     until the owning object is freed (or, for outputs, until the next
//!     `sie_spigot_get`).
//! * All fallible functions return a `c_int` status. `0` (`SIE_OK`) means
//!   success. Codes come from `src/error.zig`'s `errorToStatus`.
//! * Strings are returned as `(out_ptr, out_len)` pairs because SIE tag
//!   values are binary-safe and may contain embedded NULs. The pointer is
//!   borrowed and follows the same lifetime rules as the owning handle.
//! * `sie_version()` is the only function that returns a true NUL-terminated
//!   C string, because it points into a static string literal.

const std = @import("std");
const root = @import("root.zig");
const error_mod = @import("error.zig");

const SieFile = root.SieFile;
const Channel = root.Channel;
const ChannelSpigot = root.ChannelSpigot;
const Output = root.Output;
const Test = root.Test;
const Tag = root.Tag;
const Dimension = root.Dimension;
const Stream = root.Stream;
const FileStream = root.FileStream;
const File = root.File;
const histogram_mod = @import("histogram.zig");
const Histogram = histogram_mod.Histogram;
const writer_mod = @import("writer.zig");
const Writer = writer_mod.Writer;
const recover_mod = @import("recover.zig");
const plot_crusher_mod = @import("plot_crusher.zig");
const PlotCrusher = plot_crusher_mod.PlotCrusher;
const sifter_mod = @import("sifter.zig");
const Sifter = sifter_mod.Sifter;

// One global allocator for everything created via the C API. Using the C
// allocator keeps interop simple and predictable for FFI consumers.
const c_allocator = std.heap.c_allocator;

// ── Status codes ────────────────────────────────────────────────────────────
pub const SIE_OK: c_int = 0;

fn statusOf(err: anyerror) c_int {
    return @intCast(error_mod.errorToStatus(err));
}

// ── Library info ────────────────────────────────────────────────────────────

/// Returns the libsie version string (NUL-terminated, static).
export fn sie_version() [*:0]const u8 {
    return root.version;
}

/// Returns a static, NUL-terminated string for a status code returned by any
/// libsie function. The returned pointer is owned by the library; do not free.
export fn sie_status_message(status: c_int) [*:0]const u8 {
    const msg = error_mod.statusToMessage(@intCast(status));
    // statusToMessage() returns a static slice; ensure it's NUL-terminated.
    // The implementation uses string literals (which are sentinel-terminated),
    // so we can safely cast.
    return @ptrCast(msg.ptr);
}

// ── SieFile ─────────────────────────────────────────────────────────────────

/// Open an SIE file. On success writes an opaque handle to `out_handle` and
/// returns `SIE_OK`. On failure returns a non-zero status.
export fn sie_file_open(path: [*:0]const u8, out_handle: *?*anyopaque) c_int {
    const path_slice = std.mem.span(path);
    const sf = c_allocator.create(SieFile) catch return statusOf(error.OutOfMemory);
    sf.* = SieFile.open(c_allocator, path_slice) catch |err| {
        c_allocator.destroy(sf);
        return statusOf(err);
    };
    out_handle.* = @ptrCast(sf);
    return SIE_OK;
}

/// Close an SIE file opened with `sie_file_open`.
export fn sie_file_close(handle: ?*anyopaque) void {
    const sf = castFile(handle) orelse return;
    sf.deinit();
    c_allocator.destroy(sf);
}

export fn sie_file_num_channels(handle: ?*anyopaque) usize {
    const sf = castFile(handle) orelse return 0;
    return sf.channels().len;
}

export fn sie_file_num_tests(handle: ?*anyopaque) usize {
    const sf = castFile(handle) orelse return 0;
    return sf.tests().len;
}

export fn sie_file_num_tags(handle: ?*anyopaque) usize {
    const sf = castFile(handle) orelse return 0;
    return sf.fileTags().len;
}

/// Get the i-th channel handle (borrowed). Returns null on out-of-range.
export fn sie_file_channel(handle: ?*anyopaque, index: usize) ?*anyopaque {
    const sf = castFile(handle) orelse return null;
    const chans = sf.channels();
    if (index >= chans.len) return null;
    return @ptrCast(chans[index]);
}

/// Get the i-th test handle (borrowed). Returns null on out-of-range.
export fn sie_file_test(handle: ?*anyopaque, index: usize) ?*anyopaque {
    const sf = castFile(handle) orelse return null;
    const ts = sf.tests();
    if (index >= ts.len) return null;
    return @ptrCast(&ts[index]);
}

/// Get the i-th file-level tag handle (borrowed). Returns null on out-of-range.
export fn sie_file_tag(handle: ?*anyopaque, index: usize) ?*const anyopaque {
    const sf = castFile(handle) orelse return null;
    const tgs = sf.fileTags();
    if (index >= tgs.len) return null;
    return @ptrCast(&tgs[index]);
}

/// Find a channel by id. Returns null if not found. Borrowed handle.
export fn sie_file_find_channel(handle: ?*anyopaque, id: u32) ?*anyopaque {
    const sf = castFile(handle) orelse return null;
    return @ptrCast(sf.findChannel(id) orelse return null);
}

/// Find a test by id. Returns null if not found. Borrowed handle.
export fn sie_file_find_test(handle: ?*anyopaque, id: u32) ?*anyopaque {
    const sf = castFile(handle) orelse return null;
    return @ptrCast(sf.findTest(id) orelse return null);
}

/// Get the test that contains the given channel. Returns null if none.
export fn sie_file_containing_test(
    handle: ?*anyopaque,
    channel_handle: ?*anyopaque,
) ?*anyopaque {
    const sf = castFile(handle) orelse return null;
    const ch = castChannel(channel_handle) orelse return null;
    return @ptrCast(sf.containingTest(ch) orelse return null);
}

// ── Test ────────────────────────────────────────────────────────────────────

export fn sie_test_id(handle: ?*anyopaque) u32 {
    const t = castTest(handle) orelse return 0;
    return t.id;
}

/// Test name as (ptr, len). On null handle writes (null, 0).
export fn sie_test_name(handle: ?*anyopaque, out_ptr: *?[*]const u8, out_len: *usize) void {
    const t = castTest(handle) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return;
    };
    out_ptr.* = t.name.ptr;
    out_len.* = t.name.len;
}

export fn sie_test_num_channels(handle: ?*anyopaque) usize {
    const t = castTest(handle) orelse return 0;
    return t.channels().len;
}

/// Get the i-th channel of a test (borrowed). Returns null on out-of-range.
export fn sie_test_channel(handle: ?*anyopaque, index: usize) ?*anyopaque {
    const t = castTestMut(handle) orelse return null;
    const chans = t.channelsMut();
    if (index >= chans.len) return null;
    return @ptrCast(&chans[index]);
}

export fn sie_test_num_tags(handle: ?*anyopaque) usize {
    const t = castTest(handle) orelse return 0;
    return t.tags().len;
}

export fn sie_test_tag(handle: ?*anyopaque, index: usize) ?*const anyopaque {
    const t = castTest(handle) orelse return null;
    const tgs = t.tags();
    if (index >= tgs.len) return null;
    return @ptrCast(&tgs[index]);
}

/// Find a tag on this test by key. NUL-terminated key. Borrowed handle or null.
export fn sie_test_find_tag(handle: ?*anyopaque, key: [*:0]const u8) ?*const anyopaque {
    const t = castTest(handle) orelse return null;
    const k = std.mem.span(key);
    return @ptrCast(t.findTag(k) orelse return null);
}

// ── Channel ─────────────────────────────────────────────────────────────────

export fn sie_channel_id(handle: ?*anyopaque) u32 {
    const ch = castChannel(handle) orelse return 0;
    return ch.id;
}

export fn sie_channel_test_id(handle: ?*anyopaque) u32 {
    const ch = castChannel(handle) orelse return 0;
    return ch.test_id;
}

/// Channel name as (ptr, len). Borrowed; lifetime = owning SieFile.
export fn sie_channel_name(handle: ?*anyopaque, out_ptr: *?[*]const u8, out_len: *usize) void {
    const ch = castChannel(handle) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return;
    };
    out_ptr.* = ch.name.ptr;
    out_len.* = ch.name.len;
}

export fn sie_channel_num_dims(handle: ?*anyopaque) usize {
    const ch = castChannel(handle) orelse return 0;
    return ch.dimensions().len;
}

/// Get the i-th dimension (borrowed). Returns null on out-of-range.
export fn sie_channel_dimension(handle: ?*anyopaque, index: usize) ?*const anyopaque {
    const ch = castChannel(handle) orelse return null;
    const d = ch.dimension(@intCast(index)) orelse return null;
    return @ptrCast(d);
}

export fn sie_channel_num_tags(handle: ?*anyopaque) usize {
    const ch = castChannel(handle) orelse return 0;
    return ch.tags().len;
}

export fn sie_channel_tag(handle: ?*anyopaque, index: usize) ?*const anyopaque {
    const ch = castChannel(handle) orelse return null;
    const tgs = ch.tags();
    if (index >= tgs.len) return null;
    return @ptrCast(&tgs[index]);
}

export fn sie_channel_find_tag(handle: ?*anyopaque, key: [*:0]const u8) ?*const anyopaque {
    const ch = castChannel(handle) orelse return null;
    const k = std.mem.span(key);
    return @ptrCast(ch.findTag(k) orelse return null);
}

// ── Dimension ───────────────────────────────────────────────────────────────

export fn sie_dimension_index(handle: ?*const anyopaque) u32 {
    const d = castDim(handle) orelse return 0;
    return d.index;
}

export fn sie_dimension_name(handle: ?*const anyopaque, out_ptr: *?[*]const u8, out_len: *usize) void {
    const d = castDim(handle) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return;
    };
    out_ptr.* = d.name.ptr;
    out_len.* = d.name.len;
}

export fn sie_dimension_num_tags(handle: ?*const anyopaque) usize {
    const d = castDim(handle) orelse return 0;
    return d.tags().len;
}

export fn sie_dimension_tag(handle: ?*const anyopaque, index: usize) ?*const anyopaque {
    const d = castDim(handle) orelse return null;
    const tgs = d.tags();
    if (index >= tgs.len) return null;
    return @ptrCast(&tgs[index]);
}

export fn sie_dimension_find_tag(handle: ?*const anyopaque, key: [*:0]const u8) ?*const anyopaque {
    const d = castDim(handle) orelse return null;
    const k = std.mem.span(key);
    return @ptrCast(d.findTag(k) orelse return null);
}

// ── Tag ─────────────────────────────────────────────────────────────────────

/// Tag key as (ptr, len). Borrowed.
export fn sie_tag_key(handle: ?*const anyopaque, out_ptr: *?[*]const u8, out_len: *usize) void {
    const t = castTag(handle) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return;
    };
    out_ptr.* = t.key.ptr;
    out_len.* = t.key.len;
}

/// Tag value as (ptr, len). Binary-safe — value may contain NULs.
/// Works for both string and binary tags.
export fn sie_tag_value(handle: ?*const anyopaque, out_ptr: *?[*]const u8, out_len: *usize) void {
    const t = castTag(handle) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return;
    };
    if (t.string()) |s| {
        out_ptr.* = s.ptr;
        out_len.* = s.len;
    } else if (t.binary()) |b| {
        out_ptr.* = b.ptr;
        out_len.* = b.len;
    } else {
        out_ptr.* = null;
        out_len.* = 0;
    }
}

export fn sie_tag_value_size(handle: ?*const anyopaque) usize {
    const t = castTag(handle) orelse return 0;
    return t.valueSize();
}

/// Returns 1 if the tag holds a string value, 0 otherwise.
export fn sie_tag_is_string(handle: ?*const anyopaque) c_int {
    const t = castTag(handle) orelse return 0;
    return if (t.isString()) 1 else 0;
}

/// Returns 1 if the tag holds a binary value, 0 otherwise.
export fn sie_tag_is_binary(handle: ?*const anyopaque) c_int {
    const t = castTag(handle) orelse return 0;
    return if (t.isBinary()) 1 else 0;
}

export fn sie_tag_group(handle: ?*const anyopaque) u32 {
    const t = castTag(handle) orelse return 0;
    return t.group;
}

export fn sie_tag_is_from_group(handle: ?*const anyopaque) c_int {
    const t = castTag(handle) orelse return 0;
    return if (t.isFromGroup()) 1 else 0;
}

// ── Spigot ──────────────────────────────────────────────────────────────────

/// Attach a spigot to a channel. On success writes an opaque spigot handle
/// to `out_spigot` (caller frees with `sie_spigot_free`).
export fn sie_spigot_attach(
    file_handle: ?*anyopaque,
    channel_handle: ?*anyopaque,
    out_spigot: *?*anyopaque,
) c_int {
    const sf = castFile(file_handle) orelse return statusOf(error.InvalidData);
    const ch = castChannel(channel_handle) orelse return statusOf(error.InvalidData);
    const spig = c_allocator.create(ChannelSpigot) catch return statusOf(error.OutOfMemory);
    spig.* = sf.attachSpigot(ch) catch |err| {
        c_allocator.destroy(spig);
        return statusOf(err);
    };
    out_spigot.* = @ptrCast(spig);
    return SIE_OK;
}

/// Free a spigot returned by `sie_spigot_attach`.
export fn sie_spigot_free(handle: ?*anyopaque) void {
    const spig = castSpigot(handle) orelse return;
    spig.deinit();
    c_allocator.destroy(spig);
}

/// Pull the next Output record from the spigot.
///
/// On success writes a borrowed handle to `out_output` and returns `SIE_OK`.
/// When the spigot is exhausted, writes `null` to `out_output` and returns
/// `SIE_OK`. On error returns a non-zero status.
///
/// The Output is owned by the spigot and is invalidated by the next call to
/// `sie_spigot_get` or `sie_spigot_free`.
export fn sie_spigot_get(handle: ?*anyopaque, out_output: *?*anyopaque) c_int {
    const spig = castSpigot(handle) orelse return statusOf(error.InvalidData);
    const maybe = spig.get() catch |err| return statusOf(err);
    out_output.* = if (maybe) |out| @ptrCast(out) else null;
    return SIE_OK;
}

export fn sie_spigot_tell(handle: ?*anyopaque) u64 {
    const spig = castSpigot(handle) orelse return 0;
    return spig.tell();
}

export fn sie_spigot_seek(handle: ?*anyopaque, target: u64) u64 {
    const spig = castSpigot(handle) orelse return 0;
    return spig.seek(target);
}

export fn sie_spigot_reset(handle: ?*anyopaque) void {
    const spig = castSpigot(handle) orelse return;
    spig.reset();
}

export fn sie_spigot_is_done(handle: ?*anyopaque) c_int {
    const spig = castSpigot(handle) orelse return 0;
    return if (spig.isDone()) 1 else 0;
}

export fn sie_spigot_num_blocks(handle: ?*anyopaque) usize {
    const spig = castSpigot(handle) orelse return 0;
    return spig.numBlocks();
}

/// Disable on-the-fly engineering-unit transforms. Pass non-zero to disable.
export fn sie_spigot_disable_transforms(handle: ?*anyopaque, disable: c_int) void {
    const spig = castSpigot(handle) orelse return;
    spig.disableTransforms(disable != 0);
}

/// Apply transforms to an Output produced earlier (e.g. with transforms disabled).
export fn sie_spigot_transform_output(handle: ?*anyopaque, output_handle: ?*anyopaque) c_int {
    const spig = castSpigot(handle) orelse return statusOf(error.InvalidData);
    const out = castOutput(output_handle) orelse return statusOf(error.InvalidData);
    spig.transformOutput(out);
    return SIE_OK;
}

/// Limit the maximum number of scans returned per `sie_spigot_get`.
export fn sie_spigot_set_scan_limit(handle: ?*anyopaque, limit: u64) void {
    const spig = castSpigot(handle) orelse return;
    spig.setScanLimit(limit);
}

/// Drop the spigot's current Output buffer (releases its memory).
/// Subsequent `sie_spigot_get` calls will allocate a fresh one.
export fn sie_spigot_clear_output(handle: ?*anyopaque) void {
    const spig = castSpigot(handle) orelse return;
    spig.clearOutput();
}

/// Find first scan in `dim` with value >= `value`.
/// On success writes block/scan and returns SIE_OK; if no such scan
/// exists writes 0/0 and returns SIE_OK with `*out_found` = 0.
export fn sie_spigot_lower_bound(
    handle: ?*anyopaque,
    dim: usize,
    value: f64,
    out_block: *u64,
    out_scan: *u64,
    out_found: *c_int,
) c_int {
    const spig = castSpigot(handle) orelse return statusOf(error.InvalidData);
    const result = spig.lowerBound(dim, value) catch |err| return statusOf(err);
    if (result) |r| {
        out_block.* = r.block;
        out_scan.* = r.scan;
        out_found.* = 1;
    } else {
        out_block.* = 0;
        out_scan.* = 0;
        out_found.* = 0;
    }
    return SIE_OK;
}

/// Find last scan in `dim` with value <= `value`. See `sie_spigot_lower_bound`.
export fn sie_spigot_upper_bound(
    handle: ?*anyopaque,
    dim: usize,
    value: f64,
    out_block: *u64,
    out_scan: *u64,
    out_found: *c_int,
) c_int {
    const spig = castSpigot(handle) orelse return statusOf(error.InvalidData);
    const result = spig.upperBound(dim, value) catch |err| return statusOf(err);
    if (result) |r| {
        out_block.* = r.block;
        out_scan.* = r.scan;
        out_found.* = 1;
    } else {
        out_block.* = 0;
        out_scan.* = 0;
        out_found.* = 0;
    }
    return SIE_OK;
}

// ── Output ──────────────────────────────────────────────────────────────────
// Output handles are borrowed from a spigot; never free them.

export fn sie_output_num_dims(handle: ?*anyopaque) usize {
    const out = castOutput(handle) orelse return 0;
    return out.num_dims;
}

export fn sie_output_num_rows(handle: ?*anyopaque) usize {
    const out = castOutput(handle) orelse return 0;
    return out.num_rows;
}

export fn sie_output_block(handle: ?*anyopaque) usize {
    const out = castOutput(handle) orelse return 0;
    return out.block;
}

/// Type of dimension `dim`. Matches the C API constants:
///   0 = SIE_OUTPUT_NONE, 1 = SIE_OUTPUT_FLOAT64, 2 = SIE_OUTPUT_RAW.
export fn sie_output_type(handle: ?*anyopaque, dim: usize) c_int {
    const out = castOutput(handle) orelse return 0;
    const t = out.dimensionType(dim) orelse return 0;
    return @intCast(@intFromEnum(t));
}

export fn sie_output_get_float64(
    handle: ?*anyopaque,
    dim: usize,
    row: usize,
    out_value: *f64,
) c_int {
    const out = castOutput(handle) orelse return statusOf(error.InvalidData);
    const v = out.float64(dim, row) orelse return statusOf(error.IndexOutOfBounds);
    out_value.* = v;
    return SIE_OK;
}

export fn sie_output_get_raw(
    handle: ?*anyopaque,
    dim: usize,
    row: usize,
    out_ptr: *[*]const u8,
    out_size: *u32,
) c_int {
    const out = castOutput(handle) orelse return statusOf(error.InvalidData);
    const r = out.raw(dim, row) orelse return statusOf(error.IndexOutOfBounds);
    out_ptr.* = r.ptr.ptr;
    out_size.* = r.size;
    return SIE_OK;
}

/// Bulk-copy `count` consecutive Float64 rows of dimension `dim` from
/// the output, starting at `start_row`, into `out_buf`. The caller must
/// ensure `out_buf` has room for `count` doubles. The number of rows
/// actually written (clamped to the output's row count) is stored in
/// `*out_written`.
///
/// One ccall replaces `count` calls to `sie_output_get_float64`, which
/// is the hot path for bulk numeric reads.
export fn sie_output_get_float64_range(
    handle: ?*anyopaque,
    dim: usize,
    start_row: usize,
    count: usize,
    out_buf: [*]f64,
    out_written: *usize,
) c_int {
    const out = castOutput(handle) orelse return statusOf(error.InvalidData);
    const buf = out_buf[0..count];
    const n = out.getFloat64Range(dim, start_row, count, buf) catch |err| {
        out_written.* = 0;
        return statusOf(err);
    };
    out_written.* = n;
    return SIE_OK;
}

/// Bulk-fetch `count` consecutive Raw rows of dimension `dim` from the
/// output, starting at `start_row`. Fills the parallel arrays
/// `out_ptrs` (length `count`) and `out_sizes` (length `count`) with
/// borrowed pointer + length for each row's payload. The number of rows
/// actually written is stored in `*out_written`. Borrowed pointers
/// remain valid until the next `sie_spigot_get` call on the owning
/// spigot.
export fn sie_output_get_raw_range(
    handle: ?*anyopaque,
    dim: usize,
    start_row: usize,
    count: usize,
    out_ptrs: [*][*]const u8,
    out_sizes: [*]u32,
    out_written: *usize,
) c_int {
    const out = castOutput(handle) orelse return statusOf(error.InvalidData);
    const ptrs = out_ptrs[0..count];
    const sizes = out_sizes[0..count];
    const n = out.getRawRange(dim, start_row, count, ptrs, sizes) catch |err| {
        out_written.* = 0;
        return statusOf(err);
    };
    out_written.* = n;
    return SIE_OK;
}

// ── Stream ──────────────────────────────────────────────────────────────────
// A Stream accepts SIE bytes incrementally and indexes them by group.
// It does NOT expose channels/tests/tags — those require the full file
// hierarchy built by SieFile. Use Stream when you need to ingest blocks
// from a non-seekable source and inspect their group structure.

/// Create a new stream. Caller frees with `sie_stream_free`.
export fn sie_stream_new(out_handle: *?*anyopaque) c_int {
    const s = c_allocator.create(Stream) catch return statusOf(error.OutOfMemory);
    s.* = Stream.init(c_allocator);
    out_handle.* = @ptrCast(s);
    return SIE_OK;
}

export fn sie_stream_free(handle: ?*anyopaque) void {
    const s = castStream(handle) orelse return;
    s.deinit();
    c_allocator.destroy(s);
}

/// Feed bytes to the stream. Writes the number of consumed bytes to
/// `out_consumed` and returns SIE_OK on success.
export fn sie_stream_add_data(
    handle: ?*anyopaque,
    data: [*]const u8,
    size: usize,
    out_consumed: *usize,
) c_int {
    const s = castStream(handle) orelse return statusOf(error.InvalidData);
    out_consumed.* = s.addStreamData(data[0..size]) catch |err| return statusOf(err);
    return SIE_OK;
}

export fn sie_stream_num_groups(handle: ?*anyopaque) u32 {
    const s = castStream(handle) orelse return 0;
    return s.numGroups();
}

export fn sie_stream_group_num_blocks(handle: ?*anyopaque, group_id: u32) usize {
    const s = castStream(handle) orelse return 0;
    return s.getGroupNumBlocks(group_id);
}

export fn sie_stream_group_num_bytes(handle: ?*anyopaque, group_id: u32) u64 {
    const s = castStream(handle) orelse return 0;
    return s.getGroupNumBytes(group_id);
}

export fn sie_stream_is_group_closed(handle: ?*anyopaque, group_id: u32) c_int {
    const s = castStream(handle) orelse return 0;
    return if (s.isGroupClosed(group_id)) 1 else 0;
}

// ── Histogram ───────────────────────────────────────────────────────────────
// Build an N-dimensional histogram from a channel's data.

/// Build a histogram from a channel's spigot data. Caller frees with
/// `sie_histogram_free`. Channel must have an odd number of dims >= 3.
export fn sie_histogram_from_channel(
    file_handle: ?*anyopaque,
    channel_handle: ?*anyopaque,
    out_handle: *?*anyopaque,
) c_int {
    const sf = castFile(file_handle) orelse return statusOf(error.InvalidData);
    const ch = castChannel(channel_handle) orelse return statusOf(error.InvalidData);
    const h = c_allocator.create(Histogram) catch return statusOf(error.OutOfMemory);
    h.* = Histogram.fromChannel(c_allocator, sf, ch) catch |err| {
        c_allocator.destroy(h);
        return statusOf(err);
    };
    out_handle.* = @ptrCast(h);
    return SIE_OK;
}

export fn sie_histogram_free(handle: ?*anyopaque) void {
    const h = castHistogram(handle) orelse return;
    h.deinit();
    c_allocator.destroy(h);
}

export fn sie_histogram_num_dims(handle: ?*anyopaque) usize {
    const h = castHistogram(handle) orelse return 0;
    return h.dims.len;
}

export fn sie_histogram_total_size(handle: ?*anyopaque) usize {
    const h = castHistogram(handle) orelse return 0;
    return h.total_size;
}

export fn sie_histogram_num_bins(handle: ?*anyopaque, dim: usize) usize {
    const h = castHistogram(handle) orelse return 0;
    if (dim >= h.dims.len) return 0;
    return h.dims[dim].numBins();
}

/// Get the bin value at the given multi-dimensional indices.
/// `indices` must point to `num_dims` `usize` values.
export fn sie_histogram_get_bin(
    handle: ?*anyopaque,
    indices: [*]const usize,
    out_value: *f64,
) c_int {
    const h = castHistogram(handle) orelse return statusOf(error.InvalidData);
    out_value.* = h.getBin(indices[0..h.dims.len]);
    return SIE_OK;
}

/// Fill the caller's `lower` and `upper` arrays with this dimension's bin
/// bounds. Both arrays must have at least `num_bins(dim)` capacity.
export fn sie_histogram_get_bounds(
    handle: ?*anyopaque,
    dim: usize,
    lower: [*]f64,
    upper: [*]f64,
    capacity: usize,
) c_int {
    const h = castHistogram(handle) orelse return statusOf(error.InvalidData);
    if (dim >= h.dims.len) return statusOf(error.IndexOutOfBounds);
    h.getBinBounds(dim, lower[0..capacity], upper[0..capacity]);
    return SIE_OK;
}

// ── Writer ──────────────────────────────────────────────────────────────────
// Low-level SIE block writer. The caller supplies a C callback that receives
// each fully-formed block (header + payload + trailer); the writer is purely
// an in-memory composer.

/// C-ABI signature for the writer callback. Must return the number of bytes
/// consumed; if it differs from `size`, the writer returns SIE_E_FILE_WRITE
/// from the call that triggered the flush.
pub const sie_writer_fn = *const fn (user: ?*anyopaque, data: [*]const u8, size: usize) callconv(.c) usize;

/// Internal box: stores a Writer plus the C callback + user pointer it
/// trampolines through. The Writer holds a Zig fn pointer that calls the
/// box's C callback.
const WriterBox = struct {
    writer: Writer,
    c_fn: ?sie_writer_fn,
    c_user: ?*anyopaque,
};

fn writerTrampoline(user: ?*anyopaque, data: []const u8) usize {
    const box: *WriterBox = @ptrCast(@alignCast(user.?));
    const cb = box.c_fn orelse return data.len;
    return cb(box.c_user, data.ptr, data.len);
}

/// Writer ID-class constants matching `writer_mod.IdType`.
pub const SIE_WRITER_ID_GROUP: c_int = 0;
pub const SIE_WRITER_ID_TEST: c_int = 1;
pub const SIE_WRITER_ID_CHANNEL: c_int = 2;
pub const SIE_WRITER_ID_DECODER: c_int = 3;

/// Create a new Writer. `callback` may be NULL for a "dry-run" writer that
/// only tracks offsets / IDs / index entries.
export fn sie_writer_new(
    callback: ?sie_writer_fn,
    user: ?*anyopaque,
    out_handle: *?*anyopaque,
) c_int {
    const box = c_allocator.create(WriterBox) catch return statusOf(error.OutOfMemory);
    box.* = .{
        .writer = undefined,
        .c_fn = callback,
        .c_user = user,
    };
    box.writer = Writer.init(c_allocator, writerTrampoline, @ptrCast(box));
    out_handle.* = @ptrCast(box);
    return SIE_OK;
}

/// Free a Writer. Flushes any pending XML/index buffers first.
export fn sie_writer_free(handle: ?*anyopaque) void {
    const box = castWriter(handle) orelse return;
    box.writer.deinit();
    c_allocator.destroy(box);
}

/// Write one complete SIE block (header + payload + trailer) for `group`.
export fn sie_writer_write_block(
    handle: ?*anyopaque,
    group: u32,
    data: [*]const u8,
    size: usize,
) c_int {
    const box = castWriter(handle) orelse return statusOf(error.InvalidData);
    box.writer.writeBlock(group, data[0..size]) catch |err| return statusOf(err);
    return SIE_OK;
}

/// Append raw bytes to the pending XML buffer (auto-flushes when large).
export fn sie_writer_xml_string(
    handle: ?*anyopaque,
    data: [*]const u8,
    size: usize,
) c_int {
    const box = castWriter(handle) orelse return statusOf(error.InvalidData);
    box.writer.xmlString(data[0..size]) catch |err| return statusOf(err);
    return SIE_OK;
}

/// Append the standard SIE XML preamble (root element, decoders 0/1, etc.).
export fn sie_writer_xml_header(handle: ?*anyopaque) c_int {
    const box = castWriter(handle) orelse return statusOf(error.InvalidData);
    box.writer.xmlHeader() catch |err| return statusOf(err);
    return SIE_OK;
}

/// Force-flush the pending XML buffer as a group-0 block.
export fn sie_writer_flush_xml(handle: ?*anyopaque) void {
    const box = castWriter(handle) orelse return;
    box.writer.flushXml();
}

/// Force-flush the pending block-index buffer as a group-1 block.
export fn sie_writer_flush_index(handle: ?*anyopaque) void {
    const box = castWriter(handle) orelse return;
    box.writer.flushIndex();
}

/// Allocate the next free ID for one of the SIE id-classes. `id_type` must
/// be one of SIE_WRITER_ID_GROUP/TEST/CHANNEL/DECODER.
export fn sie_writer_next_id(handle: ?*anyopaque, id_type: c_int) u32 {
    const box = castWriter(handle) orelse return 0;
    if (id_type < 0 or id_type > 3) return 0;
    return box.writer.nextId(@enumFromInt(@as(u2, @intCast(id_type))));
}

/// Predict the total file size given currently-buffered state plus
/// `addl_bytes` of payload spread across `addl_blocks` blocks.
export fn sie_writer_total_size(
    handle: ?*anyopaque,
    addl_bytes: u64,
    addl_blocks: u64,
) u64 {
    const box = castWriter(handle) orelse return 0;
    return box.writer.totalSize(addl_bytes, addl_blocks);
}

/// Bytes already emitted (sum of all completed block sizes).
export fn sie_writer_offset(handle: ?*anyopaque) u64 {
    const box = castWriter(handle) orelse return 0;
    return box.writer.offset;
}

/// Enable / disable automatic group-1 block-index generation.
export fn sie_writer_set_do_index(handle: ?*anyopaque, do_index: c_int) void {
    const box = castWriter(handle) orelse return;
    box.writer.do_index = do_index != 0;
}

// ── FileStream ──────────────────────────────────────────────────────────────
// Stream-to-file: feed raw SIE bytes incrementally; complete blocks are
// written through to disk and indexed by group. Use this for the writer-side
// flow where you have a byte stream (e.g. from a network source) and want to
// land it in a real file without buffering everything in memory.

/// Create + open a FileStream. The path is copied internally.
export fn sie_file_stream_open(path: [*:0]const u8, out_handle: *?*anyopaque) c_int {
    const path_slice = std.mem.span(path);
    const path_copy = c_allocator.dupe(u8, path_slice) catch return statusOf(error.OutOfMemory);
    errdefer c_allocator.free(path_copy);
    const fs = c_allocator.create(FileStream) catch return statusOf(error.OutOfMemory);
    fs.* = FileStream.init(c_allocator, path_copy);
    fs.open() catch |err| {
        fs.deinit();
        c_allocator.destroy(fs);
        c_allocator.free(path_copy);
        return statusOf(err);
    };
    out_handle.* = @ptrCast(fs);
    return SIE_OK;
}

/// Close + free a FileStream.
export fn sie_file_stream_close(handle: ?*anyopaque) void {
    const fs = castFileStream(handle) orelse return;
    const path_copy = fs.path;
    fs.deinit();
    c_allocator.destroy(fs);
    c_allocator.free(path_copy);
}

/// Feed bytes; complete blocks are extracted and written to disk.
/// Returns the number of bytes consumed in `*out_consumed`.
export fn sie_file_stream_add_data(
    handle: ?*anyopaque,
    data: [*]const u8,
    size: usize,
    out_consumed: *usize,
) c_int {
    const fs = castFileStream(handle) orelse return statusOf(error.InvalidData);
    out_consumed.* = fs.addStreamData(data[0..size]) catch |err| return statusOf(err);
    return SIE_OK;
}

export fn sie_file_stream_is_group_closed(handle: ?*anyopaque, group: u32) c_int {
    const fs = castFileStream(handle) orelse return 0;
    return if (fs.isGroupClosed(group)) 1 else 0;
}

export fn sie_file_stream_num_groups(handle: ?*anyopaque) u32 {
    const fs = castFileStream(handle) orelse return 0;
    return fs.numGroups();
}

export fn sie_file_stream_highest_group(handle: ?*anyopaque) u32 {
    const fs = castFileStream(handle) orelse return 0;
    return fs.highestGroup();
}

// ── Recover ─────────────────────────────────────────────────────────────────
// Run the 3-pass corruption-recovery scan over a file and return the
// summary as a JSON string (caller frees with `sie_string_free`).

/// Run recovery on `path`. `mod` is the modulus for glue offset alignment
/// (use 0 for "any offset"). On success writes (json_ptr, json_len) and
/// returns SIE_OK; the caller MUST free `*out_json` with `sie_string_free`.
export fn sie_recover(
    path: [*:0]const u8,
    mod: u64,
    out_json: *?[*]const u8,
    out_len: *usize,
) c_int {
    const path_slice = std.mem.span(path);
    var result = recover_mod.recover(c_allocator, path_slice, mod) catch |err| {
        out_json.* = null;
        out_len.* = 0;
        return statusOf(err);
    };
    defer result.deinit(c_allocator);
    const json = result.toJson(c_allocator) catch |err| {
        out_json.* = null;
        out_len.* = 0;
        return statusOf(err);
    };
    out_json.* = json.ptr;
    out_len.* = json.len;
    return SIE_OK;
}

/// Free a string buffer allocated by libsie (e.g. from `sie_recover`).
export fn sie_string_free(ptr: ?[*]const u8, len: usize) void {
    const p = ptr orelse return;
    c_allocator.free(p[0..len]);
}

// ── PlotCrusher ─────────────────────────────────────────────────────────────
// Reduce a high-rate Output stream down to ~ideal_scans points for plotting.

/// Create a PlotCrusher targeting `ideal_scans` output samples.
export fn sie_plot_crusher_new(ideal_scans: usize, out_handle: *?*anyopaque) c_int {
    const pc = c_allocator.create(PlotCrusher) catch return statusOf(error.OutOfMemory);
    pc.* = PlotCrusher.init(c_allocator, ideal_scans);
    out_handle.* = @ptrCast(pc);
    return SIE_OK;
}

export fn sie_plot_crusher_free(handle: ?*anyopaque) void {
    const pc = castPlotCrusher(handle) orelse return;
    pc.deinit();
    c_allocator.destroy(pc);
}

/// Feed one input chunk to the crusher. Writes 1 to `*out_done` when the
/// crusher has accumulated enough to emit (the caller can then call
/// `sie_plot_crusher_finalize` and read the result).
export fn sie_plot_crusher_work(
    handle: ?*anyopaque,
    input_handle: ?*anyopaque,
    out_done: *c_int,
) c_int {
    const pc = castPlotCrusher(handle) orelse return statusOf(error.InvalidData);
    const input = castOutput(input_handle) orelse return statusOf(error.InvalidData);
    const done = pc.work(input) catch |err| return statusOf(err);
    out_done.* = if (done) 1 else 0;
    return SIE_OK;
}

export fn sie_plot_crusher_finalize(handle: ?*anyopaque) void {
    const pc = castPlotCrusher(handle) orelse return;
    pc.finalize();
}

/// Borrowed pointer to the crusher's internal Output. Valid until the next
/// `sie_plot_crusher_work` or until the crusher is freed.
export fn sie_plot_crusher_get_output(handle: ?*anyopaque) ?*anyopaque {
    const pc = castPlotCrusher(handle) orelse return null;
    const out = pc.getOutput() orelse return null;
    return @ptrCast(@constCast(out));
}

// ── Sifter ──────────────────────────────────────────────────────────────────
// Select a subset of channels from a SIE file and copy them through a Writer
// into a new (smaller) SIE file. Builds the ID-remapping internally.

/// Create a Sifter that emits through `writer_handle` (a Writer from
/// `sie_writer_new`). The sifter borrows the writer; do not free the writer
/// before the sifter is freed.
export fn sie_sifter_new(writer_handle: ?*anyopaque, out_handle: *?*anyopaque) c_int {
    const box = castWriter(writer_handle) orelse return statusOf(error.InvalidData);
    const sif = c_allocator.create(Sifter) catch return statusOf(error.OutOfMemory);
    sif.* = Sifter.init(c_allocator, &box.writer);
    out_handle.* = @ptrCast(sif);
    return SIE_OK;
}

export fn sie_sifter_free(handle: ?*anyopaque) void {
    const sif = castSifter(handle) orelse return;
    sif.deinit();
    c_allocator.destroy(sif);
}

/// Add `channel` (from `file_handle`) to the sifted output. `start_block`/
/// `end_block` clip the data range copied (use 0 / UINT64_MAX for "all").
export fn sie_sifter_add_channel(
    handle: ?*anyopaque,
    file_handle: ?*anyopaque,
    channel_handle: ?*anyopaque,
    start_block: u64,
    end_block: u64,
) c_int {
    const sif = castSifter(handle) orelse return statusOf(error.InvalidData);
    const sf = castFile(file_handle) orelse return statusOf(error.InvalidData);
    const ch = castChannel(channel_handle) orelse return statusOf(error.InvalidData);
    sif.addChannel(sf, ch, start_block, end_block) catch |err| return statusOf(err);
    return SIE_OK;
}

/// Flush XML and copy all mapped data blocks through the writer. After
/// this returns, the Writer's callback has received the complete sifted
/// SIE byte stream; the caller can free the sifter.
export fn sie_sifter_finish(handle: ?*anyopaque, file_handle: ?*anyopaque) c_int {
    const sif = castSifter(handle) orelse return statusOf(error.InvalidData);
    const sf = castFile(file_handle) orelse return statusOf(error.InvalidData);
    sif.finish(&sf.file) catch |err| return statusOf(err);
    return SIE_OK;
}

export fn sie_sifter_total_entries(handle: ?*anyopaque) usize {
    const sif = castSifter(handle) orelse return 0;
    return sif.totalEntries();
}

// ── Internal: handle casting ────────────────────────────────────────────────

inline fn castFile(h: ?*anyopaque) ?*SieFile {
    return @as(?*SieFile, @ptrCast(@alignCast(h)));
}
inline fn castChannel(h: ?*anyopaque) ?*Channel {
    return @as(?*Channel, @ptrCast(@alignCast(h)));
}
inline fn castSpigot(h: ?*anyopaque) ?*ChannelSpigot {
    return @as(?*ChannelSpigot, @ptrCast(@alignCast(h)));
}
inline fn castOutput(h: ?*anyopaque) ?*Output {
    return @as(?*Output, @ptrCast(@alignCast(h)));
}
inline fn castTest(h: ?*anyopaque) ?*const Test {
    return @as(?*const Test, @ptrCast(@alignCast(h)));
}
inline fn castTestMut(h: ?*anyopaque) ?*Test {
    return @as(?*Test, @ptrCast(@alignCast(h)));
}
inline fn castTag(h: ?*const anyopaque) ?*const Tag {
    return @as(?*const Tag, @ptrCast(@alignCast(h)));
}
inline fn castDim(h: ?*const anyopaque) ?*const Dimension {
    return @as(?*const Dimension, @ptrCast(@alignCast(h)));
}
inline fn castStream(h: ?*anyopaque) ?*Stream {
    return @as(?*Stream, @ptrCast(@alignCast(h)));
}
inline fn castHistogram(h: ?*anyopaque) ?*Histogram {
    return @as(?*Histogram, @ptrCast(@alignCast(h)));
}
inline fn castWriter(h: ?*anyopaque) ?*WriterBox {
    return @as(?*WriterBox, @ptrCast(@alignCast(h)));
}
inline fn castFileStream(h: ?*anyopaque) ?*FileStream {
    return @as(?*FileStream, @ptrCast(@alignCast(h)));
}
inline fn castPlotCrusher(h: ?*anyopaque) ?*PlotCrusher {
    return @as(?*PlotCrusher, @ptrCast(@alignCast(h)));
}
inline fn castSifter(h: ?*anyopaque) ?*Sifter {
    return @as(?*Sifter, @ptrCast(@alignCast(h)));
}
