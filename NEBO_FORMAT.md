# Nebo / MyScript BINK + BDOM format notes

Reverse-engineering notes for Nebo 6.4.x / Interactive Ink packages, based on `memy.nebo` and the controlled multi-page `e.nebo` corpus. This document deliberately separates **observed facts** from interpretations.

## Package layout

A `.nebo` file is a ZIP container. The packages analyzed here contain:

```text
meta.json
rel.json
index.bdom
pages/<8-char-page-id>/
    ink.bink
    page.bdom
    meta.json
    style.css
```

A public Nebo reverse-engineering utility independently documents the same package structure and notes that `ink.bink` is the stroke-data payload and `page.bdom` is the associated binary document model. It also states that Nebo may contain `objects/<uuid>.png` for imported images; neither of the two supplied test packages contains an `objects/` directory. citeturn279133view0

## BINK header

The file begins with ASCII `BINK`, followed by a version/header area. The supplied pages consistently begin:

```text
42 49 4e 4b 00 05 00 00 ...
 B  I  N  K
```

Exact meaning of every header word has not been established, but the same header occurs across the corpus.

## Raw stroke packet

The raw ink area is made of fixed-header stroke records. For the current corpus, a raw stroke record is: 

```text
offset +0x00 : 4 bytes  marker = 00 00 00 80
offset +0x04 : 8 bytes  timestamp_us, little-endian uint64
offset +0x0c : 4 bytes  x0, little-endian IEEE-754 float32
offset +0x10 : 4 bytes  y0, little-endian IEEE-754 float32
offset +0x14 : 2 bytes  tilt_raw, little-endian uint16
offset +0x16 : 2 bytes  orientation_raw, little-endian uint16
offset +0x18 : 2 bytes  reserved0; observed 0 in all supplied raw strokes
offset +0x1a : 2 bytes  point_count, little-endian uint16
offset +0x1c : 2 bytes  reserved1; observed 0 in all supplied raw strokes
then      : N × int16 dx
then      : N × int16 dy
then      : N × uint8 pressure/force sample
```

Therefore the raw stroke payload size is `5*N` bytes and the total stroke-record size is `30 + 5*N` bytes.

### Coordinate reconstruction

The observed coordinate reconstruction is:

```text
x[0] = x0
y[0] = y0

x[i] = x0 + sum(dx[0:i]) / 512
y[i] = y0 + sum(dy[0:i]) / 512
```

For this corpus the resulting points are in the same page coordinate system used by the rest of the document. The `/512` scale is directly validated by the ability to reconstruct recognizable handwriting geometry from raw BINK alone.

### Timestamp

`timestamp_us` is Unix epoch time in microseconds. The controlled `e.nebo` strokes have timestamps matching the creation time of the file on 2026-08-26.

Example:

```text
1787743967794653 µs
→ 2026-08-26 11:32:47.794653 UTC
```

### Tilt and orientation

The field at `+0x16` is constant at `3145` in all currently inspected strokes. Interpreting it as radians × 10000 gives `0.3145 rad ≈ 18.02°`. The field at `+0x14` varies between roughly `4000..7600`, corresponding to `0.40..0.76 rad` when divided by 10000. This is highly consistent with MyScript's public Interactive Ink concepts of pen orientation/azimuth and tilt, but the exact on-disk field names and scaling should still be treated as **high-confidence inference**, not absolute proof, until an SDK/JIIX round-trip or a controlled physical orientation experiment validates them.

### Pressure / force

The trailing `uint8[N]` stream varies independently within strokes and is strongly consistent with per-point force/pressure. MyScript's public Interactive Ink model represents force as a normalized quantity, but the exact BINK byte-to-float conversion (`byte/255`, or another quantization) is not proven from this corpus alone.

## Raw stroke completeness

For `e.nebo`, each test page has exactly one raw stroke packet. Its point counts are:

| page | points | stored color |
|---|---:|---|
| qflquhqb | 186 | `#000000FF` |
| mmfohgni | 181 | `#87202BFF` |
| ymxblcgf | 179 | `#A22E00FF` |
| haensojp | 176 | `#197F2AFF` |
| fneqfnsm | 186 | `#81208EFF` |

The raw record ends exactly before the semantic BINK/object stream begins (apart from a small zero/padding separator).

For the original `memy.nebo`, the raw region contains hundreds of stroke packets and the same packet grammar generalizes across the file.

## Semantic/object stream in BINK

After raw strokes, BINK contains a human-readable object stream. Objects have a header of the form:

```text
u32 class_id
u32 object_id
u32 flags
u32 name_length
name[name_length] UTF-8
... object relationship/value data ...
```

Examples from `e.nebo` include:

```text
active-pen-input
pen-050
.STYLE
LAYOUT_STROKES
INPUT
TEXT_STROKES
TEXT_LINE
TEXT_BLOCK
DIAGRAM
CHAR
WORD
TEXT
```

Object IDs are local graph/object IDs and are distinct from the packed references used in the relationship field.

## Packed reference field: resolved structure

The recurring 32-bit value that previously appeared as bytes such as:

```text
05 ff b9 00
```

is little-endian integer `0x00B9FF05`. Its structure is now clear:

```text
bits 0..15  : namespace/tag
bits 16..31 : parent/item identifier
```

Thus:

```text
05 ff b9 00
= 0x00B9FF05
= parent_id 185, namespace 0xFF05
```

For `memy.nebo`, references such as `0x007EFF05`, `0x0026FF05`, and `0x00300001` occur. The low 16 bits therefore really are a typed namespace/tag, not part of the numeric ID.

Observed namespaces in the supplied corpus:

```text
0xFF05  primary ink/content-item reference namespace
0x0001  secondary character/item namespace
```

The exact public MyScript symbolic names for these internal tags are not known.

## Relationship tuple

Many named BINK objects immediately follow their name with a tuple shaped like:

```text
u32 relation_count_or_mode = 1
u32 relation_kind          = 3
u32 lhs_or_begin           = A
u32 packed_reference       = REF
u32 rhs_or_end             = B
... value payload ...
```

where `REF = (parent_id << 16) | namespace`. Examples:

```text
TEXT_LINE  -> A=4,  REF=(126,0xFF05), B=12
CHAR       -> A=4,  REF=(38,0xFF05),  B=5
CHAR       -> A=7,  REF=(48,0x0001), B=7
```

The strongest interpretation is that `A..B` is a local range/span and `REF` identifies the namespace/container in which those items live. This explains why the same parent reference can be reused by a `TEXT_LINE`, `TEXT_BLOCK`, `DIAGRAM`, and `INPUT` object while each object has different local range endpoints. It also explains why the high 16-bit identifier does not need to exist as a BINK object ID in every case.

### What is proven vs inferred here

**Proven from byte structure and differential analysis:**

- The packed reference is two 16-bit quantities.
- The low 16 bits take discrete namespace values (`0xFF05`, `0x0001` in this corpus).
- The high 16 bits are reused as a container/item ID across related semantic objects.
- The surrounding tuple has two range-like integers (`A`, `B`).
- The same reference is reused by related semantic nodes.

**High-confidence interpretation:**

- `A..B` are start/end item ordinals inside the referenced namespace/container.
- `0xFF05` is the primary ink/stroke-item namespace.
- `0x0001` is a character/item namespace used by some `CHAR` records.

The exact symbolic enum names for `relation_kind=3`, field code `7`, and the namespace values are not yet identified.

## Style records / actual stored colors

`.STYLE` objects store literal style strings such as:

```text
"color:#000000ff;"
"color:#87202bff;"
"color:#a22e00ff;"
"color:#197f2aff;"
"color:#81208eff;"
```

The controlled `e.nebo` pages prove these colors are document data, not a fixed global palette. The original `memy.nebo` uses a different four-color subset.

Style strings can also contain other pen/font properties. The analyzed corpus includes `.STYLE` values containing `line-height`, `font-size`, and pen properties.

## BDOM range strings

`page.bdom` contains human-readable serialized range expressions such as:

```text
[7:0,7:185$]
[4:0,5:38$]
[8:0,12:126$]
[76:0,76:67$]
```

The exact binary serializer for BDOM is not yet fully decoded, but the range syntax confirms that MyScript stores ranges as **typed coordinates / item addresses**, not as raw global stroke ordinals. This is consistent with the packed `(namespace, id)` references found in BINK.

## BDOM dictionary / object model

`page.bdom` begins with `BDOM` and a string table containing names such as:

```text
strokes
textStrokes
nonTextStrokes
textLine
textBlock
diagram
input
char
word
text
style
pen
range
textCandidate
wordCandidate
charCandidate
shapeResult
mathResult
image
drawingField
shapeField
textField
mathField
...
```

This confirms that the BDOM is a serialized MyScript page/object graph rather than a simple XML-like metadata blob.

## Images / non-ink objects

A public reverse-engineering utility for Nebo documents states that imported images are stored under `objects/<uuid>.png`. Neither `memy.nebo` nor the controlled `e.nebo` contains an `objects/` directory, so no embedded raster image format has been observed directly in these two test files. citeturn279133view0

## Raw stroke status

At this point the **raw stroke payload** is substantially solved:

```text
record marker          ✅
timestamp              ✅
x0 / y0                ✅
point count            ✅
X/Y delta streams      ✅
coordinate scale 1/512 ✅
pressure byte stream   ✅ (quantization still inferred)
tilt field             🟡 high-confidence
orientation field      🟡 high-confidence
reserved fields        ✅ observed as zero in corpus
semantic span ref      ✅ packed two-u16 structure
semantic namespaces    🟡 symbolic names unresolved
```

## Next targets

1. Resolve the numeric class IDs (`0`, `11`, `12`, `100`, `103`, `105`, etc.) to object-type enums.
2. Decode `relation_kind=3` and field/variant code `7`.
3. Decode BDOM's typed range serializer enough to mechanically map BINK spans to BDOM objects.
4. Determine the exact pressure normalization and the precise meaning/scaling of tilt/orientation.
5. Use the controlled five-color corpus plus `memy.nebo` to prove style inheritance/overrides without image-assisted heuristics.
6. Reconstruct text/diagram/object hierarchy entirely from the package.

## External validation

An independent open-source utility confirms that `.nebo` is a ZIP package, that `ink.bink` contains the stroke data, that `page.bdom` is the corresponding binary document model, and that the MyScript engine can export a `.nebo` page to JIIX for human-readable ground truth. citeturn279133view0turn507310search0

