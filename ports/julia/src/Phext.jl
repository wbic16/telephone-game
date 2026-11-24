# libphext-julia — a Julia port of libphext (0.6.1 parity).
#
# Semantics are normative from libphext-py: a phext is a byte buffer;
# nine dimension-break bytes walk a 9-component coordinate; scroll text
# is a maximal run of non-break bytes (newline 0x0A is ordinary text).
# All byte work is done on Vector{UInt8}; the string convenience layer
# uses latin-1 codepoints (byte == codepoint) so byte identity is
# never lost.
module Phext

export Coordinate, PositionedScroll, phokenize, dephokenize, fetch,
    insert, replace, remove, normalize, explode, implode, text_to_bytes,
    bytes_to_text, DIMENSION_BREAKS

"""Dimension breaks in dimension order (library .. scroll)."""
const DIMENSION_BREAKS = UInt8[0x01, 0x1f, 0x1e, 0x1d, 0x1c, 0x1a, 0x19, 0x18, 0x17]
const BREAK_DIM = Dict{UInt8,Int}(b => d for (d, b) in enumerate(DIMENSION_BREAKS))

"""
    Coordinate

A phext coordinate: 9 components, each >= 1, ordered lexicographically.
String form: `a.b.c/d.e.f/g.h.i`.
"""
struct Coordinate
    v::NTuple{9,Int}
    function Coordinate(v::NTuple{9,Int})
        any(x -> x < 1, v) &&
            throw(ArgumentError("coordinate components must all be >= 1: $v"))
        new(v)
    end
end

Coordinate(a, b, c, d, e, f, g, h, i) = Coordinate((a, b, c, d, e, f, g, h, i))
const ROOT = Coordinate(ntuple(_ -> 1, 9))

function Coordinate(s::AbstractString)
    groups = split(strip(s), '/')
    length(groups) == 3 ||
        throw(ArgumentError("coordinate must be a.b.c/d.e.f/g.h.i: $s"))
    nums = Int[]
    for g in groups, p in split(g, '.')
        push!(nums, parse(Int, p))
    end
    length(nums) == 9 ||
        throw(ArgumentError("coordinate must have exactly 9 parts: $s"))
    Coordinate(Tuple(nums))
end

Base.string(c::Coordinate) =
    "$(c.v[1]).$(c.v[2]).$(c.v[3])/$(c.v[4]).$(c.v[5]).$(c.v[6])/" *
    "$(c.v[7]).$(c.v[8]).$(c.v[9])"
Base.show(io::IO, c::Coordinate) = print(io, string(c))
Base.isless(a::Coordinate, b::Coordinate) = a.v < b.v
Base.:(==)(a::Coordinate, b::Coordinate) = a.v == b.v
Base.hash(c::Coordinate, h::UInt) = hash(c.v, h)

"""Apply a break at dimension `d` (1-based): increment component d and
reset all lower components to 1."""
function apply_break(c::Coordinate, d::Int)
    v = collect(c.v)
    v[d] += 1
    for lower in (d + 1):9
        v[lower] = 1
    end
    Coordinate(Tuple(v))
end

"""A scroll of text (raw bytes) at a coordinate."""
struct PositionedScroll
    coord::Coordinate
    text::Vector{UInt8}
end

"""Bytes for step `text` under the game's latin-1 convention: codepoints
< 256 map to that byte; anything higher is UTF-8 encoded."""
function text_to_bytes(text::AbstractString)
    out = UInt8[]
    for ch in text
        cp = Int(ch)
        if cp < 256
            push!(out, UInt8(cp))
        else
            append!(out, codeunits(string(ch)))
        end
    end
    out
end

"""String form of raw bytes under the latin-1 convention."""
bytes_to_text(bytes::Vector{UInt8}) = join(Char.(bytes))

"""phokenize: ordered list of (coordinate, text) scrolls in `buffer`."""
function phokenize(buffer::Vector{UInt8})
    out = PositionedScroll[]
    coord = ones(Int, 9)
    run = UInt8[]
    for byte in buffer
        d = get(BREAK_DIM, byte, 0)
        if d == 0
            push!(run, byte)
        else
            if !isempty(run)
                push!(out, PositionedScroll(Coordinate(Tuple(coord)), run))
                run = UInt8[]
            end
            coord[d] += 1
            for lower in (d + 1):9
                coord[lower] = 1
            end
        end
    end
    if !isempty(run)
        push!(out, PositionedScroll(Coordinate(Tuple(coord)), run))
    end
    out
end

function _advance!(loc::Vector{Int}, target::Coordinate)
    out = UInt8[]
    target.v <= Tuple(loc) && return out
    dim = 1
    while loc[dim] == target.v[dim]
        dim += 1
    end
    append!(out, fill(DIMENSION_BREAKS[dim], target.v[dim] - loc[dim]))
    loc[dim] = target.v[dim]
    for lower in (dim + 1):9
        loc[lower] = 1
    end
    for lower in (dim + 1):9
        append!(out, fill(DIMENSION_BREAKS[lower], target.v[lower] - 1))
        loc[lower] = target.v[lower]
    end
    out
end

"""dephokenize: canonical bytes for a scroll stack — sorted coordinate
order, advancing from 1.1.1/1.1.1/1.1.1; empty scrolls contribute
nothing."""
function dephokenize(stack::Vector{PositionedScroll})
    sorted = sort(stack, by = ps -> ps.coord)
    out = UInt8[]
    loc = ones(Int, 9)
    for ps in sorted
        isempty(ps.text) && continue
        append!(out, _advance!(loc, ps.coord))
        append!(out, ps.text)
    end
    out
end

"""normalize = phokenize then dephokenize (drops empties, canonical order)."""
normalize(buffer::Vector{UInt8}) = dephokenize(phokenize(buffer))

"""fetch: the text at `coord`, or empty bytes for a gap coordinate
(never a control byte)."""
function fetch(buffer::Vector{UInt8}, coord::Coordinate)
    for ps in phokenize(buffer)
        ps.coord == coord && return ps.text
    end
    UInt8[]
end

function _update(buffer::Vector{UInt8}, coord::Coordinate,
                 text::Vector{UInt8}, overwrite::Bool)
    items = phokenize(buffer)
    result = PositionedScroll[]
    appended = false
    for ps in items
        if ps.coord > coord && !appended
            push!(result, PositionedScroll(coord, text))
            appended = true
        end
        if ps.coord == coord && !appended
            merged = overwrite ? text : vcat(ps.text, text)
            push!(result, PositionedScroll(coord, merged))
            appended = true
            continue
        end
        push!(result, ps)
    end
    appended || push!(result, PositionedScroll(coord, text))
    out = UInt8[]
    loc = ones(Int, 9)
    for ps in result
        append!(out, _advance!(loc, ps.coord))
        append!(out, ps.text)
    end
    out
end

"""insert: if a scroll exists at `coord`, the new text is the existing
text followed by the inserted text (libphext-py prepends the existing
scroll to the inserted one); otherwise a scroll is created."""
insert(buffer, coord, text) = _update(buffer, coord, text, false)

"""replace: overwrite the scroll at `coord`."""
replace(buffer, coord, text) = _update(buffer, coord, text, true)

"""remove: replace with "" then normalize."""
remove(buffer, coord) = normalize(_update(buffer, coord, UInt8[], true))

"""explode: map form of `buffer` (coordinate -> text bytes)."""
function explode(buffer::Vector{UInt8})
    out = Dict{Coordinate,Vector{UInt8}}()
    for ps in phokenize(buffer)
        out[ps.coord] = ps.text
    end
    out
end

"""implode: canonical bytes from a coordinate -> text map."""
implode(map::Dict{Coordinate,Vector{UInt8}}) =
    dephokenize([PositionedScroll(k, v) for (k, v) in map])

end # module Phext
