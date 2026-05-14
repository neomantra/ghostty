//! Per-frame cell encoder. Walks Screen.pages over the visible
//! viewport, writes packed bytes into a JS-owned output buffer, and
//! appends NeedsAtlasEntry records for cells that need glyph lookup.
//!
//! Two-phase protocol — atlas slot UVs are filled by JS post-walking
//! the needs-atlas list. See docs/superpowers/specs/2026-05-14-cell-encoding-wasm-design.md.

const std = @import("std");
const builtin = @import("builtin");
const frame_ctx = @import("frame_ctx.zig");
const terminal = @import("../../terminal/main.zig");
const terminal_c = @import("../../terminal/c/terminal.zig");

pub const FrameCtx = frame_ctx.FrameCtx;
pub const NeedsAtlasEntry = frame_ctx.NeedsAtlasEntry;
pub const EncodeOutput = frame_ctx.EncodeOutput;

// Cell-layout constants. The canonical definitions live in
// `renderer/cell.zig` (referenced by the C-ABI surface in
// `renderer/c/main.zig`). We re-declare them here so that the encoder
// stays a leaf module — importing `../cell.zig` would transitively
// pull in `font/main.zig` and `renderer.zig` (with its Metal/OpenGL
// backends), which the vt-only test target cannot compile.
// `renderer/c/main.zig` carries a `comptime` assertion that pins
// these against the canonical module so the two cannot silently drift.
pub const cell_layout = struct {
    pub const CELL_BYTES: u32 = 32;
    pub const CELL_U32S: u32 = CELL_BYTES / 4;
    pub const FLAG_BOLD: u32 = 1 << 0;
    pub const FLAG_ITALIC: u32 = 1 << 1;
    pub const FLAG_UNDERLINE: u32 = 1 << 2;
    pub const FLAG_STRIKETHROUGH: u32 = 1 << 3;
    pub const FLAG_INVERSE: u32 = 1 << 4;
    pub const FLAG_FAINT: u32 = 1 << 5;
    pub const FLAG_INVISIBLE: u32 = 1 << 6;
    pub const FLAG_IS_SELECTED: u32 = 1 << 7;
    pub const FLAG_IS_HYPERLINK_HOVERED: u32 = 1 << 8;
    pub const FLAG_IS_LINK_RANGE_HOVERED: u32 = 1 << 9;
    pub const FLAG_IS_BLOCK_ELEMENT: u32 = 1 << 10;
    pub const FLAG_IS_KITTY_PLACEHOLDER: u32 = 1 << 11;
    pub const FLAG_USE_THEME_FG: u32 = 1 << 12;
    pub const FLAG_USE_THEME_BG: u32 = 1 << 13;
    pub const FLAG_IS_CURSOR_CELL: u32 = 1 << 14;
};

// ---------------------------------------------------------------------------
// Decoration helpers
// ---------------------------------------------------------------------------

/// Per-row selection column range. Mirrors the TS `updateRowSel` logic.
const RowSelRange = struct {
    start_col: i32,
    end_col: i32, // inclusive

    fn forRow(ctx: *const FrameCtx, row_in_viewport: i32) RowSelRange {
        if (ctx.selection_present == 0) return .{ .start_col = -1, .end_col = -1 };
        if (ctx.selection_start_row == ctx.selection_end_row) {
            if (row_in_viewport == ctx.selection_start_row) {
                return .{ .start_col = ctx.selection_start_col, .end_col = ctx.selection_end_col };
            }
            return .{ .start_col = -1, .end_col = -1 };
        }
        if (row_in_viewport == ctx.selection_start_row) {
            return .{ .start_col = ctx.selection_start_col, .end_col = std.math.maxInt(i32) };
        }
        if (row_in_viewport == ctx.selection_end_row) {
            return .{ .start_col = 0, .end_col = ctx.selection_end_col };
        }
        if (row_in_viewport > ctx.selection_start_row and row_in_viewport < ctx.selection_end_row) {
            return .{ .start_col = 0, .end_col = std.math.maxInt(i32) };
        }
        return .{ .start_col = -1, .end_col = -1 };
    }
};

/// Returns true if (row, col) falls within the JS-supplied link hover range.
/// Mirrors the TS `inRange` logic for ctx.hoveredLinkRange.
fn linkRangeContains(ctx: *const FrameCtx, row: i32, col: i32) bool {
    if (ctx.link_range_present == 0) return false;
    const r = ctx.link_range_start_row;
    const re = ctx.link_range_end_row;
    const cs = ctx.link_range_start_col;
    const ce = ctx.link_range_end_col;
    return (row == r and col >= cs and (row < re or col <= ce)) or
        (row > r and row < re) or
        (row == re and col <= ce and (row > r or col >= cs));
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Encode one frame. Returns the same status value as out.status:
/// 0 on success, negative on failure.
pub fn encodeCellsPhase1(ctx: *const FrameCtx, out: *EncodeOutput) i32 {
    out.* = .{
        .needs_atlas_count = 0,
        .used_kitty_image_count = 0,
        .used_kitty_image_ids = .{0} ** 16,
        .status = 0,
    };

    // Resolve terminal handle. The JS-side stores `*TerminalWrapper`
    // in `terminal_handle`; recover the inner `*Terminal` via the
    // public C-ABI accessor.
    if (ctx.terminal_handle == 0) {
        out.status = -5;
        return -5;
    }
    const handle: terminal_c.Terminal = @ptrFromInt(ctx.terminal_handle);
    const term: *terminal.Terminal = terminal_c.terminalPtr(handle) orelse {
        out.status = -5;
        return -5;
    };

    const screen: *terminal.Screen = term.screens.active;
    const cols: u32 = @intCast(screen.pages.cols);
    const rows: u32 = @intCast(screen.pages.rows);

    // Validate output buffer size: rows*cols*CELL_BYTES.
    const required_bytes: u32 = rows * cols * cell_layout.CELL_BYTES;
    if (ctx.output_buf_len < required_bytes) {
        out.status = -1;
        return -1;
    }

    // Zero the entire output region first so empty / unwritten cells
    // are well-defined. Then walk the viewport and overwrite per-cell.
    const output_u32_count: u32 = required_bytes / 4;
    const output: [*]u32 = @ptrFromInt(ctx.output_buf_ptr);
    @memset(output[0..output_u32_count], 0);

    const default_empty_flags: u32 =
        cell_layout.FLAG_USE_THEME_FG | cell_layout.FLAG_USE_THEME_BG;

    // Running offset into the JS-owned grapheme scratch arena. We hand
    // out [start..start+len) slices to NeedsAtlasEntry records as we
    // encode glyph-bearing cells. Resets to 0 every encode call.
    var grapheme_scratch_used: u32 = 0;
    // Cast the JS-owned scratch + entry pointers once for readability —
    // ctx.{grapheme_scratch_ptr,needs_atlas_ptr} are stable across the
    // whole encode call, so threading these through the inner loop
    // reduces @ptrFromInt noise (not a perf win — pointer casts are free).
    const grapheme_buf: [*]u8 = @ptrFromInt(ctx.grapheme_scratch_ptr);
    const needs_atlas_entries: [*]NeedsAtlasEntry = @ptrFromInt(ctx.needs_atlas_ptr);

    // Walk active viewport rows top-to-bottom.
    var row_it = screen.pages.rowIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    var y: u32 = 0;
    while (row_it.next()) |row_pin| : (y += 1) {
        if (y >= rows) break;

        const page_ptr: *terminal.Page = &row_pin.node.data;
        const row_cells: []const terminal.page.Cell = page_ptr.getCells(
            row_pin.rowAndCell().row,
        );

        // Compute the selection column range for this row once (hoisted
        // outside the inner x loop to avoid redundant work per cell).
        const row_sel = RowSelRange.forRow(ctx, @intCast(y));

        var x: u32 = 0;
        while (x < cols) : (x += 1) {
            const i: u32 = (y * cols + x) * cell_layout.CELL_U32S;
            const cell = row_cells[x];

            // Skip spacer-tail cells (right half of a wide pair). The
            // wide-cell pairing logic lives in a later task; for now
            // we leave these as default-empty so they don't render
            // garbage. The left half encodes both halves' visual.
            if (cell.wide == .spacer_tail) {
                output[i + 4] = default_empty_flags;
                continue;
            }

            // Detect "no content" cells. Cell.isEmpty handles all the
            // content_tag cases for us. For bg-only cells we still
            // want to encode the bg color, so split: an isEmpty cell
            // gets the default-empty flag set; anything else falls
            // through to the styled path.
            if (cell.isEmpty()) {
                output[i + 4] = default_empty_flags;
                continue;
            }

            // Look up style. style_id == 0 is the default style; avoid
            // the styles.get() call for the common case.
            const style: terminal.Style = if (cell.style_id == 0) .{} else page_ptr.styles.get(
                page_ptr.memory,
                cell.style_id,
            ).*;

            var flags: u32 = 0;
            if (style.flags.bold) flags |= cell_layout.FLAG_BOLD;
            if (style.flags.italic) flags |= cell_layout.FLAG_ITALIC;
            if (style.flags.underline != .none) flags |= cell_layout.FLAG_UNDERLINE;
            if (style.flags.strikethrough) flags |= cell_layout.FLAG_STRIKETHROUGH;
            if (style.flags.inverse) flags |= cell_layout.FLAG_INVERSE;
            if (style.flags.faint) flags |= cell_layout.FLAG_FAINT;
            if (style.flags.invisible) flags |= cell_layout.FLAG_INVISIBLE;

            // --- Decoration bits (selection / hover) ---------------------

            // Selection: check if this cell's column falls in the
            // per-row selection range computed above.
            const col_i32: i32 = @intCast(x);
            if (col_i32 >= row_sel.start_col and col_i32 <= row_sel.end_col) {
                flags |= cell_layout.FLAG_IS_SELECTED;
            }

            // Hyperlink hover: the cell carries a bool `hyperlink` when it
            // participates in a hyperlink; resolve the id via the page map
            // and compare against ctx.hovered_hyperlink_id.
            if (cell.hyperlink and ctx.hovered_hyperlink_id != 0) {
                if (page_ptr.lookupHyperlink(&row_cells[x])) |hid| {
                    if (@as(u32, hid) == ctx.hovered_hyperlink_id) {
                        flags |= cell_layout.FLAG_IS_HYPERLINK_HOVERED;
                    }
                }
            }

            // Link range hover: a rectangular (possibly multi-row) range
            // supplied by JS for OSC 8 / regex-matched links.
            if (linkRangeContains(ctx, @intCast(y), col_i32)) {
                flags |= cell_layout.FLAG_IS_LINK_RANGE_HOVERED;
            }

            // Resolve fg color. style.fg_color is .none/.palette/.rgb.
            // For palette indices we read the terminal palette; for
            // .none we leave the rgb bytes zero and set
            // FLAG_USE_THEME_FG (the JS-side renderer fills in the
            // theme default at draw time, matching the TS encoder).
            var fg_r: u8 = 0;
            var fg_g: u8 = 0;
            var fg_b: u8 = 0;
            switch (style.fg_color) {
                .none => flags |= cell_layout.FLAG_USE_THEME_FG,
                .palette => |idx| {
                    const rgb = term.colors.palette.current[idx];
                    fg_r = rgb.r;
                    fg_g = rgb.g;
                    fg_b = rgb.b;
                },
                .rgb => |rgb| {
                    fg_r = rgb.r;
                    fg_g = rgb.g;
                    fg_b = rgb.b;
                },
            }

            // Resolve bg color. Cells with a bg_color_palette or
            // bg_color_rgb content_tag carry the color inline (these
            // are "bg-only" cells that bypass the style map): they
            // have no codepoint but isEmpty() returns false, so they
            // reach this branch and we read the color from content_tag
            // directly rather than via the style map.
            var bg_r: u8 = 0;
            var bg_g: u8 = 0;
            var bg_b: u8 = 0;
            switch (cell.content_tag) {
                .bg_color_palette => {
                    const rgb = term.colors.palette.current[cell.content.color_palette];
                    bg_r = rgb.r;
                    bg_g = rgb.g;
                    bg_b = rgb.b;
                },
                .bg_color_rgb => {
                    bg_r = cell.content.color_rgb.r;
                    bg_g = cell.content.color_rgb.g;
                    bg_b = cell.content.color_rgb.b;
                },
                .codepoint, .codepoint_grapheme => switch (style.bg_color) {
                    .none => flags |= cell_layout.FLAG_USE_THEME_BG,
                    .palette => |idx| {
                        const rgb = term.colors.palette.current[idx];
                        bg_r = rgb.r;
                        bg_g = rgb.g;
                        bg_b = rgb.b;
                    },
                    .rgb => |rgb| {
                        bg_r = rgb.r;
                        bg_g = rgb.g;
                        bg_b = rgb.b;
                    },
                },
            }

            // Pack colors as little-endian rgba8 (matches TS layout:
            // `c.fg_r | (c.fg_g << 8) | (c.fg_b << 16)`).
            const fg_packed: u32 =
                @as(u32, fg_r) |
                (@as(u32, fg_g) << 8) |
                (@as(u32, fg_b) << 16);
            const bg_packed: u32 =
                @as(u32, bg_r) |
                (@as(u32, bg_g) << 8) |
                (@as(u32, bg_b) << 16);

            output[i + 0] = fg_packed;
            output[i + 1] = bg_packed;
            // output[i+2..i+3] (atlas slot UV/wh) stay zero — filled
            // by JS post-walker in Task 6.
            output[i + 4] = flags;
            // output[i+5..i+7] (special-cell payloads) stay zero —
            // populated in Task 8 (block element / kitty placeholder).

            // ----- Atlas-needs emission ----------------------------
            // Skip cells with no glyph to render: invisible cells, and
            // bg-only cells (content_tag of bg_color_*). FLAG_IS_BLOCK_ELEMENT
            // and FLAG_IS_KITTY_PLACEHOLDER will also gate here when added in
            // Task 8; for now they're never set.
            const cp: u21 = cell.codepoint();
            const skip_atlas =
                (flags & cell_layout.FLAG_INVISIBLE) != 0 or
                cp == 0;
            if (skip_atlas) continue;

            if (out.needs_atlas_count >= ctx.needs_atlas_capacity) {
                out.status = -2;
                return -2;
            }

            // Build grapheme UTF-8 into the scratch arena, base
            // codepoint first then any combining-mark extras.
            const grapheme_start: usize = ctx.grapheme_scratch_ptr + grapheme_scratch_used;
            var write_len: u32 = 0;

            var utf8_buf: [4]u8 = undefined;
            const base_len: u32 = blk: {
                const n = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                    // Invalid codepoint — should never happen because
                    // ghostty validates codepoints when ingesting VT
                    // streams (terminal/stream.zig + parser.zig refuse
                    // surrogate halves and >U+10FFFF). If it ever does,
                    // silently dropping the atlas entry means this one
                    // cell renders without a glyph but the rest of the
                    // frame is fine — preferable to aborting the whole
                    // encode. Color/flag bytes for this cell are still
                    // written above so the bg shows correctly.
                    @branchHint(.cold);
                    break :blk 0;
                };
                break :blk @intCast(n);
            };
            if (base_len == 0) continue;
            if (grapheme_scratch_used + base_len > ctx.grapheme_scratch_len) {
                out.status = -3;
                return -3;
            }
            @memcpy(
                grapheme_buf[grapheme_scratch_used .. grapheme_scratch_used + base_len],
                utf8_buf[0..base_len],
            );
            grapheme_scratch_used += base_len;
            write_len += base_len;

            // Grapheme extras (combining marks). lookupGrapheme returns
            // the EXTRA codepoints only — the base is not included.
            if (cell.hasGrapheme()) {
                if (page_ptr.lookupGrapheme(&row_cells[x])) |extras| {
                    for (extras) |extra_cp| {
                        const extra_len: u32 = blk: {
                            const n = std.unicode.utf8Encode(extra_cp, &utf8_buf) catch {
                                @branchHint(.cold);
                                break :blk 0;
                            };
                            break :blk @intCast(n);
                        };
                        if (extra_len == 0) continue;
                        if (grapheme_scratch_used + extra_len > ctx.grapheme_scratch_len) {
                            out.status = -3;
                            return -3;
                        }
                        @memcpy(
                            grapheme_buf[grapheme_scratch_used .. grapheme_scratch_used + extra_len],
                            utf8_buf[0..extra_len],
                        );
                        grapheme_scratch_used += extra_len;
                        write_len += extra_len;
                    }
                }
            }

            const style_bits: u32 =
                (if (flags & cell_layout.FLAG_BOLD != 0) @as(u32, 1) else 0) |
                (if (flags & cell_layout.FLAG_ITALIC != 0) @as(u32, 2) else 0);

            const width_in_cells: u32 = if (cell.wide == .wide) 2 else 1;

            needs_atlas_entries[out.needs_atlas_count] = .{
                .cell_offset = i,
                .grapheme_utf8_ptr = grapheme_start,
                .grapheme_utf8_len = write_len,
                .style_bits = style_bits,
                .width_in_cells = width_in_cells,
            };
            out.needs_atlas_count += 1;
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestFixture = struct {
    // 80*24 cells * 8 u32s per cell = 15360 u32s.
    output_buf: [80 * 24 * cell_layout.CELL_U32S]u32 = .{0} ** (80 * 24 * cell_layout.CELL_U32S),
    needs_atlas: [80 * 24]NeedsAtlasEntry = undefined,
    grapheme_scratch: [80 * 24 * 32]u8 = undefined,

    fn baseCtx(self: *@This(), handle: usize) FrameCtx {
        return .{
            .terminal_handle = handle,
            .viewport_y = 0,
            .scrollback_len = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .cursor_style = 0,
            .cursor_visible_blink = 0,
            .selection_present = 0,
            .selection_start_row = -1,
            .selection_start_col = -1,
            .selection_end_row = -1,
            .selection_end_col = -1,
            .hovered_hyperlink_id = 0,
            .link_range_present = 0,
            .link_range_start_row = -1,
            .link_range_start_col = -1,
            .link_range_end_row = -1,
            .link_range_end_col = -1,
            .metrics_cell_w = 8,
            .metrics_cell_h = 16,
            .metrics_baseline = 12,
            .kitty_enabled = 0,
            .block_element_enabled = 0,
            .max_kitty_images = 16,
            .output_buf_ptr = @intFromPtr(&self.output_buf),
            .output_buf_len = @sizeOf(@TypeOf(self.output_buf)),
            .needs_atlas_ptr = @intFromPtr(&self.needs_atlas),
            .needs_atlas_capacity = self.needs_atlas.len,
            .grapheme_scratch_ptr = @intFromPtr(&self.grapheme_scratch),
            .grapheme_scratch_len = self.grapheme_scratch.len,
            .kitty_image_table_ptr = 0,
            .kitty_image_table_len = 0,
        };
    }
};

/// Build a TerminalWrapper-shaped value backed by a real Terminal so the
/// encoder can dereference it the same way the JS-side does in production.
/// We construct one via the C ABI `new`, but to also have an owning
/// `Terminal` we can call `.printString`/`vtStream` on, we expose the
/// inner terminal via `terminal_c.terminalPtr` after creation.
const HostTestTerminal = struct {
    wrapper_handle: terminal_c.Terminal,
    inner: *terminal.Terminal,

    fn init(cols: u16, rows: u16) !HostTestTerminal {
        // Use the C-ABI `new` to construct a wrapper around a fresh
        // Terminal — this mirrors exactly what the JS side does.
        var h: terminal_c.Terminal = null;
        const res = terminal_c.new(null, &h, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 0,
        });
        if (res != .success) return error.TerminalInitFailed;
        const inner = terminal_c.terminalPtr(h).?;
        return .{ .wrapper_handle = h, .inner = inner };
    }

    fn deinit(self: *HostTestTerminal) void {
        terminal_c.free(self.wrapper_handle);
    }

    fn handle(self: HostTestTerminal) usize {
        return @intFromPtr(self.wrapper_handle);
    }
};

test "encodeCellsPhase1: zero handle returns -5" {
    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(0);
    var out: EncodeOutput = undefined;

    const rc = encodeCellsPhase1(&ctx, &out);
    try std.testing.expectEqual(@as(i32, -5), rc);
    try std.testing.expectEqual(@as(i32, -5), out.status);
}

test "encodeCellsPhase1: empty 80x24 grid has default-empty flags" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    const rc = encodeCellsPhase1(&ctx, &out);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 0), out.status);

    const expected_flags = cell_layout.FLAG_USE_THEME_FG | cell_layout.FLAG_USE_THEME_BG;
    for (0..80 * 24) |idx| {
        const cell_word = fixture.output_buf[idx * cell_layout.CELL_U32S + 4];
        try std.testing.expectEqual(expected_flags, cell_word);
        // fg/bg color words are zero for empty cells.
        try std.testing.expectEqual(@as(u32, 0), fixture.output_buf[idx * cell_layout.CELL_U32S + 0]);
        try std.testing.expectEqual(@as(u32, 0), fixture.output_buf[idx * cell_layout.CELL_U32S + 1]);
    }
}

test "encodeCellsPhase1: single ASCII bold cell encodes flags" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    // SGR bold + red fg, write 'A', reset. Use the persistent vt stream
    // on the wrapper so escape sequences are interpreted (printString
    // alone only handles printable codepoints).
    const seq = "\x1b[1;31mA\x1b[0m";
    terminal_c.vt_write(term.wrapper_handle, seq.ptr, seq.len);

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    const rc = encodeCellsPhase1(&ctx, &out);
    try std.testing.expectEqual(@as(i32, 0), rc);

    // Cell (0,0) should have FLAG_BOLD set, and FLAG_USE_THEME_BG (no
    // explicit bg was set). FLAG_USE_THEME_FG should NOT be set
    // because fg was set to palette index 1 (red).
    const flags = fixture.output_buf[4];
    try std.testing.expect(flags & cell_layout.FLAG_BOLD != 0);
    try std.testing.expect(flags & cell_layout.FLAG_USE_THEME_BG != 0);
    try std.testing.expect(flags & cell_layout.FLAG_USE_THEME_FG == 0);

    // fg color word should be non-zero (red palette entry).
    try std.testing.expect(fixture.output_buf[0] != 0);
    // bg color word should be zero (default theme bg).
    try std.testing.expectEqual(@as(u32, 0), fixture.output_buf[1]);

    // Cell (0,1) onward should be empty.
    const second_flags = fixture.output_buf[cell_layout.CELL_U32S + 4];
    const expected_empty = cell_layout.FLAG_USE_THEME_FG | cell_layout.FLAG_USE_THEME_BG;
    try std.testing.expectEqual(expected_empty, second_flags);
}

test "encodeCellsPhase1: single ASCII A emits one NeedsAtlasEntry with 'A'" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    const seq = "A";
    terminal_c.vt_write(term.wrapper_handle, seq.ptr, seq.len);

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    try std.testing.expectEqual(@as(u32, 1), out.needs_atlas_count);
    const e = fixture.needs_atlas[0];
    try std.testing.expectEqual(@as(u32, 0), e.cell_offset);
    try std.testing.expectEqual(@as(u32, 1), e.width_in_cells);
    try std.testing.expectEqual(@as(u32, 0), e.style_bits);

    // Grapheme bytes should be "A".
    const grapheme_buf: [*]const u8 = @ptrFromInt(e.grapheme_utf8_ptr);
    try std.testing.expectEqualSlices(u8, "A", grapheme_buf[0..e.grapheme_utf8_len]);
}

test "encodeCellsPhase1: bold A sets style_bits=1" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    const seq = "\x1b[1mA\x1b[0m";
    terminal_c.vt_write(term.wrapper_handle, seq.ptr, seq.len);

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    try std.testing.expectEqual(@as(u32, 1), out.needs_atlas_count);
    try std.testing.expectEqual(@as(u32, 1), fixture.needs_atlas[0].style_bits); // bold
}

test "encodeCellsPhase1: CJK wide glyph emits one entry width=2" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    // U+6F22 "漢" — wide CJK ideograph (3 bytes UTF-8).
    const seq = "\xE6\xBC\xA2";
    terminal_c.vt_write(term.wrapper_handle, seq.ptr, seq.len);

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    try std.testing.expectEqual(@as(u32, 1), out.needs_atlas_count);
    try std.testing.expectEqual(@as(u32, 2), fixture.needs_atlas[0].width_in_cells);
    try std.testing.expectEqual(@as(u32, 0), fixture.needs_atlas[0].cell_offset);
}

test "encodeCellsPhase1: 'e' + combining acute emits one entry with 2 codepoints" {
    var term = try HostTestTerminal.init(80, 24);
    defer term.deinit();

    // 'e' + U+0301 combining acute (0xCC 0x81 in UTF-8) → é.
    const seq = "e\xCC\x81";
    terminal_c.vt_write(term.wrapper_handle, seq.ptr, seq.len);

    var fixture: TestFixture = .{};
    const ctx = fixture.baseCtx(term.handle());
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    try std.testing.expectEqual(@as(u32, 1), out.needs_atlas_count);
    const e = fixture.needs_atlas[0];
    const grapheme_buf: [*]const u8 = @ptrFromInt(e.grapheme_utf8_ptr);
    // 'e' (1 byte) + combining acute U+0301 (2 bytes: 0xCC 0x81) = 3 bytes.
    try std.testing.expectEqual(@as(u32, 3), e.grapheme_utf8_len);
    try std.testing.expectEqualSlices(u8, "e\xCC\x81", grapheme_buf[0..e.grapheme_utf8_len]);
}

test "encodeCellsPhase1: selection range sets FLAG_IS_SELECTED on cells inside" {
    var ht = try HostTestTerminal.init(80, 24);
    defer ht.deinit();
    terminal_c.vt_write(ht.wrapper_handle, "hello world", 11);

    var fixture: TestFixture = .{};
    var ctx = fixture.baseCtx(ht.handle());
    // Select columns 2..6 of row 0 (l, l, o, space, w).
    ctx.selection_present = 1;
    ctx.selection_start_row = 0;
    ctx.selection_start_col = 2;
    ctx.selection_end_row = 0;
    ctx.selection_end_col = 6;
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    // Cells 0 and 1 ('h', 'e') not selected.
    try std.testing.expect((fixture.output_buf[0 * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_SELECTED) == 0);
    try std.testing.expect((fixture.output_buf[1 * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_SELECTED) == 0);
    // Cells 2..6 selected.
    var i: usize = 2;
    while (i <= 6) : (i += 1) {
        try std.testing.expect((fixture.output_buf[i * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_SELECTED) != 0);
    }
    // Cell 7 ('o' in "world") not selected.
    try std.testing.expect((fixture.output_buf[7 * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_SELECTED) == 0);
}

test "encodeCellsPhase1: link range hover sets FLAG_IS_LINK_RANGE_HOVERED" {
    var ht = try HostTestTerminal.init(80, 24);
    defer ht.deinit();
    terminal_c.vt_write(ht.wrapper_handle, "hello world", 11);

    var fixture: TestFixture = .{};
    var ctx = fixture.baseCtx(ht.handle());
    // Hover columns 3..7 on row 0.
    ctx.link_range_present = 1;
    ctx.link_range_start_row = 0;
    ctx.link_range_start_col = 3;
    ctx.link_range_end_row = 0;
    ctx.link_range_end_col = 7;
    var out: EncodeOutput = undefined;

    _ = encodeCellsPhase1(&ctx, &out);

    // Cells 0..2 not in range.
    var j: usize = 0;
    while (j <= 2) : (j += 1) {
        try std.testing.expect((fixture.output_buf[j * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_LINK_RANGE_HOVERED) == 0);
    }
    // Cells 3..7 in range.
    j = 3;
    while (j <= 7) : (j += 1) {
        try std.testing.expect((fixture.output_buf[j * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_LINK_RANGE_HOVERED) != 0);
    }
    // Cell 8 not in range.
    try std.testing.expect((fixture.output_buf[8 * cell_layout.CELL_U32S + 4] & cell_layout.FLAG_IS_LINK_RANGE_HOVERED) == 0);
}
