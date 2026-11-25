// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Phext - libphext core semantics in Solidity (0.6.1 parity subset)
/// @notice A genuine implementation of the phext scroll operations in
/// Solidity itself: phokenize / dephokenize / fetch / insert / replace /
/// remove (coordinate-preserving) / normalize / explode-count over
/// `bytes`. Coordinates are uint256[9], each component >= 1.
/// Dimension breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F,
/// 2 series 0x1E, 3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A,
/// 6 chapter 0x19, 7 section 0x18, 8 scroll 0x17. Newline is text.
///
/// This contract exists as classification evidence for the Exocortical
/// Telephone Game (see ../README.md): the phext logic itself is
/// expressible in Solidity, but the adapter contract additionally
/// requires raw file I/O (seek), subprocess PGP (keygen/attest), and a
/// persistent stdin/stdout serve loop - none of which exist in the
/// EVM execution model (the EVM instruction set has no file, process,
/// or stream opcodes at all).
contract Phext {
    struct Scroll {
        uint256[9] coord;
        bytes text;
    }

    function breakByte(uint256 dim) internal pure returns (uint8) {
        if (dim == 0) return 0x01;
        if (dim == 1) return 0x1F;
        if (dim == 2) return 0x1E;
        if (dim == 3) return 0x1D;
        if (dim == 4) return 0x1C;
        if (dim == 5) return 0x1A;
        if (dim == 6) return 0x19;
        if (dim == 7) return 0x18;
        return 0x17;
    }

    function breakDim(uint8 b) internal pure returns (int256) {
        for (uint256 d = 0; d < 9; d++) {
            if (breakByte(d) == b) return int256(d);
        }
        return -1;
    }

    function compareCoord(uint256[9] memory a, uint256[9] memory b)
        internal
        pure
        returns (int256)
    {
        for (uint256 i = 0; i < 9; i++) {
            if (a[i] < b[i]) return -1;
            if (a[i] > b[i]) return 1;
        }
        return 0;
    }

    function applyBreak(uint256[9] memory coord, uint256 d) internal pure {
        coord[d] += 1;
        for (uint256 k = d + 1; k < 9; k++) {
            coord[k] = 1;
        }
    }

    function origin() internal pure returns (uint256[9] memory c) {
        for (uint256 i = 0; i < 9; i++) {
            c[i] = 1;
        }
    }

    function countRuns(bytes memory buffer) internal pure returns (uint256 n) {
        bool inRun = false;
        for (uint256 i = 0; i < buffer.length; i++) {
            if (breakDim(uint8(buffer[i])) >= 0) {
                inRun = false;
            } else if (!inRun) {
                inRun = true;
                n++;
            }
        }
    }

    function phokenize(bytes memory buffer) public pure returns (Scroll[] memory) {
        Scroll[] memory out = new Scroll[](countRuns(buffer));
        uint256[9] memory walker = origin();
        uint256 idx = 0;
        uint256 i = 0;
        while (i < buffer.length) {
            int256 d = breakDim(uint8(buffer[i]));
            if (d >= 0) {
                applyBreak(walker, uint256(d));
                i++;
            } else {
                uint256 start = i;
                while (i < buffer.length && breakDim(uint8(buffer[i])) < 0) {
                    i++;
                }
                bytes memory text = new bytes(i - start);
                for (uint256 j = 0; j < text.length; j++) {
                    text[j] = buffer[start + j];
                }
                out[idx].text = text;
                for (uint256 k = 0; k < 9; k++) {
                    out[idx].coord[k] = walker[k];
                }
                idx++;
            }
        }
        return out;
    }

    /// Number of break bytes `advance` would emit from loc to target.
    function advanceLength(uint256[9] memory loc, uint256[9] memory target)
        internal
        pure
        returns (uint256)
    {
        if (compareCoord(loc, target) >= 0) return 0;
        uint256 d = 0;
        while (loc[d] == target[d]) {
            d++;
        }
        uint256 n = target[d] - loc[d];
        for (uint256 lower = d + 1; lower < 9; lower++) {
            n += target[lower] - 1;
        }
        return n;
    }

    function dephokenize(Scroll[] memory scrolls) public pure returns (bytes memory) {
        uint256 total = 0;
        uint256[9] memory loc = origin();
        for (uint256 s = 0; s < scrolls.length; s++) {
            total += advanceLength(loc, scrolls[s].coord) + scrolls[s].text.length;
            // recompute loc := target after advancing
            if (compareCoord(loc, scrolls[s].coord) < 0) {
                uint256 d = 0;
                while (loc[d] == scrolls[s].coord[d]) {
                    d++;
                }
                loc[d] = scrolls[s].coord[d];
                for (uint256 k = d + 1; k < 9; k++) {
                    loc[k] = scrolls[s].coord[k];
                }
            }
        }
        bytes memory out = new bytes(total);
        uint256[9] memory walker = origin();
        uint256 pos = 0;
        for (uint256 s = 0; s < scrolls.length; s++) {
            if (compareCoord(walker, scrolls[s].coord) < 0) {
                uint256 d = 0;
                while (walker[d] == scrolls[s].coord[d]) {
                    d++;
                }
                for (uint256 r = 0; r < scrolls[s].coord[d] - walker[d]; r++) {
                    out[pos++] = bytes1(breakByte(d));
                }
                walker[d] = scrolls[s].coord[d];
                for (uint256 k = d + 1; k < 9; k++) {
                    walker[k] = 1;
                }
                for (uint256 lower = d + 1; lower < 9; lower++) {
                    for (uint256 r = 1; r < scrolls[s].coord[lower]; r++) {
                        out[pos++] = bytes1(breakByte(lower));
                    }
                    walker[lower] = scrolls[s].coord[lower];
                }
            }
            for (uint256 j = 0; j < scrolls[s].text.length; j++) {
                out[pos++] = scrolls[s].text[j];
            }
        }
        return out;
    }

    function normalize(bytes memory buffer) public pure returns (bytes memory) {
        return dephokenize(phokenize(buffer));
    }

    function fetch(bytes memory buffer, uint256[9] memory coord)
        public
        pure
        returns (bytes memory)
    {
        Scroll[] memory scrolls = phokenize(buffer);
        for (uint256 s = 0; s < scrolls.length; s++) {
            if (compareCoord(scrolls[s].coord, coord) == 0) {
                return scrolls[s].text;
            }
        }
        return new bytes(0);
    }

    function update(
        bytes memory buffer,
        uint256[9] memory coord,
        bytes memory text,
        bool overwrite
    ) internal pure returns (bytes memory) {
        Scroll[] memory items = phokenize(buffer);
        Scroll[] memory result = new Scroll[](items.length + 1);
        uint256 n = 0;
        bool placed = false;
        for (uint256 s = 0; s < items.length; s++) {
            int256 cmp = compareCoord(items[s].coord, coord);
            if (!placed && cmp > 0) {
                result[n].coord = coord;
                result[n].text = text;
                n++;
                placed = true;
            }
            if (!placed && cmp == 0) {
                result[n].coord = coord;
                if (overwrite) {
                    result[n].text = text;
                } else {
                    result[n].text = bytes.concat(items[s].text, text);
                }
                n++;
                placed = true;
            } else {
                result[n] = items[s];
                n++;
            }
        }
        if (!placed) {
            result[n].coord = coord;
            result[n].text = text;
            n++;
        }
        Scroll[] memory trimmed = new Scroll[](n);
        for (uint256 s = 0; s < n; s++) {
            trimmed[s] = result[s];
        }
        return dephokenize(trimmed);
    }

    function insert(bytes memory buffer, uint256[9] memory coord, bytes memory text)
        public
        pure
        returns (bytes memory)
    {
        return update(buffer, coord, text, false);
    }

    function replace(bytes memory buffer, uint256[9] memory coord, bytes memory text)
        public
        pure
        returns (bytes memory)
    {
        return update(buffer, coord, text, true);
    }

    /// remove is COORDINATE-PRESERVING: the scroll becomes empty, the
    /// delimiters stay, later scrolls do NOT shift.
    function remove(bytes memory buffer, uint256[9] memory coord)
        public
        pure
        returns (bytes memory)
    {
        return normalize(update(buffer, coord, new bytes(0), true));
    }
}
