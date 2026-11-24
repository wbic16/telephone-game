# Test suite for libphext-julia (stdlib Test only).
# Run: julia --project=. test/runtests.jl [fixtures_dir]
# Fixtures: every input.phext under the fixtures dir must survive
# normalize() idempotently, and (nearly) all must phokenize/dephokenize
# round-trip byte-identically.
using Test

include(joinpath(@__DIR__, "..", "src", "Phext.jl"))
using .Phext
using .Phext: fetch  # explicit: shadows Base.fetch, which `using` skips
using .Phext: replace  # same for Base.replace

b(s::AbstractString) = Phext.text_to_bytes(s)
s(x::Vector{UInt8}) = Phext.bytes_to_text(x)
C(x::AbstractString) = Coordinate(x)

@testset "coordinate" begin
    @test string(C("1.2.3/4.5.6/7.8.9")) == "1.2.3/4.5.6/7.8.9"
    @test C("1.1.1/1.1.1/1.1.1") < C("1.1.1/1.1.1/1.1.2")
    @test C("1.1.1/1.1.1/1.1.9") < C("1.1.1/1.1.2/1.1.1")
    @test C("2.1.1/1.1.1/1.1.1") > C("1.9.9/9.9.9/9.9.9")
    @test C("1.1.1/1.1.1/1.1.1") == Phext.ROOT
    @test_throws ArgumentError C("0.1.1/1.1.1/1.1.1")
    @test_throws ArgumentError C("1.1/1.1.1/1.1.1")
end

@testset "phokenize" begin
    sc = phokenize(b("hello"))
    @test length(sc) == 1
    @test string(sc[1].coord) == "1.1.1/1.1.1/1.1.1"
    @test s(sc[1].text) == "hello"
    sc = phokenize(b("a\x17b\x17\x17c\nline2"))
    @test length(sc) == 3
    @test string(sc[2].coord) == "1.1.1/1.1.1/1.1.2"
    @test string(sc[3].coord) == "1.1.1/1.1.1/1.1.4"
    @test s(sc[3].text) == "c\nline2"  # newline is ordinary text
    sc = phokenize(b("x\x01y"))
    @test string(sc[2].coord) == "2.1.1/1.1.1/1.1.1"  # library break resets
    sc = phokenize(b("x\x18y"))
    @test string(sc[2].coord) == "1.1.1/1.1.1/1.2.1"  # section break
    @test isempty(phokenize(UInt8[]))
end

@testset "round trip" begin
    sample = b("alpha\x17beta\x18gamma\x01delta")
    @test dephokenize(phokenize(sample)) == sample
    built = dephokenize([Phext.PositionedScroll(C("1.1.1/1.1.1/1.1.2"), b("two")),
                         Phext.PositionedScroll(C("1.1.1/1.1.1/1.1.1"), b("one"))])
    @test s(built) == "one\x17two"
    @test normalize(normalize(b("\x17\x17lead"))) == normalize(b("\x17\x17lead"))
end

@testset "fetch / insert / replace / remove" begin
    buf = b("one\x17two\x17\x17four")
    @test s(fetch(buf, C("1.1.1/1.1.1/1.1.1"))) == "one"
    @test s(fetch(buf, C("1.1.1/1.1.1/1.1.4"))) == "four"
    @test s(fetch(buf, C("1.1.1/1.1.1/1.1.3"))) == ""   # gap -> ""
    @test s(fetch(buf, C("9.9.9/9.9.9/9.9.9"))) == ""   # far gap -> ""
    @test s(fetch(UInt8[], C("1.1.1/1.1.1/1.1.1"))) == ""

    out = insert(b("base"), C("1.1.1/1.1.1/1.1.1"), b("+more"))
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.1"))) == "base+more"  # existing first
    out = insert(UInt8[], C("1.1.1/1.1.1/1.1.3"), b("new"))
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.3"))) == "new"
    @test s(out) == "\x17\x17new"
    out = insert(b("a\x17c"), C("1.1.1/1.1.1/1.1.2"), b("b"))
    @test s(out) == "a\x17cb"  # insert at existing scroll merges
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.2"))) == "cb"

    out = replace(b("old\x17keep"), C("1.1.1/1.1.1/1.1.1"), b("new"))
    @test s(out) == "new\x17keep"
    out = replace(b("a"), C("1.1.1/1.1.1/1.1.5"), b("deep"))
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.5"))) == "deep"

    out = remove(b("a\x17b\x17c"), C("1.1.1/1.1.1/1.1.2"))
    @test s(out) == "a\x17\x17c"  # remove leaves a gap, no renumbering
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.2"))) == ""
    @test s(fetch(out, C("1.1.1/1.1.1/1.1.3"))) == "c"
    @test isempty(remove(b("only"), C("1.1.1/1.1.1/1.1.1")))
    @test s(remove(b("a"), C("5.5.5/5.5.5/5.5.5"))) == "a"
end

@testset "explode / implode" begin
    map = explode(b("x\x17y"))
    @test length(map) == 2
    @test s(implode(map)) == "x\x17y"
end

# Fixtures are checked outside @testset so the counts print either way.
fxdir = length(ARGS) >= 1 ? ARGS[1] :
        get(ENV, "PHEXT_FIXTURES", "")
if !isempty(fxdir) && isdir(fxdir)
    files, identical, idem = let files = 0, identical = 0, idem = 0
        for (root, _dirs, names) in walkdir(fxdir)
            for name in names
                endswith(name, "input.phext") || continue
                files += 1
                data = read(joinpath(root, name))
                dephokenize(phokenize(data)) == data && (identical += 1)
                n1 = normalize(data)
                normalize(n1) == n1 && (idem += 1)
            end
        end
        (files, identical, idem)
    end
    println("fixtures: $files input.phext, $identical byte-identical " *
            "round-trips, $idem normalize-idempotent")
    @test idem == files
    @test identical >= files - 2
else
    println("fixtures: skipped (no fixtures dir)")
end
