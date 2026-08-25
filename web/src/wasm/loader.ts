// Thin typed wrapper around the notein-core wasm module's raw C-ABI exports.
// No marshaling layer (no wasm-bindgen): every export takes/returns plain
// numbers (pointers are just u32 offsets into `memory`), and structured
// results are read back as typed-array *views* directly over wasm memory
// (zero-copy) using the `extern struct` layouts documented in wasm/src/main.zig.

interface NoteinExports {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  alloc_big(len: number): number;
  open(ptr: number, len: number): number;
  get_page_count(): number;
  get_page_info_ptr(): number;
  set_active_window(ptr: number, count: number): void;
  render_viewport(
    pageIndex: number,
    x: number,
    y: number,
    w: number,
    h: number,
    pixelW: number,
    pixelH: number,
    timeMin: number,
    timeMax: number,
    minStrokePx: number,
  ): number;
  get_visible_image_count(pageIndex: number, x: number, y: number, w: number, h: number): number;
  get_visible_image_ptr(): number;
  get_visible_textbox_count(pageIndex: number, x: number, y: number, w: number, h: number): number;
  get_visible_textbox_ptr(): number;
  get_bytes(namePtr: number, nameLen: number): number;
  get_bytes_len(): number;
  get_all_images_count(): number;
  get_all_images_ptr(): number;
  get_all_links_count(): number;
  get_all_links_ptr(): number;
  get_all_audio_count(): number;
  get_all_audio_ptr(): number;
  get_vector_content_count(pageIndex: number, x: number, y: number, w: number, h: number, timeMin: number, timeMax: number): number;
  get_vector_content_poly_ptr(): number;
  get_vector_content_vertex_ptr(): number;
}

export interface PageInfo {
  width: number;
  height: number;
  unbounded: boolean;
  color: number; // packed ARGB
}

export interface ImageDraw {
  left: number;
  top: number;
  right: number;
  bottom: number;
  name: string;
  creationTime: number; // epoch ms, for chronological/z-order interleaving with ink
}

export interface TextBoxDraw {
  left: number;
  top: number;
  right: number;
  bottom: number;
  size: number;
  color: number; // packed ARGB
  text: string;
  creationTime: number; // epoch ms, for chronological/z-order interleaving with ink
}

const PAGE_INFO_STRIDE = 16; // f32 width, f32 height, u32 unbounded, u32 color
const IMAGE_DRAW_STRIDE = 32; // 4x f32 bounds, u32 name_ptr, u32 name_len, f64 creation_time
const TEXTBOX_DRAW_STRIDE = 40; // 4x f32 bounds, f32 size, u32 color, u32 text_ptr, u32 text_len, f64 creation_time
const VECTOR_POLY_STRIDE = 24; // f64 creation_time, u32 color, u32 vertex_offset, u32 vertex_count
const ASSET_IMAGE_STRIDE = 40; // f64 creation_time, 4x f32 bounds, u32 page_index, u32 name_ptr, u32 name_len
const LINK_DRAW_STRIDE = 40; // f64 creation_time, 4x f32 bounds, u32 page_index, i32 link_type, u32 dest_ptr, u32 dest_len
const AUDIO_DRAW_STRIDE = 32; // f64 creation_time, f64 duration_ms, u32 name_ptr, u32 name_len, u32 entry_ptr, u32 entry_len

export interface AssetImage {
  pageIndex: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  name: string;
  creationTime: number;
}

export interface LinkAsset {
  pageIndex: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  destination: string;
  linkType: number;
  creationTime: number;
}

export interface AudioAsset {
  name: string;
  entryName: string;
  durationMs: number;
  creationTime: number;
}

export interface VectorPoly {
  color: number; // packed ARGB
  creationTime: number;
  points: Float32Array; // flat [x0, y0, x1, y1, ...]
}

export class NoteinModule {
  private constructor(private readonly exports: NoteinExports) {}

  static async load(wasmUrl: string): Promise<NoteinModule> {
    const resp = await fetch(wasmUrl);
    const bytes = await resp.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {});
    return new NoteinModule(instance.exports as unknown as NoteinExports);
  }

  private get memory(): ArrayBuffer {
    return this.exports.memory.buffer;
  }

  /** Current size of the wasm module's linear memory, in bytes. */
  get memoryBytes(): number {
    return this.exports.memory.buffer.byteLength;
  }

  private writeBytes(bytes: Uint8Array): { ptr: number; len: number } {
    const ptr = this.exports.alloc(bytes.length);
    if (ptr === 0 && bytes.length > 0) throw new Error("wasm alloc failed");
    new Uint8Array(this.memory, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  }

  private readString(ptr: number, len: number): string {
    return new TextDecoder().decode(new Uint8Array(this.memory, ptr, len));
  }

  /** Loads a `.in` file's bytes. Throws if the file can't be parsed.
   * Uses `alloc_big` (not the general-purpose `alloc`) since the uploaded
   * file is the one genuinely large, long-lived buffer per load -- see
   * wasm/src/big_alloc.zig. */
  openFile(bytes: Uint8Array): void {
    const ptr = this.exports.alloc_big(bytes.length);
    if (ptr === 0 && bytes.length > 0) throw new Error("wasm alloc failed");
    new Uint8Array(this.memory, ptr, bytes.length).set(bytes);
    const status = this.exports.open(ptr, bytes.length);
    if (status !== 0) throw new Error(`failed to parse .in file (status ${status})`);
  }

  getPages(): PageInfo[] {
    const count = this.exports.get_page_count();
    const ptr = this.exports.get_page_info_ptr();
    const pages: PageInfo[] = [];
    const view = new DataView(this.memory, ptr, count * PAGE_INFO_STRIDE);
    for (let i = 0; i < count; i++) {
      const base = i * PAGE_INFO_STRIDE;
      pages.push({
        width: view.getFloat32(base + 0, true),
        height: view.getFloat32(base + 4, true),
        unbounded: view.getUint32(base + 8, true) !== 0,
        color: view.getUint32(base + 12, true),
      });
    }
    return pages;
  }

  /** Call whenever the visible page range changes (scroll/pan/zoom crosses a page boundary). */
  setActiveWindow(pageIndices: number[]): void {
    const arr = new Uint32Array(pageIndices);
    const ptr = this.exports.alloc(arr.byteLength);
    new Uint32Array(this.memory, ptr, arr.length).set(arr);
    this.exports.set_active_window(ptr, arr.length);
  }

  /**
   * Rasterizes strokes+shapes for the given page/viewport, restricted to
   * items with creation_time in [timeMin, timeMax) (default: everything --
   * pass -Infinity/Infinity), into an RGBA buffer returned as a zero-copy
   * view into wasm memory (valid only until the next call that reuses the
   * canvas buffer -- copy it out, or draw it, before calling this again).
   * The time range lets the caller interleave multiple ink passes with
   * image/text compositing to get correct chronological stacking order.
   */
  renderViewport(
    pageIndex: number,
    x: number,
    y: number,
    w: number,
    h: number,
    pixelW: number,
    pixelH: number,
    timeMin = -Infinity,
    timeMax = Infinity,
    minStrokePx = 0,
  ): Uint8ClampedArray {
    const ptr = this.exports.render_viewport(pageIndex, x, y, w, h, pixelW, pixelH, timeMin, timeMax, minStrokePx);
    return new Uint8ClampedArray(this.memory, ptr, pixelW * pixelH * 4);
  }

  getVisibleImages(pageIndex: number, x: number, y: number, w: number, h: number): ImageDraw[] {
    const count = this.exports.get_visible_image_count(pageIndex, x, y, w, h);
    const ptr = this.exports.get_visible_image_ptr();
    const view = new DataView(this.memory, ptr, count * IMAGE_DRAW_STRIDE);
    const out: ImageDraw[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * IMAGE_DRAW_STRIDE;
      const namePtr = view.getUint32(base + 16, true);
      const nameLen = view.getUint32(base + 20, true);
      out.push({
        left: view.getFloat32(base + 0, true),
        top: view.getFloat32(base + 4, true),
        right: view.getFloat32(base + 8, true),
        bottom: view.getFloat32(base + 12, true),
        name: this.readString(namePtr, nameLen),
        creationTime: view.getFloat64(base + 24, true),
      });
    }
    return out;
  }

  getVisibleTextBoxes(pageIndex: number, x: number, y: number, w: number, h: number): TextBoxDraw[] {
    const count = this.exports.get_visible_textbox_count(pageIndex, x, y, w, h);
    const ptr = this.exports.get_visible_textbox_ptr();
    const view = new DataView(this.memory, ptr, count * TEXTBOX_DRAW_STRIDE);
    const out: TextBoxDraw[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * TEXTBOX_DRAW_STRIDE;
      const textPtr = view.getUint32(base + 24, true);
      const textLen = view.getUint32(base + 28, true);
      out.push({
        left: view.getFloat32(base + 0, true),
        top: view.getFloat32(base + 4, true),
        right: view.getFloat32(base + 8, true),
        bottom: view.getFloat32(base + 12, true),
        size: view.getFloat32(base + 16, true),
        color: view.getUint32(base + 20, true),
        text: this.readString(textPtr, textLen),
        creationTime: view.getFloat64(base + 32, true),
      });
    }
    return out;
  }

  /**
   * Returns strokes+shapes intersecting the given viewport/time range as
   * vector polygon outlines (for SVG/vector export), not rasterized pixels --
   * resolution-independent, so there's no pixel size to request. Each
   * `points` array is copied out of wasm memory immediately (unlike
   * `renderViewport`'s view), since it's cheap here and avoids the caller
   * needing to worry about wasm memory growth invalidating it mid-export.
   */
  getVectorContent(
    pageIndex: number,
    x: number,
    y: number,
    w: number,
    h: number,
    timeMin = -Infinity,
    timeMax = Infinity,
  ): VectorPoly[] {
    const count = this.exports.get_vector_content_count(pageIndex, x, y, w, h, timeMin, timeMax);
    const polyPtr = this.exports.get_vector_content_poly_ptr();
    const vertexPtr = this.exports.get_vector_content_vertex_ptr();
    const view = new DataView(this.memory, polyPtr, count * VECTOR_POLY_STRIDE);
    const out: VectorPoly[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * VECTOR_POLY_STRIDE;
      const creationTime = view.getFloat64(base + 0, true);
      const color = view.getUint32(base + 8, true);
      const vertexOffset = view.getUint32(base + 12, true);
      const vertexCount = view.getUint32(base + 16, true);
      const points = new Float32Array(this.memory, vertexPtr + vertexOffset * 8, vertexCount * 2).slice();
      out.push({ color, creationTime, points });
    }
    return out;
  }

  /** Fetches a zip asset's raw bytes (e.g. an image) by its entry name. */
  getBytes(name: string): Uint8Array {
    const nameBytes = new TextEncoder().encode(name);
    const { ptr, len } = this.writeBytes(nameBytes);
    const dataPtr = this.exports.get_bytes(ptr, len);
    const dataLen = this.exports.get_bytes_len();
    // Copy out immediately: the returned buffer is reused on the next call.
    return new Uint8Array(this.memory, dataPtr, dataLen).slice();
  }

  // Zero-length Zig allocations return a dangling sentinel pointer (e.g.
  // 0xFFFFFFF8), which JS reads as a large negative i32 -- DataView rejects
  // that as an out-of-bounds offset. Short-circuit before touching *_ptr().
  /** All images in the note (not viewport-culled), for the Media panel. */
  getAllImages(): AssetImage[] {
    const count = this.exports.get_all_images_count();
    if (count === 0) return [];
    const ptr = this.exports.get_all_images_ptr();
    const view = new DataView(this.memory, ptr, count * ASSET_IMAGE_STRIDE);
    const out: AssetImage[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * ASSET_IMAGE_STRIDE;
      const namePtr = view.getUint32(base + 28, true);
      const nameLen = view.getUint32(base + 32, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        left: view.getFloat32(base + 8, true),
        top: view.getFloat32(base + 12, true),
        right: view.getFloat32(base + 16, true),
        bottom: view.getFloat32(base + 20, true),
        pageIndex: view.getUint32(base + 24, true),
        name: this.readString(namePtr, nameLen),
      });
    }
    return out;
  }

  /** All hyperlinks in the note, for the Links panel. */
  getAllLinks(): LinkAsset[] {
    const count = this.exports.get_all_links_count();
    if (count === 0) return [];
    const ptr = this.exports.get_all_links_ptr();
    const view = new DataView(this.memory, ptr, count * LINK_DRAW_STRIDE);
    const out: LinkAsset[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * LINK_DRAW_STRIDE;
      const destPtr = view.getUint32(base + 32, true);
      const destLen = view.getUint32(base + 36, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        left: view.getFloat32(base + 8, true),
        top: view.getFloat32(base + 12, true),
        right: view.getFloat32(base + 16, true),
        bottom: view.getFloat32(base + 20, true),
        pageIndex: view.getUint32(base + 24, true),
        linkType: view.getInt32(base + 28, true),
        destination: this.readString(destPtr, destLen),
      });
    }
    return out;
  }

  /** All audio recordings in the note, for the Media panel's Audio tab. */
  getAllAudio(): AudioAsset[] {
    const count = this.exports.get_all_audio_count();
    if (count === 0) return [];
    const ptr = this.exports.get_all_audio_ptr();
    const view = new DataView(this.memory, ptr, count * AUDIO_DRAW_STRIDE);
    const out: AudioAsset[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * AUDIO_DRAW_STRIDE;
      const namePtr = view.getUint32(base + 16, true);
      const nameLen = view.getUint32(base + 20, true);
      const entryPtr = view.getUint32(base + 24, true);
      const entryLen = view.getUint32(base + 28, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        durationMs: view.getFloat64(base + 8, true),
        name: this.readString(namePtr, nameLen),
        entryName: this.readString(entryPtr, entryLen),
      });
    }
    return out;
  }
}
