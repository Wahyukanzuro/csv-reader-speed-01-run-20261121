// Fast drop-in for csv-reader 1.0.0: run(input) returns exactly csv-reader's
// {columns, rows, errors} for the input {text, header}, but much faster.
// Strategy: slice fields with indexOf jumps instead of reading character by
// character, and take a whole-line fast path for records that hold no quote
// and no stray CR. The reference semantics (vendor/csv-reader/index.js):
// BOM dropped at the start; empty lines are no records; a CR outside quotes
// not followed by LF is dropped (stray_cr); a quoted field runs to the next
// quote that is not doubled ("" is one quote, CRLF/lone CR inside is LF),
// junk after its closing quote is appended as it stands (quote_junk), and a
// quote that never closes is a literal character with the text after it read
// again as unquoted (unterminated_quote); rows are padded (short_row) or cut
// (long_row) to the first record's width; errors carry {code, line, row} in
// the order met, line/row being the record's start line and rows-index.

const COMMA = 0;
const LINE_BREAK = 1;
const END = 2;

let text = '';
let len = 0;
let pos = 0;
let line = 1;
let header = false;
let errors = null;
let rows = null;
let columns = null;
let width = -1;
let recordLine = 1;
let recordRow = null;
let fEnded = END;
let uAdded = 0;

function error(code) {
  errors.push({ code, line: recordLine, row: recordRow });
}

// Reads an unquoted field starting at pos, appending onto `value` ('' for a
// fresh field, the quoted value for junk after a closing quote, '"' for the
// re-read after an unterminated quote). Sets fEnded (COMMA/LINE_BREAK/END)
// and uAdded (characters appended). A CR not followed by LF is dropped and
// records stray_cr; the field goes on after it.
function readUnquoted(value) {
  uAdded = 0;
  for (;;) {
    const c = text.indexOf(',', pos);
    const n = text.indexOf('\n', pos);
    const r = text.indexOf('\r', pos);
    let m = -1;
    let kind = 0;
    if (c !== -1) { m = c; kind = 0; }
    if (n !== -1 && (m === -1 || n < m)) { m = n; kind = 1; }
    if (r !== -1 && (m === -1 || r < m)) { m = r; kind = 2; }
    if (m === -1) {
      if (pos < len) { value += text.slice(pos); uAdded += len - pos; }
      pos = len;
      fEnded = END;
      return value;
    }
    if (kind === 0) {
      if (m > pos) { value += text.slice(pos, m); uAdded += m - pos; }
      pos = m + 1;
      fEnded = COMMA;
      return value;
    }
    if (kind === 1) {
      if (m > pos) { value += text.slice(pos, m); uAdded += m - pos; }
      pos = m + 1;
      line++;
      fEnded = LINE_BREAK;
      return value;
    }
    // kind === 2: a CR.
    if (text.charCodeAt(m + 1) === 10) {
      if (m > pos) { value += text.slice(pos, m); uAdded += m - pos; }
      pos = m + 2;
      line++;
      fEnded = LINE_BREAK;
      return value;
    }
    // Stray CR: dropped, error recorded, field goes on.
    error('stray_cr');
    if (m > pos) { value += text.slice(pos, m); uAdded += m - pos; }
    pos = m + 1;
  }
}

// The value of a quoted field's content, text[start..end) (start just after
// the opening quote, end at the closing quote), with "" collapsed to one
// quote and every CRLF or lone CR inside read as LF. Updates `line` for the
// line breaks inside. `hasEsc` says whether any "" pair was met.
function quotedValue(start, end, hasEsc) {
  const r = text.indexOf('\r', start);
  const hasCR = r !== -1 && r < end;
  if (!hasCR) {
    let cnt = 0;
    for (let i = text.indexOf('\n', start); i !== -1 && i < end; i = text.indexOf('\n', i + 1)) cnt++;
    line += cnt;
    const s = text.slice(start, end);
    return hasEsc ? s.replaceAll('""', '"') : s;
  }
  const seg = text.slice(start, end);
  const br = seg.match(/\r\n|\r|\n/g);
  line += br ? br.length : 0;
  const s = seg.replace(/\r\n?/g, '\n');
  return hasEsc ? s.replaceAll('""', '"') : s;
}

// Reads a quoted field whose opening quote is at pos. Sets fEnded.
function readQuoted() {
  const open = pos;
  const openLine = line;
  let q = open + 1;
  let close = -1;
  let hasEsc = false;
  for (;;) {
    q = text.indexOf('"', q);
    if (q === -1) break;
    if (text.charCodeAt(q + 1) === 34) { hasEsc = true; q += 2; continue; }
    close = q;
    break;
  }
  if (close === -1) {
    // The quote never closes: it is a literal character, and the text after
    // it is read again as unquoted.
    pos = open + 1;
    line = openLine;
    error('unterminated_quote');
    return readUnquoted('"');
  }
  const value = quotedValue(open + 1, close, hasEsc);
  pos = close + 1;
  if (pos >= len) { fEnded = END; return value; }
  const c = text.charCodeAt(pos);
  if (c === 44) { pos++; fEnded = COMMA; return value; }
  if (c === 10) { pos++; line++; fEnded = LINE_BREAK; return value; }
  if (c === 13 && text.charCodeAt(pos + 1) === 10) { pos += 2; line++; fEnded = LINE_BREAK; return value; }
  // What follows the closing quote is appended as it stands.
  const junk = readUnquoted(value);
  if (uAdded > 0) error('quote_junk');
  return junk;
}

// A record's fields are complete: apply the width rule, or drop a record
// that held only one empty unquoted field. `quoted` says whether the
// record's (only) field opened with a quote.
function finishRecord(fields, quoted) {
  if (fields.length === 1 && fields[0] === '' && !quoted) return;
  if (width < 0) width = fields.length;
  if (header && columns === null) { columns = fields; return; }
  if (fields.length < width) {
    errors.push({ code: 'short_row', line: recordLine, row: recordRow, fields: fields.length });
    while (fields.length < width) fields.push('');
  } else if (fields.length > width) {
    errors.push({ code: 'long_row', line: recordLine, row: recordRow, extra: fields.splice(width) });
  }
  rows.push(fields);
}

/** csv-reader 1.0.0's answer for one case's input {text, header}. */
export function run(input) {
  text = String(input.text);
  header = input.header === true;
  len = text.length;
  errors = [];
  rows = [];
  columns = null;
  width = -1;
  pos = 0;
  line = 1;
  if (len > 0 && text.charCodeAt(0) === 0xFEFF) pos = 1;

  for (;;) {
    // Lines with no characters are no records.
    while (pos < len) {
      const c = text.charCodeAt(pos);
      if (c === 10) { pos++; line++; }
      else if (c === 13 && text.charCodeAt(pos + 1) === 10) { pos += 2; line++; }
      else break;
    }
    if (pos >= len) break;

    recordLine = line;
    recordRow = (header && columns === null) ? null : rows.length;

    // Fast path: the record's line holds no quote and no stray CR, so the
    // record is exactly this one line; split it on commas.
    const nl = text.indexOf('\n', pos);
    const q = text.indexOf('"', pos);
    const r = text.indexOf('\r', pos);
    const fast = nl === -1
      ? (q === -1 && r === -1)
      : ((q === -1 || q > nl) && (r === -1 || r === nl - 1 || r > nl));
    if (fast) {
      const contentEnd = nl === -1 ? len : (r === nl - 1 ? nl - 1 : nl);
      const fields = text.slice(pos, contentEnd).split(',');
      pos = nl === -1 ? len : nl + 1;
      if (nl !== -1) line++;
      finishRecord(fields, false);
      continue;
    }

    // Slow path: field by field.
    const fields = [];
    let quoted = false;
    let value;
    do {
      quoted = text.charCodeAt(pos) === 34;
      value = quoted ? readQuoted() : readUnquoted('');
      fields.push(value);
    } while (fEnded === COMMA);
    finishRecord(fields, quoted);
  }
  return { columns: header ? (columns ?? []) : null, rows, errors };
}
