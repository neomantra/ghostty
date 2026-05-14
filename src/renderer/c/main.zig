//! Renderer C ABI surface.
//!
//! Mirrors the pattern used by terminal/c/main.zig: a small set of
//! `export fn` declarations that surface internal renderer constants
//! and (eventually) helper functions to embedders via the WebAssembly
//! / C function-export ABI.
//!
//! Sub-project #1 exposes only cell-layout constants (cell stride and
//! flag bits). Subsequent sub-projects (#2 cell encoding, #3 shader
//! source, …) will grow this file with additional export fns.

const cell = @import("../cell.zig");

// -------------------------------------------------------------------------
// Cell layout constants
// -------------------------------------------------------------------------

export fn renderer_cell_bytes() u32 {
    return cell.CELL_BYTES;
}

export fn renderer_cell_u32s() u32 {
    return cell.CELL_U32S;
}

// -------------------------------------------------------------------------
// Cell flag bits
// -------------------------------------------------------------------------

export fn renderer_flag_bold() u32 {
    return cell.FLAG_BOLD;
}

export fn renderer_flag_italic() u32 {
    return cell.FLAG_ITALIC;
}

export fn renderer_flag_underline() u32 {
    return cell.FLAG_UNDERLINE;
}

export fn renderer_flag_strikethrough() u32 {
    return cell.FLAG_STRIKETHROUGH;
}

export fn renderer_flag_inverse() u32 {
    return cell.FLAG_INVERSE;
}

export fn renderer_flag_faint() u32 {
    return cell.FLAG_FAINT;
}

export fn renderer_flag_invisible() u32 {
    return cell.FLAG_INVISIBLE;
}

export fn renderer_flag_is_selected() u32 {
    return cell.FLAG_IS_SELECTED;
}

export fn renderer_flag_is_hyperlink_hovered() u32 {
    return cell.FLAG_IS_HYPERLINK_HOVERED;
}

export fn renderer_flag_is_link_range_hovered() u32 {
    return cell.FLAG_IS_LINK_RANGE_HOVERED;
}

export fn renderer_flag_is_block_element() u32 {
    return cell.FLAG_IS_BLOCK_ELEMENT;
}

export fn renderer_flag_is_kitty_placeholder() u32 {
    return cell.FLAG_IS_KITTY_PLACEHOLDER;
}

export fn renderer_flag_use_theme_fg() u32 {
    return cell.FLAG_USE_THEME_FG;
}

export fn renderer_flag_use_theme_bg() u32 {
    return cell.FLAG_USE_THEME_BG;
}

export fn renderer_flag_is_cursor_cell() u32 {
    return cell.FLAG_IS_CURSOR_CELL;
}

// -------------------------------------------------------------------------
// Cell encoding (sub-project #2)
// -------------------------------------------------------------------------

const encode = @import("encode_cells.zig");
const frame_ctx_mod = @import("frame_ctx.zig");

// ghostty-web: encode_cells.zig re-declares the cell-layout constants
// locally so the vt-only test target can compile without pulling the
// renderer's font/Metal/OpenGL dependencies via `../cell.zig`. Pin the
// two copies together with a compile-time assertion that runs whenever
// the C-ABI surface is built (i.e., the canonical place that imports
// both modules).
comptime {
    if (encode.cell_layout.CELL_BYTES != cell.CELL_BYTES) @compileError("cell layout drift: CELL_BYTES");
    if (encode.cell_layout.CELL_U32S != cell.CELL_U32S) @compileError("cell layout drift: CELL_U32S");
    if (encode.cell_layout.FLAG_BOLD != cell.FLAG_BOLD) @compileError("cell layout drift: FLAG_BOLD");
    if (encode.cell_layout.FLAG_ITALIC != cell.FLAG_ITALIC) @compileError("cell layout drift: FLAG_ITALIC");
    if (encode.cell_layout.FLAG_UNDERLINE != cell.FLAG_UNDERLINE) @compileError("cell layout drift: FLAG_UNDERLINE");
    if (encode.cell_layout.FLAG_STRIKETHROUGH != cell.FLAG_STRIKETHROUGH) @compileError("cell layout drift: FLAG_STRIKETHROUGH");
    if (encode.cell_layout.FLAG_INVERSE != cell.FLAG_INVERSE) @compileError("cell layout drift: FLAG_INVERSE");
    if (encode.cell_layout.FLAG_FAINT != cell.FLAG_FAINT) @compileError("cell layout drift: FLAG_FAINT");
    if (encode.cell_layout.FLAG_INVISIBLE != cell.FLAG_INVISIBLE) @compileError("cell layout drift: FLAG_INVISIBLE");
    if (encode.cell_layout.FLAG_IS_SELECTED != cell.FLAG_IS_SELECTED) @compileError("cell layout drift: FLAG_IS_SELECTED");
    if (encode.cell_layout.FLAG_IS_HYPERLINK_HOVERED != cell.FLAG_IS_HYPERLINK_HOVERED) @compileError("cell layout drift: FLAG_IS_HYPERLINK_HOVERED");
    if (encode.cell_layout.FLAG_IS_LINK_RANGE_HOVERED != cell.FLAG_IS_LINK_RANGE_HOVERED) @compileError("cell layout drift: FLAG_IS_LINK_RANGE_HOVERED");
    if (encode.cell_layout.FLAG_IS_BLOCK_ELEMENT != cell.FLAG_IS_BLOCK_ELEMENT) @compileError("cell layout drift: FLAG_IS_BLOCK_ELEMENT");
    if (encode.cell_layout.FLAG_IS_KITTY_PLACEHOLDER != cell.FLAG_IS_KITTY_PLACEHOLDER) @compileError("cell layout drift: FLAG_IS_KITTY_PLACEHOLDER");
    if (encode.cell_layout.FLAG_USE_THEME_FG != cell.FLAG_USE_THEME_FG) @compileError("cell layout drift: FLAG_USE_THEME_FG");
    if (encode.cell_layout.FLAG_USE_THEME_BG != cell.FLAG_USE_THEME_BG) @compileError("cell layout drift: FLAG_USE_THEME_BG");
    if (encode.cell_layout.FLAG_IS_CURSOR_CELL != cell.FLAG_IS_CURSOR_CELL) @compileError("cell layout drift: FLAG_IS_CURSOR_CELL");
}

export fn renderer_frame_ctx_size() u32 {
    return @sizeOf(frame_ctx_mod.FrameCtx);
}

export fn renderer_needs_atlas_entry_size() u32 {
    return @sizeOf(frame_ctx_mod.NeedsAtlasEntry);
}

export fn renderer_encode_output_size() u32 {
    return @sizeOf(frame_ctx_mod.EncodeOutput);
}

export fn renderer_encode_cells_phase1(ctx_ptr: u32, out_ptr: u32) i32 {
    const ctx: *const frame_ctx_mod.FrameCtx = @ptrFromInt(ctx_ptr);
    const out: *frame_ctx_mod.EncodeOutput = @ptrFromInt(out_ptr);
    return encode.encodeCellsPhase1(ctx, out);
}
