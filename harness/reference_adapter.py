#!/usr/bin/env python3
"""Harness reference implementation for Exocortical Stress Testing.

An independent phext implementation written from the format's break/advance
semantics (NOT a libphext port): raw bytes throughout, scroll runs found by
regex, canonical serialization by the advance algorithm. It plays and
cross-checks so the game always has a second pair of eyes. Labelled
honestly in the registry as kind=verifier.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adapter_base import Adapter, coord_str, parse_coord  # noqa: E402

BREAKS = b"\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"
BREAK_DIM = {b: d for d, b in enumerate(BREAKS)}
RUN = re.compile(rb"[^\x01\x17-\x1a\x1c-\x1f]+")


class ReferenceAdapter(Adapter):
    IMPL = "reference"

    def explode(self, data: bytes):
        out = {}
        coord = [1] * 9
        pos = 0
        for run in RUN.finditer(data):
            for i in range(pos, run.start()):
                d = BREAK_DIM[data[i]]
                coord[d] += 1
                for lower in range(d + 1, 9):
                    coord[lower] = 1
            out[tuple(coord)] = run.group()
            pos = run.end()
        return out

    def _advance(self, loc, target):
        loc = list(loc)
        if tuple(loc) >= tuple(target):
            return b"", loc
        dim = 0
        while loc[dim] == target[dim]:
            dim += 1
        parts = [bytes([BREAKS[dim]]) * (target[dim] - loc[dim])]
        loc = loc[:dim] + [target[dim]] + [1] * (8 - dim)
        for lower in range(dim + 1, 9):
            parts.append(bytes([BREAKS[lower]]) * (target[lower] - 1))
            loc[lower] = target[lower]
        return b"".join(parts), loc

    def implode(self, mapping):
        out = []
        loc = [1] * 9
        for coord in sorted(mapping):
            text = mapping[coord]
            if not text:
                continue
            adv, loc = self._advance(loc, coord)
            out.append(adv)
            out.append(text)
        return b"".join(out)

    def insert(self, data: bytes, coord, text: bytes) -> bytes:
        m = self.explode(data)
        if coord in m:
            raise ValueError("coordinate already occupied")
        m[coord] = text
        return self.implode(m)

    def fetch(self, data: bytes, coord) -> bytes:
        return self.explode(data).get(coord, b"")

    # ---- this implementation's own adventure ----
    def choose(self, state, position, turn):
        m = self.explode(state)
        pos = list(parse_coord(position))
        dim = turn % 9
        pos[dim] += 1
        while tuple(pos) in m:
            pos[8] += 1
        return {"op": "insert", "coordinate": coord_str(pos),
                "text": "reference placement %d" % turn}

    def elect(self, position, candidates, turn, placements):
        import hashlib
        return min(candidates,
                   key=lambda c: hashlib.sha256(
                       ("%d:%s" % (turn, c)).encode()).hexdigest())


if __name__ == "__main__":
    ReferenceAdapter().main()
