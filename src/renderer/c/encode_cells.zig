//! Per-frame cell encoder. Walks Screen.pages over the visible
//! viewport, writes packed bytes into a JS-owned output buffer, and
//! appends NeedsAtlasEntry records for cells that need glyph lookup.
//!
//! Two-phase protocol — atlas slot UVs are filled by JS post-walking
//! the needs-atlas list. See docs/superpowers/specs/2026-05-14-cell-encoding-wasm-design.md.

const std = @import("std");
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
