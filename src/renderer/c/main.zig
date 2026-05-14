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
