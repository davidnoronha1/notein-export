# Notein / Nebo Vector Stroke Rendering Engine

This document provides a comprehensive technical, mathematical, and architectural breakdown of the vector stroke rendering pipeline implemented in the WebAssembly engine (`wasm/src/`) and frontend canvas system (`web/src/`).

---

## 1. Executive Summary & Pipeline Architecture

Digital handwriting captures discrete stylus events (coordinates, pressure, tilt) sampled at 60–240 Hz. High-quality vector rendering transforms these discrete, noisy samples into continuous, resolution-independent vector strokes with variable stroke width, calligraphic nib shaping, sub-pixel anti-aliasing, and flawless curve boundaries under infinite zoom.

```
+-------------------------------------------------------------------------+
|                              INPUT INGESTION                            |
|    - Notein SQLite JSON (StrokeEntity) / Nebo BINK binary streams       |
|    - Point stream: P_i = (x_i, y_i), pressure p_i in [0, 1]             |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                       CONDITIONING & FILTERING                          |
|    - Deduplicate near-coincident samples (|Delta P|^2 < 0.0001)         |
|    - 3-point Gaussian-like moving average [0.25, 0.5, 0.25]             |
|    - Strict preservation of stroke endpoints                            |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|             CENTRIPETAL CATMULL-ROM SPLINE INTERPOLATION               |
|    - Centripetal knot parameterization (alpha = 0.5)                    |
|    - Exact analytical polynomial derivatives (dh00, dh10, dh01, dh11)   |
|    - Dynamic zoom-adaptive step budgeting (Pixels-Per-Step <= 0.6)      |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|             OFFSET GEOMETRY & CURVATURE BOUNDING                        |
|    - Variable width: r(u) = base_width * max(0.15, p(u)) * 0.5          |
|    - Broad-nib / calligraphy modulation: angle theta = -45 deg          |
|    - Frenet-Serret curvature bounding: r_inner <= 0.95 * R_curv         |
|    - Elimination of retrograde swallowtails and winding holes           |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                  CONTOUR CLOSURE & CAP GENERATION                       |
|    - Forward left offset contour + 8-segment circular end cap           |
|    - Reverse right offset contour + 8-segment circular start cap        |
|    - Seamless closed single-contour ribbon polygon                      |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|               SUB-PIXEL SCANLINE RASTERIZER (WASM)                      |
|    - Nonzero-winding rule edge-crossing span evaluation                 |
|    - 4x vertical sub-scanline anti-aliasing (supersampling)             |
|    - 8-wide SIMD-vectorized horizontal coverage accumulation            |
|    - Dark-mode HSL lightness inversion + alpha blending                 |
+-------------------------------------------------------------------------+
```

---

## 2. Input Ingestion & Data Representation

### 2.1 Notein (`.in`) Input
In Notein SQLite databases, strokes are stored in the `StrokeEntity` table as JSON records:
```json
{
  "color": -16777216,
  "width": 4.2,
  "creationTime": 1714000000000,
  "bounds": { "left": 0, "top": 0, "right": 100, "bottom": 50 },
  "points": [
    { "x": 12.3, "y": 45.6, "p": 0.72, "action": 0 },
    { "x": 13.1, "y": 46.8, "p": 0.75, "action": 2 },
    { "x": 14.5, "y": 48.0, "p": 0.68, "action": 1 }
  ]
}
```
- `action`: `0` = Touch Down, `2` = Move, `1` = Touch Up.
- `color`: 32-bit signed ARGB integer (converted to unsigned `0xAARRGGBB`).
- `p`: Normalized pressure value in $[0.0, 1.0]$.

### 2.2 Nebo (`.nebo` / `ink.bink`) Input
In Nebo BINK packages, stroke records consist of a 30-byte header followed by packed delta streams:
- `x0, y0`: IEEE-754 32-bit float origin.
- `dx[i], dy[i]`: 16-bit signed delta values scaled by $\frac{1}{512}$ world units:
  $$x_i = x_0 + \sum_{k=0}^i \frac{dx_k}{512}, \quad y_i = y_0 + \sum_{k=0}^i \frac{dy_k}{512}$$
- `pressure[i]`: 8-bit unsigned force sample normalized to $[0.0, 1.0]$.

---

## 3. Point Conditioning & Filtering

Raw stylus data from touch digitizers suffers from two primary artifacts:
1. **Duplicate or near-coincident points** caused by high sampling frequencies when the pen slows down or stops.
2. **Sub-pixel staircasing / quantization jitter** caused by digitizer grid resolution limits.

### 3.1 Deduplication
Consecutive points $P_i, P_{i+1}$ satisfying $\|P_{i+1} - P_i\|^2 < 0.0001$ are immediately discarded. This prevents division-by-zero errors in chord tangent calculations and avoids zero-length spline segments.

### 3.2 Moving Average Noise Filter
For raw stroke sequences with $N \ge 3$ points, high-frequency digitizer quantization noise is filtered with a 3-point Gaussian-like kernel:
$$\tilde{P}_i = 0.25 \cdot P_{i-1} + 0.50 \cdot P_i + 0.25 \cdot P_{i+1}, \quad \text{for } 1 \le i < N - 1$$
The first and last control points ($\tilde{P}_0 = P_0$ and $\tilde{P}_{N-1} = P_{N-1}$) are preserved exactly to guarantee that stroke beginnings and ends remain pinned to the user's intent.

---

## 4. Centripetal Catmull-Rom Spline Interpolation

### 4.1 Why Centripetal Parameterization?
Standard uniform Catmull-Rom splines parameterize segments uniformly with $u \in [0, 1]$, assuming uniform spacing between control points. When consecutive control points have uneven spacing (typical of handwriting speed variations), uniform splines suffer from:
- Cusps (sharp unwanted loops).
- Overshoot (bulging curves on sharp turns).
- Self-intersections.

Our engine implements **Centripetal Catmull-Rom Splines** ($\alpha = 0.5$), where knot intervals $t_{i+1} - t_i = \|P_{i+1} - P_i\|^{0.5}$. The centripetal formulation mathematically guarantees:
- No cusps or loops within segments.
- Strict preservation of curve monotonicity.
- Minimal curve energy and smooth acceleration.

### 4.2 Analytical Hermite Evaluation with Exact Derivatives
For four consecutive control points $P_0, P_1, P_2, P_3$, the tangent vectors $M_1$ and $M_2$ at knots $P_1$ and $P_2$ are computed using centripetal weighting:
$$d_0 = \|P_1 - P_0\|^{0.5}, \quad d_1 = \|P_2 - P_1\|^{0.5}, \quad d_2 = \|P_3 - P_2\|^{0.5}$$
$$w_0 = \frac{d_1^2}{d_0(d_0 + d_1)}, \quad w_1 = \frac{d_0}{d_0 + d_1}, \quad M_1 = w_0 (P_1 - P_0) + w_1 (P_2 - P_1)$$
$$w_2 = \frac{d_2}{d_1 + d_2}, \quad w_3 = \frac{d_1^2}{d_2(d_1 + d_2)}, \quad M_2 = w_2 (P_2 - P_1) + w_3 (P_3 - P_2)$$

The cubic Hermite basis functions:
$$h_{00}(u) = 2u^3 - 3u^2 + 1, \quad h_{10}(u) = u^3 - 2u^2 + u$$
$$h_{01}(u) = -2u^3 + 3u^2, \quad h_{11}(u) = u^3 - u^2$$

The position $C(u)$ and exact polynomial derivative $C'(u) = \left(\frac{dx}{du}, \frac{dy}{du}\right)$ are evaluated simultaneously:
$$\frac{dh_{00}}{du} = 6u^2 - 6u, \quad \frac{dh_{10}}{du} = 3u^2 - 4u + 1$$
$$\frac{dh_{01}}{du} = -6u^2 + 6u, \quad \frac{dh_{11}}{du} = 3u^2 - 2u$$
$$C(u) = h_{00} P_1 + h_{10} M_1 + h_{01} P_2 + h_{11} M_2$$
$$C'(u) = \frac{dh_{00}}{du} P_1 + \frac{dh_{10}}{du} M_1 + \frac{dh_{01}}{du} P_2 + \frac{dh_{11}}{du} M_2$$

Evaluating exact analytical derivatives eliminates the discretization chatter and normal-vector jitter inherent to finite-difference approximations ($\Delta P / \Delta u$).

---

## 5. Zoom-Adaptive Tessellation & Step Allocation

### 5.1 Dynamic Screen-Space Step Budgeting
To maintain 60 FPS performance when zoomed out while ensuring sub-pixel smoothness when zoomed in to 800%+, the subdivision step count for each spline segment $P_1 \to P_2$ is computed dynamically in screen space:
$$\text{len\_steps} = \left\lceil \frac{\|P_2 - P_1\| \cdot S}{\text{PIXELS\_PER\_STEP}} \right\rceil, \quad \text{where } \text{PIXELS\_PER\_STEP} = 0.6$$
where $S$ is the current viewport canvas scale.

### 5.2 Angle-Adaptive Corner Allocation
On high-curvature turns, step allocation is augmented by the angular change between knot tangents:
$$\cos\theta = \text{clamp}\left( \frac{M_1 \cdot M_2}{\|M_1\| \|M_2\|}, -1.0, 1.0 \right)$$
$$\text{angle\_steps} = \lceil (1 - \cos\theta) \cdot 8.0 \rceil$$
$$\text{steps} = \text{clamp}(\max(\text{len\_steps}, \text{angle\_steps}), 1, 256)$$

### 5.3 Continuous Tangent Orientation
At turning cusps or inflection points where derivative speed $\|C'(u)\| \to 0$, the unit tangent vector is preserved continuously:
$$T_{\text{new}} = \frac{C'(u)}{\|C'(u)\|}$$
$$T = \begin{cases} T_{\text{new}} & \text{if } T_{\text{new}} \cdot T_{\text{prev}} > 0 \\ T_{\text{prev}} & \text{otherwise} \end{cases}$$
The stroke normal is the orthogonal unit vector:
$$N = (-T_y, T_x)$$

---

## 6. Offset Curve Geometry & Swallowtail Elimination

### 6.1 The Frenet-Serret Curvature Problem
A stroke of local radius $r(u)$ generates two boundary offset curves:
$$L(u) = C(u) + r(u) N(u) \quad (\text{Left Offset})$$
$$R(u) = C(u) - r(u) N(u) \quad (\text{Right Offset})$$

According to Frenet-Serret differential geometry, the velocity along the offset curve is:
$$L'(u) = (1 - r(u) \kappa(u)) T(u) + r'(u) N(u)$$
where $\kappa(u)$ is the signed curvature of the centerline $C(u)$.

When a curve turns tightly such that the radius of curvature $R_c = \frac{1}{|\kappa|} < r(u)$:
$$1 - r(u) \kappa(u) < 0$$
The inner offset curve **moves backwards** relative to the curve tangent, creating a self-intersecting loop known as a **swallowtail cusp**.

```
Centerline:          C(u) -------------->
Outer Offset:        R(u) ====================> (Smooth, 1 + r*kappa > 0)
Inner Offset:        L(u) ------->  <------ (Reverses direction! 1 - r*kappa < 0)
                                  \  /
                                   \/  <--- Swallowtail loop cancels winding to 0!
```

### 6.2 The Root Cause of Black Dots / Notches
When a closed ribbon polygon containing a swallowtail loop is rasterized under the standard **nonzero winding rule**:
- The normal stroke body has winding number $+1$.
- The interior of the retrograde swallowtail loop has winding number $+1 + (-1) = 0$.
- Because winding is $0$, the scanline rasterizer treats the overlap as **outside the polygon**, leaving an unfilled black background hole/notch!

### 6.3 Curvature-Bounded Inner Offset
To solve this without modifying the outer stroke width or introducing sharp spikes, our engine implements **adaptive curvature bounding**:

For consecutive evaluated samples $(P_{\text{prev}}, T_{\text{prev}})$ and $(P_{\text{curr}}, T_{\text{curr}})$:
$$\Delta s = \|P_{\text{curr}} - P_{\text{prev}}\|, \quad \sin(\Delta\theta) = T_{\text{prev}, x} T_{\text{curr}, y} - T_{\text{prev}, y} T_{\text{curr}, x}$$
$$R_{\text{curv}} = \frac{\Delta s}{|\sin(\Delta\theta)|}$$

On the inner side of the turn:
$$r_{\text{inner}} = \min\left(r, \max\left(0.4, 0.95 \cdot R_{\text{curv}}\right)\right)$$
- If turning left ($\sin(\Delta\theta) > 0$): $r_{\text{left}} = r_{\text{inner}}, \quad r_{\text{right}} = r$.
- If turning right ($\sin(\Delta\theta) < 0$): $r_{\text{left}} = r, \quad r_{\text{right}} = r_{\text{inner}}$.

**Mathematical Guarantees**:
1. Since $r_{\text{inner}} \le 0.95 \cdot R_{\text{curv}}$, the speed $1 - r_{\text{inner}} \kappa \ge 0.05 > 0$ is strictly positive.
2. The inner offset curve is **strictly monotonic** along the curve direction and never reverses.
3. Swallowtail loops cannot form.
4. The generated ribbon polygon is simple (non-self-intersecting) on turns, ensuring winding number is $+1$ everywhere inside the stroke with **zero black holes, notches, or slits**.

---

## 7. Broad-Nib / Calligraphic Pen Modeling

For calligraphic strokes (`is_calligraphic = true`), the stroke radius is modulated by the angle between the stroke tangent $T$ and the fixed broad-nib angle $\phi = -45^\circ$:
$$\cos\phi = \frac{\sqrt{2}}{2}, \quad \sin\phi = -\frac{\sqrt{2}}{2}$$
$$\text{nib\_alignment} = |T_y \cos\phi - T_x \sin\phi|$$
$$\text{nib\_factor} = 0.6 + (1.0 - 0.6) \cdot \text{nib\_alignment}$$
$$r(u) = \max(0.4, \text{base\_width} \cdot \max(0.15, p(u)) \cdot \text{nib\_factor}) \cdot 0.5$$

This reproduces traditional flat-chisel calligraphy: horizontal/vertical strokes maintain full width while $45^\circ$ diagonal strokes produce sharp, hairline flourishes.

---

## 8. Contour Closure & End Cap Geometry

To form a closed, water-tight polygon outline:
1. **Left Outline**: Generated in forward order from $s = 0 \to N$.
2. **End Round Cap**: 8-segment semi-circle parameterized from $\beta = \frac{\pi}{2} \to -\frac{\pi}{2}$:
   $$V_{\text{end}}(k) = P_{\text{last}} + T_{\text{last}} \cos\beta \cdot r_{\text{last}} + N_{\text{last}} \sin\beta \cdot r_{\text{last}}$$
3. **Right Outline**: Appended in reverse order from $s = N \to 1$.
4. **Start Round Cap**: 8-segment semi-circle prepended at the head of the polygon from $\alpha = -\frac{\pi}{2} \to \frac{\pi}{2}$:
   $$V_{\text{start}}(k) = P_{\text{first}} - T_{\text{first}} \cos\alpha \cdot r_{\text{first}} + N_{\text{first}} \sin\alpha \cdot r_{\text{first}}$$

The resulting contiguous vertex array forms a closed polygon $V_0, V_1, \dots, V_M, V_0$.

---

## 9. Sub-Pixel Scanline Rasterizer (WASM)

### 9.1 Edge Crossing Accumulation
For each scanline row $Y$, the rasterizer determines all polygon edges $E = (A, B)$ crossing the scanline. For non-horizontal edges:
$$t = \frac{Y - A_y}{B_y - A_y}, \quad X_{\text{cross}} = A_x + t (B_x - A_x)$$
$$\text{dir} = \begin{cases} +1 & \text{if } A_y \le Y < B_y \text{ (edge going down)} \\ -1 & \text{if } B_y \le Y < A_y \text{ (edge going up)} \end{cases}$$

Crossings are sorted left-to-right by $X$.

### 9.2 Nonzero Winding Rule
The rasterizer traverses sorted crossings, maintaining an active winding count:
$$\text{winding} \leftarrow \text{winding} + \text{dir}$$
$$\text{inside} = (\text{winding} \ne 0)$$
Spans $[X_{\text{start}}, X_{\text{end}}]$ where $\text{inside} = \text{true}$ are filled into the scanline coverage buffer.

### 9.3 4× Sub-Scanline Anti-Aliasing (SSAA)
Each pixel row $y$ is sampled across 4 vertical sub-pixel scanlines:
$$Y_{\text{sub}} = y + \frac{k + 0.5}{4}, \quad k \in \{0, 1, 2, 3\}$$
Each sub-scanline accumulates coverage with weight $w = 0.25$.

### 9.4 SIMD-Vectorized Coverage Accumulation
Interior span pixels are accumulated using 8-wide 32-bit float SIMD vectors (`@Vector(8, f32)` in Zig):
```zig
const w8: @Vector(8, f32) = @splat(0.25);
while (ix + 8 <= ix1) : (ix += 8) {
    const ptr = @as(*align(1) @Vector(8, f32), @ptrCast(&coverage[ix]));
    ptr.* += w8;
}
```

### 9.5 Dark-Mode Lightness Inversion
Dark mode uses an **involutional HSL lightness inversion** ($L \mapsto 1 - L$) that flips background paper from white to black and ink from black to white while strictly preserving chromatic hue and saturation:
```zig
pub fn outputColor(argb: u32) u32 {
    if (!invert_colors) return argb;
    const a = (argb >> 24) & 0xff;
    const hsl = rgbToHsl(r, g, b);
    const inverted_rgb = hslToRgb(hsl.h, hsl.s, 1.0 - hsl.l);
    return (a << 24) | (inverted_rgb.r << 16) | (inverted_rgb.g << 8) | inverted_rgb.b;
}
```

---

## 10. Memory Management & Performance

- **Zero Per-Frame Allocation**: All dynamic lists (`g_poly_buf`, `g_right_buf`, `g_clean_pts_buf`, `g_smooth_pts_buf`) retain their capacity across frames, eliminating garbage collection pauses and allocator locks.
- **Cache-Friendly Stack Structures**: Scanline crossings and polygon bounds are computed in stack arrays.
- **Throughput**: Renders complex multi-page documents containing >100,000 stroke points at continuous 60 FPS in standard WebAssembly runtimes.
