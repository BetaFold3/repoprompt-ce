#!/usr/bin/env python3
"""Streaming output records for the conductor (plan Step 3).

Pure helpers shared by the live output reader (tail, XCTest progress and
telemetry) and retrospective summaries. This module owns no process, socket,
scheduler or job state.

* ``RecordSplitter``: bytes -> ``OutputRecord``. Records end at ``\\n``,
  ``\\r\\n`` or a bare ``\\r``; a bare ``\\r`` emits its record immediately and
  swallows one following ``\\n``, even across a read boundary. Splits only
  happen on ASCII delimiters, so UTF-8 and ANSI sequences split across reads are
  reassembled before decoding. A pending record is capped at 64 KiB: the
  record keeps its first 64 KiB as text, a bounded suffix and the dropped byte
  count as diagnostics, and is marked truncated. A record completed by a later
  read takes that read's receive time. Before any byte is dropped, the whole
  over-cap record also streams through a bounded ``VisiblePrefix`` (its first
  visible characters, ANSI removed exactly as from the whole text) and an
  optional ``SegmentScanner`` that classifies it line by line, so the tail,
  summaries and XCTest progress never depend on where the record was cut.
* ``iter_file_texts``: a raw log streamed through the splitter.
* ``tail_entry``/``tail_entries_from_text``: ANSI-stripped visible-tail entries
  capped at 4 KiB (OD7), each terminated by ``\\n`` unless it is an
  unterminated final record (an over-cap record's entry comes from its
  ``visible`` prefix, ``visible_tail_entry``).
* ``OutputTail``: the job tail, at most 30 entries and 64 KiB.
* ``record_batches``: per-read batches of at most 256 records or 64 KiB.
"""
from __future__ import annotations

import re
from collections import deque
from itertools import repeat
from operator import itemgetter
from pathlib import Path
import codecs
from typing import Any, Callable, FrozenSet, Iterable, Iterator, List, NamedTuple, Optional, Sequence, Tuple

READ_CHUNK_BYTES = 64 * 1024
MAX_PENDING_RECORD_BYTES = 64 * 1024
TRUNCATED_SUFFIX_BYTES = 256
BATCH_MAX_RECORDS = 256
BATCH_MAX_BYTES = 64 * 1024
TAIL_MAX_ENTRIES = 30
TAIL_MAX_BYTES = 64 * 1024
TAIL_ENTRY_MAX_BYTES = 4 * 1024
TAIL_ELLIPSIS = "…"
# OD14 bounded PTY available-read coalescing: after one blocking read, the reader
# takes further reads only while data is already available (never waits for more),
# and ends a group at whichever of these bounds comes first. Each further read asks
# for at most the group's remaining bytes and none starts once the time budget is
# spent. Each read keeps its own receive time, raw bytes, order, and its own write
# and flush; only the lock/notify cycle (tail, transitions, notify) is shared.
COALESCE_MAX_BYTES = 64 * 1024
COALESCE_MAX_READS = 64
COALESCE_MAX_NS = 5_000_000
_ELLIPSIS_BYTES = len(TAIL_ELLIPSIS.encode("utf-8"))

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")
# CSI only: the grammar retrospective summaries strip (``conductor.ANSI_RE``).
CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# Visible characters kept for an over-cap record: enough for a tail entry's
# 4 KiB cut (one more character than the cut can need, so "longer" is exact).
TAIL_VISIBLE_CHARS = TAIL_ENTRY_MAX_BYTES + 1


class OutputRecord(NamedTuple):
    seq: int
    receive_ns: int
    text: str  # bounded: at most ``max_pending`` bytes decoded, no delimiter
    delimiter: str  # "lf" | "crlf" | "cr" | "eof"
    truncated: bool = False
    dropped_bytes: int = 0  # bytes beyond the kept prefix (truncated records only)
    suffix: str = ""  # the last dropped bytes, decoded (truncated records only)
    # Segment items the scanner classified over the whole record (truncated
    # records of a splitter with a scanner only), in order. Empty for the
    # record at which the scanner failed (OD16, ``RecordSplitter.segment_failure``)
    # and for every later record of that splitter.
    segment_items: tuple = ()
    # Truncated records only: the first characters of the whole record's
    # decoded text with the splitter's ANSI grammar removed in one pass (see
    # ``VisiblePrefix``), or ``None``.
    visible: Optional[str] = None


_DELIMITER_RE = re.compile(rb"\r\n|\r|\n")
_SPLIT_BYTES_RE = re.compile(rb"(\r\n|\r|\n)")
_SPLIT_TEXT_RE = re.compile(r"\r\n|\r|\n")
_SPLIT_TEXT_CAPTURE_RE = re.compile(r"(\r\n|\r|\n)")
_TEXT_DELIMITER_KINDS = {"\n": "lf", "\r\n": "crlf", "\r": "cr"}
_tuple_new = tuple.__new__
# Reads smaller than this use the reference loop; the bulk path is faster at
# every size (tests raise this to force the reference loop).
_BULK_MIN_BYTES = 1
# Segment items an over-cap record may hold until it completes (bounded memory:
# each item holds at most ``SEGMENT_MAX_CHARS`` characters). One more fails the
# scanner (OD16): the items are neither applied early nor dropped silently.
SEGMENT_MAX_PENDING_ITEMS = 16
# An ESC that may still start a sequence of ``ANSI_RE`` or ``CSI_RE`` once more
# text arrives (it ends the text it is matched in).
_ANSI_OPEN_TAIL_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*)?")


class VisiblePrefix:
    """The first ``max_chars`` characters of ``pattern.sub("", text)``, in bounded memory.

    ``text`` is the fed bytes decoded with replacement (incrementally, which
    equals decoding them at once). ``pattern`` is ``ANSI_RE`` or ``CSI_RE``:
    every match starts at ESC and holds no other ESC, so the text before the
    last ESC is substituted exactly as within the whole text, and only a
    trailing ESC that may still start a sequence is carried to the next piece.
    A carried candidate longer than needed keeps its first characters (all
    that can be visible within ``max_chars`` if it turns out literal) and its
    last one: it is ``ESC [`` then parameters then intermediates, so dropping
    a middle part of that run keeps its grammar state (parameter or
    intermediate phase) and never changes whether or where the sequence ends.
    Nothing is decoded once ``max_chars`` characters are known.
    """

    def __init__(self, max_chars: int, pattern: "re.Pattern[str]" = ANSI_RE) -> None:
        self._max = max(0, int(max_chars))
        self._sub = pattern.sub
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._parts: List[str] = []
        self._count = 0
        self._carry = ""
        self.complete = self._max == 0

    def feed(self, data: bytes) -> None:
        if self.complete:
            return
        text = self._decoder.decode(data)
        if self._carry:
            text = self._carry + text
            self._carry = ""
        cut = text.rfind("\x1b")
        if cut >= 0 and _ANSI_OPEN_TAIL_RE.match(text, cut).end() == len(text):
            keep = self._max - self._count + 2
            carry = text[cut:]
            self._carry = carry if len(carry) <= keep else carry[: keep - 1] + carry[-1]
            text = text[:cut]
        if text:
            self._add(self._sub("", text) if "\x1b" in text else text)

    def _add(self, visible: str) -> None:
        if not visible:
            return  # ANSI-only input keeps no fragment (bounded memory)
        room = self._max - self._count
        if len(visible) < room:
            self._parts.append(visible)
            self._count += len(visible)
            return
        self._parts.append(visible[:room])
        self._count = self._max
        self._carry = ""
        self.complete = True

    def finish(self) -> str:
        """End of the text: an unterminated candidate is literal."""
        if not self.complete:
            text = self._carry + self._decoder.decode(b"", True)
            self._carry = ""
            if text:
                self._add(self._sub("", text) if "\x1b" in text else text)
        return "".join(self._parts)


class RecordSplitter:
    """Streaming bytes -> records. Not thread-safe; one per reader.

    When a pending record first exceeds ``max_pending``, every byte of that
    record from its start, before anything is dropped, also streams through a
    ``VisiblePrefix`` (``visible_chars`` characters, ``visible_pattern``; 0
    disables it), whose result rides on the record as ``visible`` when it
    completes. ``segment_scanner`` (optional) is a factory for a
    ``SegmentScanner`` that receives the same bytes; the items of the segments
    it classifies ride on the record as ``segment_items``, so they take the
    receive time of the read that completes the record. When a scanner fails
    (OD16: a marker-shaped segment over its character bound, or more than
    ``SEGMENT_MAX_PENDING_ITEMS`` items), ``segment_failure`` latches
    ``(kind, seq)`` of the record it was scanning; that record carries no
    items and no later record is scanned. Records and raw bytes are unaffected.
    """

    def __init__(
        self,
        max_pending: int = MAX_PENDING_RECORD_BYTES,
        first_seq: int = 0,
        suffix_bytes: int = TRUNCATED_SUFFIX_BYTES,
        segment_scanner: Optional[Callable[[], "SegmentScanner"]] = None,
        visible_chars: int = TAIL_VISIBLE_CHARS,
        visible_pattern: "re.Pattern[str]" = ANSI_RE,
    ) -> None:
        if max_pending <= 0:
            raise ValueError("max_pending must be positive")
        self.max_pending = max_pending
        self.suffix_bytes = max(0, int(suffix_bytes))
        self._pending = bytearray()
        self._suffix = bytearray()
        self._record_dropped = 0
        self._swallow_lf = False
        self._seq = first_seq
        self._scanner_factory = segment_scanner
        self._scanner: Optional[SegmentScanner] = None
        self._visible_chars = max(0, int(visible_chars))
        self._visible_pattern = visible_pattern
        self._visible: Optional[VisiblePrefix] = None
        self.dropped_bytes = 0
        self.truncated_records = 0
        # OD16: ``(SegmentScanner.failure, seq of the record being scanned)``, once.
        self.segment_failure: Optional[Tuple[str, int]] = None

    @property
    def line_open(self) -> bool:
        """Bytes of an unterminated record are pending: the raw stream ends mid-line."""
        return bool(self._pending)

    def _latch_segment_failure(self) -> None:
        """The scanner hit a bound (OD16): latch it and stop scanning this stream."""
        if self.segment_failure is None and self._scanner is not None:
            self.segment_failure = (str(self._scanner.failure), self._seq)
        self._scanner = None
        self._scanner_factory = None

    def _append(self, piece: bytes) -> None:
        room = self.max_pending - len(self._pending)
        if len(piece) <= room:
            self._pending += piece
            return
        if self._record_dropped:
            if self._scanner is not None:
                self._scanner.feed(piece)
                if self._scanner.failure is not None:
                    self._latch_segment_failure()
            if self._visible is not None:
                self._visible.feed(piece)
        else:
            # First overflow of this record: stream it from its first byte.
            whole = bytes(self._pending) + piece
            if self._scanner_factory is not None:
                self._scanner = self._scanner_factory()
                self._scanner.feed(whole)
                if self._scanner.failure is not None:
                    self._latch_segment_failure()
            if self._visible_chars:
                self._visible = VisiblePrefix(self._visible_chars, self._visible_pattern)
                self._visible.feed(whole)
        if room > 0:
            self._pending += piece[:room]
            piece = piece[room:]
        dropped = len(piece)
        self._record_dropped += dropped
        self.dropped_bytes += dropped
        if self.suffix_bytes:
            self._suffix += piece[-self.suffix_bytes:]
            if len(self._suffix) > self.suffix_bytes:
                del self._suffix[: len(self._suffix) - self.suffix_bytes]

    def _emit(self, receive_ns: int, delimiter: str) -> OutputRecord:
        dropped = self._record_dropped
        if dropped:
            self.truncated_records += 1
            items: tuple = ()
            if self._scanner is not None:
                items = tuple(self._scanner.finish())
                if self._scanner.failure is not None:
                    items = ()
                    self._latch_segment_failure()
                self._scanner = None
            visible: Optional[str] = None
            if self._visible is not None:
                visible = self._visible.finish()
                self._visible = None
            record = OutputRecord(
                self._seq,
                receive_ns,
                bytes(self._pending).decode("utf-8", errors="replace"),
                delimiter,
                True,
                dropped,
                bytes(self._suffix).decode("utf-8", errors="replace"),
                items,
                visible,
            )
            self._suffix = bytearray()
            self._record_dropped = 0
        else:
            record = _tuple_new(
                OutputRecord,
                (self._seq, receive_ns, bytes(self._pending).decode("utf-8", errors="replace"), delimiter, False, 0, "", (), None),
            )
        self._seq += 1
        self._pending = bytearray()
        return record

    def feed(self, data: bytes, receive_ns: int) -> List[OutputRecord]:
        start = 0
        if self._swallow_lf and data[:1] == b"\n":
            start = 1
        if data:
            self._swallow_lf = False
        if self._record_dropped:
            return self._feed_slow(data, start, receive_ns)
        size = len(data)
        if size < _BULK_MIN_BYTES:
            return self._feed_slow(data, start, receive_ns)
        last = max(data.rfind(b"\n"), data.rfind(b"\r"))
        if last < start:
            self._append(data[start:])
            return []
        # Bulk path: split complete records in C; any record that would hit
        # the pending cap falls back to the reference loop for this read.
        region = bytes(self._pending) + data[start:last + 1] if self._pending else data[start:last + 1]
        if len(region) > self.max_pending and max(map(len, _SPLIT_BYTES_RE.split(region))) > self.max_pending:
            return self._feed_slow(data, start, receive_ns)
        # Delimiters are ASCII and never part of a UTF-8 sequence (nor produced
        # by replacement), so decoding the region once and splitting the text
        # equals decoding each record separately.
        pieces = _SPLIT_TEXT_CAPTURE_RE.split(region.decode("utf-8", errors="replace"))
        texts = pieces[0::2]
        texts.pop()
        delimiters = pieces[1::2]
        count = len(delimiters)
        if count != region.count(b"\n") + region.count(b"\r") - region.count(b"\r\n"):
            raise ValueError("record split mismatch after decoding")
        if delimiters[-1] == "\r" and last == size - 1:
            self._swallow_lf = True
        first_seq = self._seq
        self._seq += count
        self._pending = bytearray()
        if last + 1 < size:
            self._append(data[last + 1:])
        return list(map(
            _tuple_new,
            repeat(OutputRecord, count),
            zip(
                range(first_seq, first_seq + count),
                repeat(receive_ns, count),
                texts,
                map(_TEXT_DELIMITER_KINDS.__getitem__, delimiters),
                repeat(False, count),
                repeat(0, count),
                repeat("", count),
                repeat((), count),
                repeat(None, count),
            ),
        ))

    def _feed_slow(self, data: bytes, start: int, receive_ns: int) -> List[OutputRecord]:
        """Reference per-record loop (also used for truncation)."""
        records: List[OutputRecord] = []
        end = len(data)
        for match in _DELIMITER_RE.finditer(data, start):
            self._append(data[start:match.start()])
            token = match.group(0)
            if token == b"\r\n":
                delimiter = "crlf"
            elif token == b"\r":
                delimiter = "cr"
                if match.end() == end:
                    self._swallow_lf = True
            else:
                delimiter = "lf"
            records.append(self._emit(receive_ns, delimiter))
            start = match.end()
        if start < end:
            self._append(data[start:])
        return records

    def finish(self, receive_ns: int) -> List[OutputRecord]:
        """Flush a final record that has no delimiter (EOF)."""
        self._swallow_lf = False
        if not self._pending and not self._record_dropped:
            return []
        return [self._emit(receive_ns, "eof")]


# ``str.splitlines`` boundaries. Inside a record only the ones other than CR/LF
# occur (CR and LF end records).
_SEGMENT_SEPARATOR_RE = re.compile("[\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]")
# The SGR grammar stripped before line matching (``conductor.XCTEST_ANSI_SGR_RE``).
SEGMENT_SGR_PATTERN = r"\x1b\[[0-9:;]*m"
_SEGMENT_SGR_RE = re.compile(SEGMENT_SGR_PATTERN)
_SGR_PARAMETER_CHARS = "0123456789:;"
# A trailing candidate that could still become an SGR sequence in a later piece.
_SGR_OPEN_TAIL_RE = re.compile(r"\x1b(?:\[[0-9:;]*)?\Z")
SEGMENT_MAX_CHARS = 64 * 1024
# OD16: the XCTest progress-marker grammar (``conductor.XCTEST_PROGRESS_RE``),
# decided exactly in bounded memory for a stripped segment over the bound by
# ``SegmentScanner(marker_shape=True)``. Such content is a marker iff it starts
# with ``_MARKER_HEAD`` and either ends with ``_MARKER_PLAIN_END_RE`` or ends
# with ")." whose ")" closes a ")"-free run holding an opener. The opener's
# quote is at index 12 or later (the name ``(.+)`` is not empty), so the shape
# is tracked from index 12. Stripped content has no trailing ``\s``, holds no
# ``\n``, and is longer than the bound (so a plain end never overlaps the head).
XCTEST_MARKER_PATTERN = r"^Test Case '(.+)' (started|passed|failed|skipped)(?: \([^)]*\))?\.\s*$"
_MARKER_HEAD = "Test Case '"
_MARKER_TRACK_FROM = len(_MARKER_HEAD) + 1
_MARKER_OPENER_RE = re.compile(r"' (?:started|passed|failed|skipped) \(")
_MARKER_OPENER_CARRY = 10  # the longest opener (11 characters) minus one
_MARKER_PLAIN_END_RE = re.compile(r"' (?:started|passed|failed|skipped)\.\Z")
_MARKER_END_CHARS = 16  # at least the longest plain end (10 characters)


class SegmentScanner:
    """Bounded streaming line classification of one over-cap record.

    For every ``str.splitlines`` segment of the record's complete decoded text,
    it reproduces ``SGR-strip, then str.strip()`` (``_SEGMENT_SGR_RE`` and
    whitespace as ``str.isspace``) without holding the record: leading and
    trailing whitespace and complete SGR sequences are discarded as they
    stream, and at most ``max_chars`` characters of stripped content are kept.
    ``classify(content, found)`` decides each completed segment's item
    (``None`` skips it): ``content`` is the exact stripped segment, or ``None``
    when it exceeds ``max_chars``; ``found`` holds the ``keywords`` that occur
    anywhere in the SGR-stripped segment (exact even when ``content`` is
    ``None``). Bytes are decoded incrementally with replacement, exactly like
    decoding the whole record at once.

    OD16 bounds fail the scanner instead of losing or reordering items:
    ``failure`` becomes ``"segment"`` when ``marker_shape`` is set and a
    segment over ``max_chars`` matches ``XCTEST_MARKER_PATTERN`` (such a
    segment never reaches ``classify``), or ``"pending"`` when more than
    ``max_pending_items`` items are held. A failed scanner holds no items and
    ignores further input.
    """

    def __init__(
        self,
        classify: Callable[[Optional[str], FrozenSet[str]], Any],
        keywords: Sequence[str],
        max_chars: int = SEGMENT_MAX_CHARS,
        marker_shape: bool = False,
        max_pending_items: int = SEGMENT_MAX_PENDING_ITEMS,
    ) -> None:
        self._classify = classify
        self._keywords = tuple(keywords)
        self._window_chars = max((len(keyword) for keyword in self._keywords), default=1) - 1
        self._max_chars = max_chars
        self._marker_shape = marker_shape
        self._max_pending = max_pending_items
        self.failure: Optional[str] = None
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._items: List[Any] = []
        self._reset_segment()

    def _reset_segment(self) -> None:
        self._carry = ""  # an open SGR candidate (``\x1b`` or ``\x1b[`` + parameters)
        self._carry_long = False  # its parameters exceed ``max_chars`` (not kept)
        self._started = False  # a non-whitespace character was seen
        self._content: List[str] = []
        self._content_chars = 0
        self._spaces = ""  # whitespace after the content (stripped unless more follows)
        self._spaces_long = False
        self._overflow = False
        self._window = ""
        self._found: set = set()
        # Marker shape (OD16): None (not a marker), "head" or "track".
        self._shape: Optional[str] = "head" if self._marker_shape else None
        self._shape_head = ""  # the first ``_MARKER_TRACK_FROM`` content characters
        self._shape_end = ""  # last characters of content through its last non-whitespace one
        self._shape_spaces = ""  # last characters of the whitespace after it
        self._run_tail = ""  # last characters since the last ")" (an opener may straddle pieces)
        self._run_opener = False  # an opener occurs since the last ")"
        self._closer_ok = False  # the run the last ")" closed held an opener

    def _fail(self, kind: str) -> None:
        self.failure = kind
        self._items = []
        self._reset_segment()

    def feed(self, data: bytes) -> None:
        if self.failure is not None:
            return
        self._feed_text(self._decoder.decode(data))

    @property
    def pending_items(self) -> int:
        return len(self._items)

    def take(self) -> List[Any]:
        items, self._items = self._items, []
        return items

    def finish(self) -> List[Any]:
        """End of the record: flush the decoder and the last segment."""
        if self.failure is None:
            self._feed_text(self._decoder.decode(b"", True))
        if self.failure is None:
            self._end_segment()
        return self.take()

    def _feed_text(self, text: str) -> None:
        start = 0
        for match in _SEGMENT_SEPARATOR_RE.finditer(text):
            if match.start() > start:
                self._feed_part(text[start:match.start()])
            self._end_segment()
            if self.failure is not None:
                return
            start = match.end()
        if start < len(text):
            self._feed_part(text[start:])

    def _feed_part(self, part: str) -> None:
        if self._carry_long:
            rest = part.lstrip(_SGR_PARAMETER_CHARS)
            if not rest:
                return
            self._carry = ""
            self._carry_long = False
            if rest[0] == "m":
                part = rest[1:]  # the long sequence was SGR: removed
            else:
                self._consume_long_literal()
                part = rest
            if not part:
                return
        elif self._carry:
            part = self._carry + part
            self._carry = ""
        open_tail = _SGR_OPEN_TAIL_RE.search(part) if "\x1b" in part else None
        if open_tail is not None:
            self._carry = part[open_tail.start():]
            part = part[:open_tail.start()]
            if len(self._carry) > self._max_chars + 2:
                self._carry = "\x1b["
                self._carry_long = True
        if "\x1b" in part:
            part = _SEGMENT_SGR_RE.sub("", part)
        self._consume(part)

    def _consume_long_literal(self) -> None:
        # An unterminated SGR candidate longer than ``max_chars`` is literal
        # content longer than the bound; it holds no keyword characters.
        self._started = True
        self._overflow = True
        self._content = []
        self._spaces = ""
        self._window = ""
        if self._shape == "head" and self._shape_head == _MARKER_HEAD:
            self._shape = "track"  # its ESC is the name's first character
        if self._shape == "head":
            self._shape = None  # the literal's ESC breaks the head
        elif self._shape == "track":
            # Its parameter characters hold no ")" and no opener character: the
            # current run continues, but no opener straddles it and no end matches.
            self._shape_end = "0"
            self._shape_spaces = ""
            self._run_tail = ""

    def _track_shape(self, text: str) -> None:
        """Content ``text`` (after the leading whitespace, SGR removed) for the marker shape."""
        if self._shape == "head":
            need = _MARKER_TRACK_FROM - len(self._shape_head)
            head = self._shape_head + text[:need]
            if not (head.startswith(_MARKER_HEAD) if len(head) > len(_MARKER_HEAD) else _MARKER_HEAD.startswith(head)):
                self._shape = None
                return
            self._shape_head = head
            if len(head) < _MARKER_TRACK_FROM:
                return
            self._shape = "track"
            text = text[need:]
            if not text:
                return
        body = text.rstrip()
        if body:
            self._shape_end = (self._shape_end + self._shape_spaces + body[-_MARKER_END_CHARS:])[-_MARKER_END_CHARS:]
            self._shape_spaces = text[len(body):][-_MARKER_END_CHARS:]
        else:
            self._shape_spaces = (self._shape_spaces + text)[-_MARKER_END_CHARS:]
        close = text.rfind(")")
        if close < 0:
            if not self._run_opener:
                self._run_opener = _MARKER_OPENER_RE.search(self._run_tail + text) is not None
            self._run_tail = (self._run_tail + text[-_MARKER_OPENER_CARRY:])[-_MARKER_OPENER_CARRY:]
            return
        previous = text.rfind(")", 0, close)
        if previous < 0:
            self._closer_ok = self._run_opener or _MARKER_OPENER_RE.search(self._run_tail + text[:close]) is not None
        else:
            self._closer_ok = _MARKER_OPENER_RE.search(text, previous + 1, close) is not None
        rest = text[close + 1:]
        self._run_opener = _MARKER_OPENER_RE.search(rest) is not None
        self._run_tail = rest[-_MARKER_OPENER_CARRY:]

    def _shape_is_marker(self) -> bool:
        end = self._shape_end
        if end.endswith(")."):
            return self._closer_ok
        return _MARKER_PLAIN_END_RE.search(end) is not None

    def _consume(self, text: str) -> None:
        if not text:
            return
        window = self._window + text
        for keyword in self._keywords:
            if keyword in window:
                self._found.add(keyword)
        self._window = window[-self._window_chars:] if self._window_chars else ""
        if self._overflow:
            if self._shape is not None:
                self._track_shape(text)
            return
        if not self._started:
            text = text.lstrip()
            if not text:
                return
            self._started = True
        if self._shape is not None:
            self._track_shape(text)
        content = text.rstrip()
        if content:
            if self._spaces_long or self._content_chars + len(self._spaces) + len(content) > self._max_chars:
                self._overflow = True
                self._content = []
                self._spaces = ""
                return
            if self._spaces:
                self._content.append(self._spaces)
            self._content.append(content)
            self._content_chars += len(self._spaces) + len(content)
            self._spaces = text[len(content):]
        elif not self._spaces_long:
            self._spaces += text
        if not self._spaces_long and self._content_chars + len(self._spaces) > self._max_chars:
            # More content after this whitespace could no longer fit.
            self._spaces = ""
            self._spaces_long = True

    def _end_segment(self) -> None:
        if self._carry_long:
            self._consume_long_literal()
        elif self._carry:
            self._consume(self._carry)  # an unterminated candidate is literal text
        found = frozenset(self._found)
        if self._overflow:
            if self._shape == "track" and self._shape_is_marker():
                self._fail("segment")
                return
            item = self._classify(None, found)
        elif self._content:
            item = self._classify("".join(self._content), found)
        else:
            item = None
        if item is not None:
            self._items.append(item)
            if len(self._items) > self._max_pending:
                self._fail("pending")
                return
        self._reset_segment()


def iter_file_texts(
    path: Path,
    chunk_bytes: int = READ_CHUNK_BYTES,
    over_cap: Optional[Callable[[str], Any]] = None,
    visible_chars: int = 0,
    visible_pattern: "re.Pattern[str]" = CSI_RE,
) -> Iterator[Any]:
    """Stream a raw log's record texts through the splitter (OSError propagates).

    With ``over_cap``, a record beyond the pending cap yields
    ``over_cap(visible)`` instead: the first ``visible_chars`` characters of
    the whole record with ``visible_pattern`` removed in one pass.
    """
    splitter = RecordSplitter(
        visible_chars=visible_chars if over_cap is not None else 0, visible_pattern=visible_pattern
    )
    with Path(path).open("rb") as handle:
        read = handle.read
        while True:
            chunk = read(chunk_bytes)
            if not chunk:
                break
            for record in splitter.feed(chunk, 0):
                yield over_cap(record[8]) if record[4] and over_cap is not None else record[2]
    for record in splitter.finish(0):
        yield over_cap(record[8]) if record[4] and over_cap is not None else record[2]


def tail_entry(text: str, terminated: bool = True) -> Tuple[str, int]:
    """One visible-tail entry and its UTF-8 size: ANSI-stripped, at most 4 KiB."""
    terminator = "\n" if terminated else ""
    if "\x1b" in text:
        text = ANSI_RE.sub("", text)
    elif text.isascii() and len(text) <= TAIL_ENTRY_MAX_BYTES - len(terminator):
        return text + terminator, len(text) + len(terminator)
    return visible_tail_entry(text, terminated)


def visible_tail_entry(text: str, terminated: bool = True) -> Tuple[str, int]:
    """``tail_entry`` of already ANSI-stripped text (never stripped again).

    For an over-cap record this is its ``visible`` prefix: at least
    ``TAIL_VISIBLE_CHARS`` characters when the whole stripped text is longer,
    so the 4 KiB cut and its ellipsis are those of the whole record.
    """
    terminator = "\n" if terminated else ""
    encoded = text.encode("utf-8", errors="replace")
    limit = TAIL_ENTRY_MAX_BYTES - len(terminator)
    if len(encoded) > limit:
        text = encoded[: limit - _ELLIPSIS_BYTES].decode("utf-8", errors="ignore") + TAIL_ELLIPSIS
        encoded = text.encode("utf-8", errors="replace")
    return text + terminator, len(encoded) + len(terminator)


def tail_entries(records: Sequence[OutputRecord]) -> List[Tuple[str, int]]:
    """Entries for the last ``TAIL_MAX_ENTRIES`` records (earlier ones would be evicted)."""
    entries: List[Tuple[str, int]] = []
    append = entries.append
    plain_limit = TAIL_ENTRY_MAX_BYTES - 1
    for record in records[-TAIL_MAX_ENTRIES:]:
        if record[4] and record[8] is not None:
            # Over cap: the whole record's visible prefix, not the kept bytes.
            append(visible_tail_entry(record[8], record[3] != "eof"))
            continue
        text = record[2]
        if record[3] != "eof" and len(text) <= plain_limit and text.isascii() and "\x1b" not in text:
            append((text + "\n", len(text) + 1))  # ``tail_entry``'s plain case, inlined
        else:
            append(tail_entry(text, record[3] != "eof"))
    return entries


def tail_entries_from_text(text: str) -> List[Tuple[str, int]]:
    """Entries for a complete text (system lines), split like process output."""
    if not text:
        return []
    parts = _SPLIT_TEXT_RE.split(text)
    last = parts.pop()
    entries = [tail_entry(part) for part in parts]
    if last:
        entries.append(tail_entry(last, terminated=False))
    return entries


_pair_entry = itemgetter(0)
_pair_size = itemgetter(1)


class OutputTail:
    """The visible job tail: at most ``max_entries`` entries and ``max_bytes`` bytes."""

    __slots__ = ("_entries", "_sizes", "_bytes", "max_entries", "max_bytes")

    def __init__(self, max_entries: int = TAIL_MAX_ENTRIES, max_bytes: int = TAIL_MAX_BYTES) -> None:
        # The entry bound is enforced by the deques themselves (in C).
        self._entries: deque[str] = deque(maxlen=max_entries)
        self._sizes: deque[int] = deque(maxlen=max_entries)
        self._bytes = 0
        self.max_entries = max_entries
        self.max_bytes = max_bytes

    def extend_sized(self, entries: Iterable[Tuple[str, int]]) -> None:
        pairs = entries if isinstance(entries, list) else list(entries)
        if not pairs:
            return
        self._entries.extend(map(_pair_entry, pairs))
        self._sizes.extend(map(_pair_size, pairs))
        total = sum(self._sizes)
        while total > self.max_bytes and self._entries:
            self._entries.popleft()
            total -= self._sizes.popleft()
        self._bytes = total

    def append_text(self, text: str) -> None:
        self.extend_sized(tail_entries_from_text(text))

    @property
    def byte_count(self) -> int:
        return self._bytes

    def __iter__(self) -> Iterator[str]:
        return iter(self._entries)

    def __len__(self) -> int:
        return len(self._entries)

    def __getitem__(self, index: int) -> str:
        return self._entries[index]

    def __repr__(self) -> str:
        return f"OutputTail({list(self._entries)!r})"


# A decoded character is at most 4 UTF-8 bytes, so this many characters of
# record text can never exceed ``BATCH_MAX_BYTES``; larger batches are measured
# exactly (a single larger record still forms its own batch).
_BATCH_SAFE_CHARS = BATCH_MAX_BYTES // 4
_record_text = itemgetter(2)


def utf8_size(text: str) -> int:
    return len(text) if text.isascii() else len(text.encode("utf-8"))


def record_batches(records: List[OutputRecord]) -> Iterator[List[OutputRecord]]:
    """Consecutive batches of at most ``BATCH_MAX_RECORDS`` records and ``BATCH_MAX_BYTES``
    UTF-8 bytes of record text, preserving order."""
    count = len(records)
    start = 0
    while start < count:
        end = min(count, start + BATCH_MAX_RECORDS)
        batch = records[start:end] if start or end < count else records
        if sum(map(len, map(_record_text, batch))) > _BATCH_SAFE_CHARS:
            size = 0
            end = start
            for record in batch:
                length = utf8_size(record[2])
                if end > start and size + length > BATCH_MAX_BYTES:
                    break
                size += length
                end += 1
            batch = records[start:end]
        yield batch
        start = end
