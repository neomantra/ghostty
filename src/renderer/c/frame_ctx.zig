//! Plain-data layouts for the renderer cell-encoding C ABI.
//!
//! These extern structs are written/read by both the WASM-side encoder
//! and the JS-side wrapper in lib/renderer-wasm-encode.ts. The layouts
//! must match exactly — JS uses a DataView with byte offsets derived
//! from these field orderings.

/// Per-frame input written by JS into linear memory and read by
/// renderer_encode_cells_phase1. Fields are u32 except for signed
/// row/col coords that may be -1 (sentinel for "not set").
pub const FrameCtx = extern struct {
    terminal_handle: u32,
    viewport_y: u32,
    scrollback_len: u32,

    cursor_x: u32,
    cursor_y: u32,
    /// 0=block, 1=underline, 2=bar
    cursor_style: u32,
    /// bit 0: cursor.visible, bit 1: blink_visible
    cursor_visible_blink: u32,

    /// 0 if no selection, else 1.
    selection_present: u32,
    selection_start_row: i32,
    selection_start_col: i32,
    selection_end_row: i32,
    selection_end_col: i32,

    /// 0 if no hyperlink hover, else the id.
    hovered_hyperlink_id: u32,
    /// 0 if no link range hover, else 1.
    link_range_present: u32,
    link_range_start_row: i32,
    link_range_start_col: i32,
    link_range_end_row: i32,
    link_range_end_col: i32,

    metrics_cell_w: u32,
    metrics_cell_h: u32,
    metrics_baseline: u32,

    kitty_enabled: u32,
    block_element_enabled: u32,
    max_kitty_images: u32,

    /// Output: packed cell bytes. Sized for rows*cols*CELL_BYTES.
    output_buf_ptr: u32,
    output_buf_len: u32,

    /// Output: NeedsAtlasEntry array. Capacity = rows*cols.
    needs_atlas_ptr: u32,
    needs_atlas_capacity: u32,

    /// Output: grapheme UTF-8 scratch arena. Capacity should be
    /// rows*cols*32 bytes (generous upper bound).
    grapheme_scratch_ptr: u32,
    grapheme_scratch_len: u32,

    /// Input: JS-prepared imageId -> (idx in used_kitty_image_ids) map,
    /// for kitty placeholder cells. Format: pairs of (imageId, idx) u32,
    /// terminated by imageId==0. Read but not written by WASM.
    kitty_image_table_ptr: u32,
    kitty_image_table_len: u32,
};

/// Per-cell atlas-lookup request emitted by the WASM encoder for each
/// cell that needs a glyph rendered. JS post-walks the list and calls
/// GlyphAtlasBase.getOrRaster to resolve the slot UVs.
pub const NeedsAtlasEntry = extern struct {
    /// Offset into FrameCtx.output_buf in u32 units (i.e., index of the
    /// first u32 of this cell's 8-u32 record).
    cell_offset: u32,
    /// Pointer into the grapheme_scratch arena.
    grapheme_utf8_ptr: u32,
    grapheme_utf8_len: u32,
    /// bit 0: bold, bit 1: italic.
    style_bits: u32,
    /// 1 or 2.
    width_in_cells: u32,
};

/// Return struct written by the encoder.
pub const EncodeOutput = extern struct {
    /// Number of NeedsAtlasEntry rows written into needs_atlas_ptr.
    needs_atlas_count: u32,
    /// Number of valid entries in used_kitty_image_ids (0..16).
    used_kitty_image_count: u32,
    /// Image ids encountered, in order of first appearance. Capped at 16.
    used_kitty_image_ids: [16]u32,
    /// 0 on success, negative on failure (see spec error handling).
    status: i32,
};
