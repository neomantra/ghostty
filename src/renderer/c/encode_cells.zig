//! Per-frame cell encoder. Walks Screen.pages over the visible
//! viewport, writes packed bytes into a JS-owned output buffer, and
//! appends NeedsAtlasEntry records for cells that need glyph lookup.
//!
//! Two-phase protocol — atlas slot UVs are filled by JS post-walking
//! the needs-atlas list. See docs/superpowers/specs/2026-05-14-cell-encoding-wasm-design.md.

const std = @import("std");
const builtin = @import("builtin");
const frame_ctx = @import("frame_ctx.zig");

pub const FrameCtx = frame_ctx.FrameCtx;
pub const NeedsAtlasEntry = frame_ctx.NeedsAtlasEntry;
pub const EncodeOutput = frame_ctx.EncodeOutput;

/// Encode one frame. Returns the same status value as out.status:
/// 0 on success, negative on failure.
pub fn encodeCellsPhase1(ctx: *const FrameCtx, out: *EncodeOutput) i32 {
    // Stub: zero output, no entries.
    out.* = .{
        .needs_atlas_count = 0,
        .used_kitty_image_count = 0,
        .used_kitty_image_ids = .{0} ** 16,
        .status = 0,
    };
    _ = ctx;
    return 0;
}

test "encodeCellsPhase1 stub: returns success with zero output" {
    var output_buf: [16]u32 = .{0} ** 16;
    var needs_atlas: [4]NeedsAtlasEntry = undefined;
    var grapheme_scratch: [256]u8 = undefined;

    // output_buf_ptr, needs_atlas_ptr, grapheme_scratch_ptr are u32 ABI fields
    // (WASM is 32-bit so pointers fit). On 64-bit host we truncate — safe here
    // because the stub body never dereferences these fields.
    const ctx: FrameCtx = .{
        .terminal_handle = 0,
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
        .output_buf_ptr = @truncate(@intFromPtr(&output_buf)),
        .output_buf_len = @sizeOf(@TypeOf(output_buf)),
        .needs_atlas_ptr = @truncate(@intFromPtr(&needs_atlas)),
        .needs_atlas_capacity = needs_atlas.len,
        .grapheme_scratch_ptr = @truncate(@intFromPtr(&grapheme_scratch)),
        .grapheme_scratch_len = grapheme_scratch.len,
        .kitty_image_table_ptr = 0,
        .kitty_image_table_len = 0,
    };
    var out: EncodeOutput = undefined;

    const rc = encodeCellsPhase1(&ctx, &out);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 0), out.status);
    try std.testing.expectEqual(@as(u32, 0), out.needs_atlas_count);
    try std.testing.expectEqual(@as(u32, 0), out.used_kitty_image_count);
}
