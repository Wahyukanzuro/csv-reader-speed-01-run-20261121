// csv-reader-speed-01 v2: WASM SIMD128 JSON-to-JSON CSV transducer.
//
// Architecture (encoded-text approach):
// - main.ts reads /input/cases.json as a raw Buffer, copies it to WASM linear
//   memory at 0, calls run_json(0, len). The WASM parses the JSON structure,
//   runs the CSV engine DIRECTLY on the JSON-encoded text bytes (no separate
//   decode pass), and writes answers.json bytes to OUT_BASE. JS copies the
//   output buffer out with writeFileSync. No JSON.parse / JSON.stringify.
// - Why encoded works: in the JSON-encoded text, every CSV special character
//   appears as an escape sequence: `"` -> `\"`, LF -> `\n`, CR -> `\r`,
//   TAB -> `\t`, backslash -> `\\`. A bare `"` / LF / CR byte NEVER appears
//   inside a JSON string. And the JSON encoding of a field value is exactly
//   the JSON encoding the output needs, so clean fields are copied verbatim
//   (no decode, no re-escape). Only the CSV transformations ("" -> ",
//   CR/CRLF inside quotes -> LF, stray CR dropped) need rewriting.
// - CSV semantics mirror csv-reader 1.0.0 exactly (vendor/csv-reader/index.js
//   and the proven v1 solve.js). The engine works on the encoded bytes, where
//   a "CSV character" is either one byte (`,` and any byte except `\` and `"`)
//   or an escape sequence (`\` + 1 char, or `\uXXXX` = 6 bytes, opaque).
// - `\uXXXX` escapes: JSON.stringify never emits them for this data (verified:
//   practice cases.json has 0 `\u` and 0 `\\`). They are treated as opaque
//   6-byte sequences and copied verbatim (correct JSON for that code unit).
//   A `\u` decoding to a CSV special (", ,, LF, CR) cannot occur from
//   JSON.stringify output; it is not handled (documented limitation).
// - Determinism: single-threaded, no hashing, no randomness; output is a pure
//   function of the input bytes.

const std = @import("std");

// ---------------- memory layout (initial 1024 pages = 64 MiB) ----------------
// input buffer: 0 .. (written by JS)
// output buffer: OUT_BASE .. (answers.json, ~12 MiB)
// scratch: SCRATCH_BASE .. (errors buffer, field buffer, record spans)
const OUT_BASE: u32 = 0x2000000; // 32 MiB
const SCRATCH_BASE: u32 = 0x3000000; // 48 MiB
const ERR_BASE: u32 = SCRATCH_BASE; // errors JSON fragments, cap 1 MiB
const ERR_CAP: u32 = 0x100000;
const FB_BASE: u32 = SCRATCH_BASE + 0x100000; // materialized field values, 1 MiB
const FB_CAP: u32 = 0x100000;
const SPAN_BASE: u32 = SCRATCH_BASE + 0x200000; // record field spans (ptr,len) pairs
const TEXT_BUF: u32 = SCRATCH_BASE + 0x201000; // scratch for materialized non-string text
const SPAN_CAP_FIELDS: u32 = 128;

// ---------------- globals ----------------
var g_in_end: u32 = 0; // end of input (cases.json) in memory
var g_out: u32 = 0; // current output write position
var g_err_len: u32 = 0; // bytes used in errors buffer
var g_fast_recs: u64 = 0;
var g_slow_recs: u64 = 0;
var g_fast_fields: u64 = 0;
var g_slow_fields: u64 = 0;

export fn stats() u64 { return (g_fast_recs << 48) | (g_slow_recs << 32) | (g_fast_fields << 16) | g_slow_fields; }
var g_fb: u32 = 0; // field buffer write position (reset per record)

// CSV per-case state
var cs_start: u32 = 0; // text span start (encoded)
var cs_end: u32 = 0; // text span end (encoded, exclusive)
var cs_pos: u32 = 0; // current scan position
var cs_line: u32 = 1; // 1-based line of cs_pos
var cs_width: i32 = -1; // first record's field count
var cs_header: bool = false;
var cs_rows: u32 = 0; // rows emitted so far (for row index)
var cs_cols_done: bool = false; // first record (columns) already handled
var cs_rec_line: u32 = 1; // current record's start line
var cs_rec_row: i32 = -1; // current record's row index (-1 = null/header)
var g_nspans: u32 = 0; // fields in current record
var g_last_quoted: bool = false; // last field of current record opened with a quote

// Field end kinds
const F_COMMA: u8 = 0;
const F_BREAK: u8 = 1;
const F_END: u8 = 2;
const F_JUNK: u8 = 3;

// ---------------- low-level memory access ----------------
inline fn b8(p: u32) u8 {
    return @as(*const u8, @ptrFromInt(p)).*;
}
inline fn b8set(p: u32, v: u8) void {
    @as(*u8, @ptrFromInt(p)).* = v;
}
inline fn load16(p: u32) @Vector(16, u8) {
    return @as(*const [16]u8, @ptrFromInt(p)).*;
}
fn store16(p: u32, v: @Vector(16, u8)) void {
    @as(*[16]u8, @ptrFromInt(p)).* = v;
}
inline fn loadU16(p: u32) u16 {
    return @as(*const u16, @ptrFromInt(p)).*;
}
inline fn loadU32(p: u32) u32 {
    return @as(*const u32, @ptrFromInt(p)).*;
}
inline fn storeU32(p: u32, v: u32) void {
    @as(*u32, @ptrFromInt(p)).* = v;
}

// memcpy within linear memory (handles overlap like memmove via std)
fn memCopy(dst: u32, src: u32, len: u32) void {
    if (len == 0) return;
    const d: [*]u8 = @ptrFromInt(dst);
    const s: [*]const u8 = @ptrFromInt(src);
    @memcpy(d[0..len], s[0..len]);
}
fn memEqual(a: u32, b: u32, len: u32) bool {
    if (len == 0) return true;
    const x: [*]const u8 = @ptrFromInt(a);
    const y: [*]const u8 = @ptrFromInt(b);
    return std.mem.eql(u8, x[0..len], y[0..len]);
}

// ---------------- output helpers ----------------
inline fn outByte(v: u8) void {
    b8set(g_out, v);
    g_out += 1;
}
fn outSlice(p: u32, len: u32) void {
    memCopy(g_out, p, len);
    g_out += len;
}
fn outLit(s: []const u8) void {
    for (s) |c| outByte(c);
}
fn outU32(n: u32) void {
    var buf: [10]u8 = undefined;
    var v = n;
    var i: usize = 10;
    if (v == 0) {
        outByte('0');
        return;
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    for (buf[i..10]) |c| outByte(c);
}
fn outI32(n: i32) void {
    if (n < 0) {
        outByte('-');
        outU32(@intCast(-n));
    } else {
        outU32(@intCast(n));
    }
}

// ---------------- SIMD scanning ----------------
// Find the next position >= pos where the byte is ',' or '\\', up to end.
// Returns end if none. (Used by the unquoted-field scan: ',' ends the field,
// '\\' starts an escape that must be classified.)
fn findCommaOrBs(pos: u32, end: u32) u32 {
    var p = pos;
    const comma_splat: @Vector(16, u8) = @splat(',');
    const bs_splat: @Vector(16, u8) = @splat('\\');
    while (p + 16 <= end) : (p += 16) {
        const chunk = load16(p);
        const m: u16 = @bitCast((chunk == comma_splat) | (chunk == bs_splat));
        if (m != 0) return p + @ctz(m);
    }
    while (p < end) : (p += 1) {
        const c = b8(p);
        if (c == ',' or c == '\\') return p;
    }
    return end;
}

// Find the next position >= pos where the byte is '\\', up to end.
// Returns end if none. (Used by the quoted-field scan and the JSON string scan.)
fn findBs(pos: u32, end: u32) u32 {
    var p = pos;
    const bs_splat: @Vector(16, u8) = @splat('\\');
    while (p + 16 <= end) : (p += 16) {
        const chunk = load16(p);
        const m: u16 = @bitCast(chunk == bs_splat);
        if (m != 0) return p + @ctz(m);
    }
    while (p < end) : (p += 1) {
        if (b8(p) == '\\') return p;
    }
    return end;
}

// Find the next position >= pos where the byte is '"' or '\\', up to end.
// Returns end if none. (Used to find a JSON string's closing quote: a '"'
// preceded by an odd run of backslashes is escaped.)
fn findQuoteOrBs(pos: u32, end: u32) u32 {
    var p = pos;
    const q_splat: @Vector(16, u8) = @splat('"');
    const bs_splat: @Vector(16, u8) = @splat('\\');
    while (p + 16 <= end) : (p += 16) {
        const chunk = load16(p);
        const m: u16 = @bitCast((chunk == q_splat) | (chunk == bs_splat));
        if (m != 0) return p + @ctz(m);
    }
    while (p < end) : (p += 1) {
        const c = b8(p);
        if (c == '"' or c == '\\') return p;
    }
    return end;
}

// Count line breaks in the encoded span [start, end): each `\n` escape and
// each `\r` escape counts 1, except a `\r` escape immediately followed by a
// `\n` escape (CRLF) counts as 1 for the pair. `prev_cr` carries whether the
// byte before `start` was a `\r` escape's end... simpler: this counts breaks
// for a span that starts and ends on escape boundaries (quoted content).
// It scans for backslashes and classifies each escape.
fn countLineBreaks(start: u32, end: u32) u32 {
    var n: u32 = 0;
    var p = start;
    while (p < end) {
        const m = findBs(p, end);
        if (m >= end) break;
        // escape at m: next byte decides
        if (m + 1 >= end) break; // trailing lone backslash (cannot happen in valid JSON)
        const c = b8(m + 1);
        if (c == 'n') {
            n += 1;
            p = m + 2;
        } else if (c == 'r') {
            // CRLF pair counts once: if the next escape is \n, skip it too
            if (m + 4 <= end and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                n += 1;
                p = m + 4;
            } else {
                n += 1;
                p = m + 2;
            }
        } else if (c == 'u') {
            p = m + 6;
        } else {
            p = m + 2;
        }
    }
    return n;
}

// Does the encoded span [start, end) contain a `\"` escape (a quote char) or
// a `\r` escape? Used to decide whether a quoted field's content can be
// copied verbatim (no "" doubling, no CR to normalize).
fn spanHasQuoteOrCr(start: u32, end: u32) bool {
    var p = start;
    while (p < end) {
        const m = findBs(p, end);
        if (m >= end) return false;
        if (m + 1 >= end) return false;
        const c = b8(m + 1);
        if (c == '"' or c == 'r') return true;
        if (c == 'u') {
            p = m + 6;
        } else {
            p = m + 2;
        }
    }
    return false;
}

// ---------------- JSON parsing (structure only; text stays encoded) ----------------

fn skipWs(p: u32) u32 {
    var q = p;
    while (q < g_in_end) {
        const c = b8(q);
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            q += 1;
        } else break;
    }
    return q;
}

fn keyIs(start: u32, len: u32, want: []const u8) bool {
    if (len != want.len) return false;
    for (want, 0..) |c, i| {
        if (b8(start + @as(u32, @intCast(i))) != c) return false;
    }
    return true;
}

// Parse a JSON string starting at p (which points at the opening '"').
// Returns the raw (still escaped) content span and the position after the
// closing quote. Escapes are skipped as units, so a '"' returned is always
// the closing quote.
const StrSpan = struct { start: u32, end: u32, next: u32 };
fn parseJsonString(p: u32) StrSpan {
    var q = p + 1;
    const start = q;
    while (true) {
        const m = findQuoteOrBs(q, g_in_end);
        if (m >= g_in_end) {
            return .{ .start = start, .end = g_in_end, .next = g_in_end };
        }
        const c = b8(m);
        if (c == '\\') {
            if (m + 1 < g_in_end and b8(m + 1) == 'u') {
                q = m + 6;
            } else {
                q = m + 2;
            }
            continue;
        }
        // c == '"': the closing quote (any escaped quote's backslash was
        // found first by findQuoteOrBs and skipped above).
        return .{ .start = start, .end = m, .next = m + 1 };
    }
}

// Skip one JSON value starting at p (after skipWs). Returns the position
// just past the value.
fn skipJsonValue(p: u32) u32 {
    var q = skipWs(p);
    if (q >= g_in_end) return q;
    const c = b8(q);
    if (c == '"') {
        return (parseJsonString(q)).next;
    }
    if (c == '{') {
        q += 1;
        q = skipWs(q);
        if (q < g_in_end and b8(q) == '}') return q + 1;
        while (true) {
            q = skipWs(q);
            const k = parseJsonString(q);
            q = skipWs(k.next);
            q += 1; // ':'
            q = skipJsonValue(q);
            q = skipWs(q);
            if (q < g_in_end and b8(q) == ',') {
                q += 1;
                continue;
            }
            return q + 1; // '}'
        }
    }
    if (c == '[') {
        q += 1;
        q = skipWs(q);
        if (q < g_in_end and b8(q) == ']') return q + 1;
        while (true) {
            q = skipJsonValue(q);
            q = skipWs(q);
            if (q < g_in_end and b8(q) == ',') {
                q += 1;
                continue;
            }
            return q + 1; // ']'
        }
    }
    // literal (true/false/null/number): scan to a structural delimiter.
    while (q < g_in_end) {
        const d = b8(q);
        if (d == ',' or d == '}' or d == ']' or d == ' ' or d == '\t' or d == '\n' or d == '\r') break;
        q += 1;
    }
    return q;
}


// Materialize a non-string JSON value (null/true/false/number) starting at p
// into TEXT_BUF as its String() form (the raw token, which equals String(v)
// for null/true/false and for integer numbers). Returns the position just past
// the token. The text span becomes [TEXT_BUF, TEXT_BUF+len).
fn materializeTextValue(p: u32) u32 {
    var q = p;
    const c = b8(q);
    if (c == 'n') { // null
        memCopy(TEXT_BUF, q, 4);
        return q + 4;
    }
    if (c == 't') { // true
        memCopy(TEXT_BUF, q, 4);
        return q + 4;
    }
    if (c == 'f') { // false
        memCopy(TEXT_BUF, q, 5);
        return q + 5;
    }
    // number (or other scalar): copy the token [0-9eE.+-]*
    const start = q;
    while (q < g_in_end) {
        const ch = b8(q);
        if ((ch >= '0' and ch <= '9') or ch == '-' or ch == '+' or ch == '.' or ch == 'e' or ch == 'E') {
            q += 1;
        } else break;
    }
    const len = q - start;
    if (len > 0) memCopy(TEXT_BUF, start, len);
    return q;
}

// Parse one case object. p points at '{'. Extracts the text span (encoded)
// and header flag. Returns the position just past '}'.
fn parseCase(p: u32, out_text: *u32, out_text_end: *u32, out_header: *bool) u32 {
    var q = p + 1;
    var text_start: u32 = 0;
    var text_end: u32 = 0;
    var text_found: bool = false;
    var header: bool = false;
    q = skipWs(q);
    if (q < g_in_end and b8(q) == '}') return q + 1;
    while (true) {
        q = skipWs(q);
        const k = parseJsonString(q);
        q = skipWs(k.next);
        q += 1; // ':'
        q = skipWs(q);
        const klen = k.end - k.start;
        if (keyIs(k.start, klen, "input")) {
            q = skipWs(q);
            q += 1; // '{'
            q = skipWs(q);
            if (q < g_in_end and b8(q) == '}') {
                q += 1;
            } else {
                while (true) {
                    q = skipWs(q);
                    const ik = parseJsonString(q);
                    q = skipWs(ik.next);
                    q += 1; // ':'
                    q = skipWs(q);
                    const ilen = ik.end - ik.start;
                    if (keyIs(ik.start, ilen, "text")) {
                        if (q < g_in_end and b8(q) == '"') {
                            const s = parseJsonString(q);
                            text_start = s.start;
                            text_end = s.end;
                            q = s.next;
                        } else {
                            // non-string text: String(value) -> materialize it
                            const tok_end = materializeTextValue(q);
                            text_start = TEXT_BUF;
                            text_end = TEXT_BUF + (tok_end - q);
                            q = tok_end;
                        }
                        text_found = true;
                    } else if (keyIs(ik.start, ilen, "header")) {
                        if (q < g_in_end and b8(q) == 't') {
                            header = true;
                            q += 4;
                        } else {
                            header = false;
                            q += 5;
                        }
                    } else {
                        q = skipJsonValue(q);
                    }
                    q = skipWs(q);
                    if (q < g_in_end and b8(q) == ',') {
                        q += 1;
                        continue;
                    }
                    q += 1; // '}'
                    break;
                }
            }
        } else {
            q = skipJsonValue(q);
        }
        q = skipWs(q);
        if (q < g_in_end and b8(q) == ',') {
            q += 1;
            continue;
        }
        q += 1; // '}'
        break;
    }
    if (!text_found) {
        // text key missing (e.g. undefined): String(undefined) = "undefined"
        const lit = "undefined";
        for (lit, 0..) |ch, i| b8set(TEXT_BUF + @as(u32, @intCast(i)), ch);
        text_start = TEXT_BUF;
        text_end = TEXT_BUF + lit.len;
    }
    out_text.* = text_start;
    out_text_end.* = text_end;
    out_header.* = header;
    return q;
}

// ---------------- errors buffer ----------------
// Errors are serialized as JSON fragments into ERR_BASE as they are found,
// comma-separated, and copied into the output at the end of the case.
fn errByte(v: u8) void {
    b8set(ERR_BASE + g_err_len, v);
    g_err_len += 1;
}
inline fn errLit(s: []const u8) void {
    for (s) |c| errByte(c);
}
fn errSlice(p: u32, len: u32) void {
    memCopy(ERR_BASE + g_err_len, p, len);
    g_err_len += len;
}
fn errU32(n: u32) void {
    var buf: [10]u8 = undefined;
    var v = n;
    var i: usize = 10;
    if (v == 0) {
        errByte('0');
        return;
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    for (buf[i..10]) |c| errByte(c);
}
fn errRow() void {
    if (cs_rec_row < 0) {
        errLit("null");
    } else {
        errU32(@intCast(cs_rec_row));
    }
}
fn errSep() void {
    if (g_err_len > 0) errByte(',');
}
fn errSimple(code: []const u8) void {
    errSep();
    errLit("{\"code\":\"");
    errLit(code);
    errLit("\",\"line\":");
    errU32(cs_rec_line);
    errLit(",\"row\":");
    errRow();
    errByte('}');
}
fn errShortRow() void {
    errSep();
    errLit("{\"code\":\"short_row\",\"line\":");
    errU32(cs_rec_line);
    errLit(",\"row\":");
    errRow();
    errLit(",\"fields\":");
    errU32(g_nspans);
    errByte('}');
}
fn errLongRow() void {
    const w: u32 = @intCast(cs_width);
    errSep();
    errLit("{\"code\":\"long_row\",\"line\":");
    errU32(cs_rec_line);
    errLit(",\"row\":");
    errRow();
    errLit(",\"extra\":[");
    var i = w;
    while (i < g_nspans) : (i += 1) {
        if (i > w) errByte(',');
        errByte('"');
        errSlice(getSpanPtr(i), getSpanLen(i));
        errByte('"');
    }
    errLit("]}");
}

// ---------------- record field spans ----------------
fn addSpan(ptr: u32, len: u32) void {
    const base = SPAN_BASE + g_nspans * 8;
    storeU32(base, ptr);
    storeU32(base + 4, len);
    g_nspans += 1;
}
fn getSpanPtr(i: u32) u32 {
    return loadU32(SPAN_BASE + i * 8);
}
fn getSpanLen(i: u32) u32 {
    return loadU32(SPAN_BASE + i * 8 + 4);
}

// ---------------- field readers (slow path) ----------------
// All slow-path field values are materialized into the field buffer as
// JSON-escaped bytes (escapes copied verbatim, stray CRs dropped, "" -> ",
// CR/CRLF inside quotes -> \n). Spans then point into the field buffer.

// Read an unquoted field, appending its value to the field buffer starting
// at fb_start, and record a span for it. Returns the end kind. Sets
// g_last_added to the bytes appended by this call.
var g_last_added: u32 = 0;
fn readUnquotedAppend(fb_start: u32) u8 {
    const fb_before = g_fb;
    var seg = cs_pos;
    var p = cs_pos;
    while (true) {
        const m = findCommaOrBs(p, cs_end);
        if (m >= cs_end) {
            memCopy(g_fb, seg, cs_end - seg);
            g_fb += cs_end - seg;
            addSpan(fb_start, g_fb - fb_start);
            g_last_added = g_fb - fb_before;
            cs_pos = cs_end;
            return F_END;
        }
        if (b8(m) == ',') {
            memCopy(g_fb, seg, m - seg);
            g_fb += m - seg;
            addSpan(fb_start, g_fb - fb_start);
            g_last_added = g_fb - fb_before;
            cs_pos = m + 1;
            return F_COMMA;
        }
        // escape at m
        if (m + 1 >= cs_end) {
            // trailing lone backslash (invalid JSON; treat as end)
            memCopy(g_fb, seg, cs_end - seg);
            g_fb += cs_end - seg;
            addSpan(fb_start, g_fb - fb_start);
            g_last_added = g_fb - fb_before;
            cs_pos = cs_end;
            return F_END;
        }
        const e = b8(m + 1);
        if (e == 'n') {
            memCopy(g_fb, seg, m - seg);
            g_fb += m - seg;
            addSpan(fb_start, g_fb - fb_start);
            g_last_added = g_fb - fb_before;
            cs_pos = m + 2;
            cs_line += 1;
            return F_BREAK;
        }
        if (e == 'r') {
            if (m + 4 <= cs_end and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                memCopy(g_fb, seg, m - seg);
                g_fb += m - seg;
                addSpan(fb_start, g_fb - fb_start);
                g_last_added = g_fb - fb_before;
                cs_pos = m + 4;
                cs_line += 1;
                return F_BREAK;
            }
            // stray CR: error, drop it, continue
            errSimple("stray_cr");
            memCopy(g_fb, seg, m - seg);
            g_fb += m - seg;
            seg = m + 2;
            p = m + 2;
            continue;
        }
        // other escape (", t, b, f, \, /, u...): a literal char, keep scanning
        p = if (e == 'u') m + 6 else m + 2;
    }
}
// Standalone unquoted field: use a direct span into the text when no stray
// CR needs dropping (the common case). Falls back to FB materialization
// only when a stray CR is present.
fn readUnquoted() u8 {
    var p = cs_pos;
    const seg_start = cs_pos;
    while (true) {
        const m = findCommaOrBs(p, cs_end);
        if (m >= cs_end) {
            addSpan(seg_start, cs_end - seg_start);
            cs_pos = cs_end;
            return F_END;
        }
        if (b8(m) == ',') {
            addSpan(seg_start, m - seg_start);
            cs_pos = m + 1;
            return F_COMMA;
        }
        if (m + 1 >= cs_end) {
            addSpan(seg_start, cs_end - seg_start);
            cs_pos = cs_end;
            return F_END;
        }
        const e = b8(m + 1);
        if (e == 'n') {
            addSpan(seg_start, m - seg_start);
            cs_pos = m + 2;
            cs_line += 1;
            return F_BREAK;
        }
        if (e == 'r') {
            if (m + 4 <= cs_end and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                addSpan(seg_start, m - seg_start);
                cs_pos = m + 4;
                cs_line += 1;
                return F_BREAK;
            }
            // stray CR: materialize into FB (drops the CR), re-scan from seg_start
            cs_pos = seg_start;
            return readUnquotedAppend(g_fb);
        }
        p = if (e == 'u') m + 6 else m + 2;
    }
}

// Copy a quoted field's content span [cstart, cend) into the field buffer,
// applying the CSV transforms: \"\" -> \" (one quote), \r\n -> \n, \r -> \n.
// Other escapes are copied verbatim. Returns nothing; g_fb advances.
fn copyQuotedContent(cstart: u32, cend: u32) void {
    var q = cstart;
    while (q < cend) {
        const m = findBs(q, cend);
        if (m >= cend) {
            memCopy(g_fb, q, cend - q);
            g_fb += cend - q;
            return;
        }
        memCopy(g_fb, q, m - q);
        g_fb += m - q;
        if (m + 1 >= cend) {
            // trailing backslash (cannot happen inside a closed quoted field)
            return;
        }
        const e = b8(m + 1);
        if (e == '"') {
            // doubled quote \"\" -> emit one \"
            b8set(g_fb, '\\');
            g_fb += 1;
            b8set(g_fb, '"');
            g_fb += 1;
            q = m + 4;
        } else if (e == 'r') {
            // CR (lone or CRLF) -> \n
            b8set(g_fb, '\\');
            g_fb += 1;
            b8set(g_fb, 'n');
            g_fb += 1;
            if (m + 4 <= cend and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                q = m + 4;
            } else {
                q = m + 2;
            }
        } else {
            const elen: u32 = if (e == 'u') 6 else 2;
            memCopy(g_fb, m, elen);
            g_fb += elen;
            q = m + elen;
        }
    }
}

// Read a quoted field whose opening \" is at cs_pos. Materializes the value
// into the field buffer and records a span. Returns the end kind.
fn readQuoted() u8 {
    const open = cs_pos;
    const open_line = cs_line;
    var p = open + 2; // content starts after the opening \"
    var has_dbl = false;
    var has_cr = false;
    var breaks: u32 = 0;
    var close: u32 = 0;
    var closed = false;
    while (true) {
        const m = findBs(p, cs_end);
        if (m >= cs_end) break; // unterminated
        if (m + 1 >= cs_end) break; // trailing backslash: unterminated
        const e = b8(m + 1);
        if (e == '"') {
            // quote char: doubled ("") or closing?
            if (m + 4 <= cs_end and b8(m + 2) == '\\' and b8(m + 3) == '"') {
                has_dbl = true;
                p = m + 4;
                continue;
            }
            close = m;
            closed = true;
            break;
        }
        if (e == 'n') {
            breaks += 1;
            p = m + 2;
            continue;
        }
        if (e == 'r') {
            has_cr = true;
            breaks += 1;
            // CRLF pair counts once: skip a following \n escape too
            if (m + 4 <= cs_end and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                p = m + 4;
            } else {
                p = m + 2;
            }
            continue;
        }
        p = if (e == 'u') m + 6 else m + 2;
    }
    if (!closed) {
        // The quote never closes: literal char, text re-read as unquoted.
        cs_pos = open + 2;
        cs_line = open_line;
        errSimple("unterminated_quote");
        const fb_start = g_fb;
        b8set(g_fb, '\\');
        g_fb += 1;
        b8set(g_fb, '"');
        g_fb += 1;
        return readUnquotedAppend(fb_start);
    }
    const cstart = open + 2;
    const cend = close;
    // line breaks inside the quoted content (counted inline during the scan)
    cs_line += breaks;
    // what follows the closing quote (which ends at close+2)
    cs_pos = close + 2;
    const clean_end: u8 = blk: {
        if (cs_pos >= cs_end) break :blk F_END;
        const c = b8(cs_pos);
        if (c == ',') break :blk F_COMMA;
        if (c == '\\' and cs_pos + 1 < cs_end) {
            const e = b8(cs_pos + 1);
            if (e == 'n') break :blk F_BREAK;
            if (e == 'r' and cs_pos + 4 <= cs_end and b8(cs_pos + 2) == '\\' and b8(cs_pos + 3) == 'n') break :blk F_BREAK;
        }
        break :blk F_JUNK;
    };
    if (clean_end != F_JUNK and !has_dbl and !has_cr) {
        // direct span into the text (no FB copy, no transform needed)
        addSpan(cstart, cend - cstart);
        if (clean_end == F_END) return F_END;
        if (clean_end == F_COMMA) { cs_pos += 1; return F_COMMA; }
        // F_BREAK
        if (b8(cs_pos + 1) == 'n') { cs_pos += 2; } else { cs_pos += 4; }
        cs_line += 1;
        return F_BREAK;
    }
    // materialize the content (transforms if needed)
    const fb_start = g_fb;
    if (!has_dbl and !has_cr) {
        memCopy(g_fb, cstart, cend - cstart);
        g_fb += cend - cstart;
    } else {
        copyQuotedContent(cstart, cend);
    }
    if (cs_pos >= cs_end) {
        addSpan(fb_start, g_fb - fb_start);
        return F_END;
    }
    const c = b8(cs_pos);
    if (c == ',') {
        addSpan(fb_start, g_fb - fb_start);
        cs_pos += 1;
        return F_COMMA;
    }
    if (c == '\\') {
        if (cs_pos + 1 < cs_end) {
            const e = b8(cs_pos + 1);
            if (e == 'n') {
                addSpan(fb_start, g_fb - fb_start);
                cs_pos += 2;
                cs_line += 1;
                return F_BREAK;
            }
            if (e == 'r' and cs_pos + 4 <= cs_end and b8(cs_pos + 2) == '\\' and b8(cs_pos + 3) == 'n') {
                addSpan(fb_start, g_fb - fb_start);
                cs_pos += 4;
                cs_line += 1;
                return F_BREAK;
            }
        }
    }
    // junk after the closing quote: read as unquoted, appended to the value
    const fb_before_junk = g_fb;
    const kind = readUnquotedAppend(fb_start);
    if (g_fb - fb_before_junk > 0) {
        // junk.added > 0 (bytes appended by the junk scan; a junk of only
        // dropped stray CRs appends 0 bytes, matching added == 0)
        errSimple("quote_junk");
    }
    return kind;
}

// ---------------- record parsing ----------------
fn skipEmptyLines() void {
    while (cs_pos < cs_end) {
        const c = b8(cs_pos);
        if (c == '\\' and cs_pos + 1 < cs_end and b8(cs_pos + 1) == 'n') {
            cs_pos += 2;
            cs_line += 1;
        } else if (c == '\\' and cs_pos + 4 <= cs_end and b8(cs_pos + 1) == 'r' and b8(cs_pos + 2) == '\\' and b8(cs_pos + 3) == 'n') {
            cs_pos += 4;
            cs_line += 1;
        } else break;
    }
}

// Fast path: the record starting at cs_pos is one clean line (no quotes, no
// stray CR). Parses it by splitting on commas, fills the spans, and returns
// true. Returns false if the line is not clean (caller falls back to the
// slow field-by-field path). Does not move cs_pos on false.
fn tryFastRecord() bool {
    var p = cs_pos;
    // comma positions within this line (max 64; more falls back to slow path)
    var commas: [64]u32 = undefined;
    var ncommas: u32 = 0;
    var content_end: u32 = 0;
    var after_pos: u32 = 0;
    var is_last: bool = false; // line ends at cs_end (no terminator)
    while (true) {
        const m = findCommaOrBs(p, cs_end);
        if (m >= cs_end) {
            content_end = cs_end;
            after_pos = cs_end;
            is_last = true;
            break;
        }
        const c = b8(m);
        if (c == ',') {
            if (ncommas >= 64) return false;
            commas[ncommas] = m;
            ncommas += 1;
            p = m + 1;
            continue;
        }
        // escape at m
        if (m + 1 >= cs_end) {
            // trailing backslash: treat line as ending at cs_end
            content_end = cs_end;
            after_pos = cs_end;
            is_last = true;
            break;
        }
        const e = b8(m + 1);
        if (e == 'n') {
            content_end = m;
            after_pos = m + 2;
            break;
        }
        if (e == 'r') {
            if (m + 4 <= cs_end and b8(m + 2) == '\\' and b8(m + 3) == 'n') {
                content_end = m;
                after_pos = m + 4;
                break;
            }
            return false; // stray CR
        }
        if (e == '"') return false; // quote
        p = if (e == 'u') m + 6 else m + 2;
    }
    // Clean line: fields are the comma-separated segments. They are already
    // JSON-escaped (escapes copied verbatim), so spans point into the text.
    g_nspans = 0;
    g_fb = FB_BASE;
    var fstart = cs_pos;
    var i: u32 = 0;
    while (i < ncommas) : (i += 1) {
        addSpan(fstart, commas[i] - fstart);
        fstart = commas[i] + 1;
    }
    addSpan(fstart, content_end - fstart);
    g_fast_recs += 1;
    g_fast_fields += ncommas + 1;
    g_last_quoted = false;
    cs_pos = after_pos;
    if (!is_last) cs_line += 1;
    return true;
}

// Slow path: parse one record field by field. Fills the spans.
// Returns the end kind of the last field (F_BREAK / F_END).
fn parseSlowRecord() u8 {
    g_slow_recs += 1;
    g_nspans = 0;
    g_fb = FB_BASE;
    var kind: u8 = F_END;
    while (true) {
        const quoted = cs_pos < cs_end and b8(cs_pos) == '\\' and cs_pos + 1 < cs_end and b8(cs_pos + 1) == '"';
        g_last_quoted = quoted;
        kind = if (quoted) readQuoted() else readUnquoted();
        g_slow_fields += 1;
        if (kind == F_COMMA) continue;
        break;
    }
    return kind;
}

// Parse the next non-dropped record into the spans. Returns true if a record
// was found, false at end of text. Sets cs_rec_line / cs_rec_row.
fn parseNextRecord() bool {
    while (true) {
        skipEmptyLines();
        if (cs_pos >= cs_end) return false;
        cs_rec_line = cs_line;
        cs_rec_row = if (cs_header and !cs_cols_done) -1 else @intCast(cs_rows);
        const ok = tryFastRecord();
        if (!ok) {
            _ = parseSlowRecord();
        }
        // drop a record that held only one empty unquoted field
        if (g_nspans == 1 and getSpanLen(0) == 0 and !g_last_quoted) {
            continue; // dropped (its errors stay); parse the next record
        }
        return true;
    }
}

// ---------------- record emission ----------------
inline fn emitRecordArray() void {
    outByte('[');
    var i: u32 = 0;
    while (i < g_nspans) : (i += 1) {
        if (i > 0) outByte(',');
        outByte('"');
        outSlice(getSpanPtr(i), getSpanLen(i));
        outByte('"');
    }
    outByte(']');
}
// Emit a row with exactly `nemit` fields, padded with "" up to `pad_to`.
fn emitRowFields(nemit: u32, pad_to: u32) void {
    outByte('[');
    var i: u32 = 0;
    while (i < nemit) : (i += 1) {
        if (i > 0) outByte(',');
        outByte('"');
        outSlice(getSpanPtr(i), getSpanLen(i));
        outByte('"');
    }
    var j = nemit;
    while (j < pad_to) : (j += 1) {
        if (j > 0) outByte(',');
        outLit("\"\"");
    }
    outByte(']');
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0xFF;
}
fn isBomEscape(p: u32) bool {
    if (p + 6 > cs_end) return false;
    if (b8(p) != '\\' or b8(p + 1) != 'u') return false;
    return hexVal(b8(p + 2)) == 0xF and hexVal(b8(p + 3)) == 0xE and
        hexVal(b8(p + 4)) == 0xF and hexVal(b8(p + 5)) == 0xF;
}

// ---------------- case driver ----------------
fn processCase(text_start: u32, text_end: u32, header: bool) void {
    cs_start = text_start;
    cs_end = text_end;
    cs_pos = text_start;
    cs_line = 1;
    cs_width = -1;
    cs_header = header;
    cs_rows = 0;
    cs_cols_done = false;
    g_err_len = 0;
    // BOM: raw UTF-8 EF BB BF, or the \uFEFF escape
    if (cs_end - cs_start >= 3 and b8(cs_start) == 0xEF and b8(cs_start + 1) == 0xBB and b8(cs_start + 2) == 0xBF) {
        cs_pos = cs_start + 3;
    } else if (isBomEscape(cs_start)) {
        cs_pos = cs_start + 6;
    }
    outLit("{\"columns\":");
    if (!parseNextRecord()) {
        // no records at all (errors from dropped records still apply)
        if (header) {
            outLit("[]");
        } else {
            outLit("null");
        }
        outLit(",\"rows\":[],\"errors\":[");
        outSlice(ERR_BASE, g_err_len);
        outLit("]}");
        return;
    }
    // first record found; it sets the width
    cs_width = @intCast(g_nspans);
    if (header) {
        emitRecordArray(); // columns
        cs_cols_done = true;
    } else {
        outLit("null");
    }
    outLit(",\"rows\":[");
    if (!header) {
        // first record is row 0
        emitRecordArray();
        cs_rows = 1;
    }
    // subsequent records
    while (parseNextRecord()) {
        const w: u32 = @intCast(cs_width);
        if (g_nspans < w) {
            errShortRow();
            if (cs_rows > 0) outByte(',');
            emitRowFields(g_nspans, w);
            cs_rows += 1;
        } else if (g_nspans > w) {
            errLongRow();
            if (cs_rows > 0) outByte(',');
            emitRowFields(w, w);
            cs_rows += 1;
        } else {
            if (cs_rows > 0) outByte(',');
            emitRecordArray();
            cs_rows += 1;
        }
    }
    outLit("],\"errors\":[");
    outSlice(ERR_BASE, g_err_len);
    outLit("]}");
}

// ---------------- entry point ----------------

// Run the whole cases.json (at in_ptr, in_len bytes) and write answers.json
// to OUT_BASE. Returns the output length in bytes. The caller (JS) reads
// [OUT_BASE, OUT_BASE + len) from the exported memory.
// Grow linear memory to 1024 pages (64 MiB) if smaller. Call once before
// writing the input.
export fn init() void {
    const need_pages: u32 = 1024;
    const cur = @wasmMemorySize(0);
    if (cur < need_pages) {
        _ = @wasmMemoryGrow(0, need_pages - cur);
    }
}

export fn run_json(in_ptr: u32, in_len: u32) u32 {
    // Ensure enough linear memory (1024 pages = 64 MiB).
    const need_pages: u32 = 1024;
    const cur = @wasmMemorySize(0);
    if (cur < need_pages) {
        _ = @wasmMemoryGrow(0, need_pages - cur);
    }
    g_in_end = in_ptr + in_len;
    g_out = OUT_BASE;
    var p = skipWs(in_ptr);
    // top-level '['
    if (p < g_in_end and b8(p) == '[') p += 1;
    outByte('[');
    var first = true;
    p = skipWs(p);
    if (p < g_in_end and b8(p) == ']') {
        outByte(']');
        return g_out - OUT_BASE;
    }
    while (true) {
        p = skipWs(p);
        var ts: u32 = 0;
        var te: u32 = 0;
        var hdr: bool = false;
        p = parseCase(p, &ts, &te, &hdr);
        if (!first) outByte(',');
        first = false;
        processCase(ts, te, hdr);
        p = skipWs(p);
        if (p < g_in_end and b8(p) == ',') {
            p += 1;
            continue;
        }
        break; // ']'
    }
    outByte(']');
    return g_out - OUT_BASE;
}

// Output buffer base (so JS does not hardcode the layout).
export fn out_ptr() u32 {
    return OUT_BASE;
}

// Current linear memory size in pages (diagnostics).
export fn mem_pages() u32 {
    return @wasmMemorySize(0);
}
