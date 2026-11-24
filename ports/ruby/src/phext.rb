# libphext-ruby — a Ruby port of libphext (0.6.1 parity).
#
# Semantics are normative from libphext-py: a phext is a byte buffer;
# nine dimension-break bytes walk a 9-component coordinate; scroll text
# is a maximal run of non-break bytes (newline 0x0A is ordinary text).
# Byte handling: all buffers are String with Encoding::BINARY, so
# control bytes and arbitrary byte sequences are never reinterpreted.
# The text convenience layer maps bytes to codepoints via latin-1
# (byte == codepoint), preserving byte identity.
module Phext
  # Dimension breaks in dimension order (library .. scroll).
  DIMENSION_BREAKS = [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17].freeze
  BREAK_DIM = DIMENSION_BREAKS.each_with_index.to_h.freeze

  # A phext coordinate: 9 components, each >= 1, ordered
  # lexicographically. String form: a.b.c/d.e.f/g.h.i
  class Coordinate
    include Comparable
    attr_reader :v

    def initialize(*parts)
      parts = parts.flatten
      raise ArgumentError, "coordinate needs 9 parts: #{parts.inspect}" unless parts.length == 9
      raise ArgumentError, "components must be >= 1: #{parts.inspect}" if parts.any? { |x| x < 1 }

      @v = parts.map(&:to_i).freeze
    end

    def self.parse(str)
      groups = str.strip.split('/')
      raise ArgumentError, "coordinate must be a.b.c/d.e.f/g.h.i: #{str}" unless groups.length == 3

      nums = groups.flat_map { |g| g.split('.').map { |p| Integer(p) } }
      new(nums)
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid coordinate: #{str}"
    end

    def self.root
      new([1] * 9)
    end

    def <=>(other)
      v <=> other.v
    end

    def ==(other)
      other.is_a?(Coordinate) && v == other.v
    end
    alias eql? ==

    def hash
      v.hash
    end

    # Apply a break at dimension d (0-based): increment component d,
    # reset all lower components to 1.
    def apply_break(d)
      out = v.dup
      out[d] += 1
      (d + 1...9).each { |lower| out[lower] = 1 }
      Coordinate.new(out)
    end

    def to_s
      "#{v[0]}.#{v[1]}.#{v[2]}/#{v[3]}.#{v[4]}.#{v[5]}/#{v[6]}.#{v[7]}.#{v[8]}"
    end
    alias inspect to_s
  end

  # A scroll of text (binary String) at a coordinate.
  PositionedScroll = Struct.new(:coord, :text)

  module_function

  # Bytes for step text under the game's latin-1 convention: codepoints
  # < 256 map to that byte; anything higher is UTF-8 encoded.
  def text_to_bytes(text)
    out = String.new(encoding: Encoding::BINARY)
    text.each_codepoint do |cp|
      if cp < 256
        out << cp
      else
        out << [cp].pack('U').b
      end
    end
    out
  end

  # String form of raw bytes under the latin-1 convention.
  def bytes_to_text(bytes)
    bytes.b.unpack('C*').pack('U*')
  end

  # phokenize: ordered list of PositionedScroll in +buffer+.
  def phokenize(buffer)
    buffer = buffer.b
    out = []
    coord = [1] * 9
    run = String.new(encoding: Encoding::BINARY)
    buffer.each_byte do |byte|
      d = BREAK_DIM[byte]
      if d.nil?
        run << byte
      else
        unless run.empty?
          out << PositionedScroll.new(Coordinate.new(coord.dup), run)
          run = String.new(encoding: Encoding::BINARY)
        end
        coord[d] += 1
        (d + 1...9).each { |lower| coord[lower] = 1 }
      end
    end
    out << PositionedScroll.new(Coordinate.new(coord.dup), run) unless run.empty?
    out
  end

  def advance(loc, target)
    # Mutates loc (9-array) up to target; returns emitted break bytes.
    return String.new(encoding: Encoding::BINARY) if (loc <=> target.v) >= 0

    dim = 0
    dim += 1 while loc[dim] == target.v[dim]
    out = String.new(encoding: Encoding::BINARY)
    out << ([DIMENSION_BREAKS[dim]] * (target.v[dim] - loc[dim])).pack('C*')
    loc[dim] = target.v[dim]
    (dim + 1...9).each { |lower| loc[lower] = 1 }
    (dim + 1...9).each do |lower|
      out << ([DIMENSION_BREAKS[lower]] * (target.v[lower] - 1)).pack('C*')
      loc[lower] = target.v[lower]
    end
    out
  end

  # dephokenize: canonical bytes — sorted coordinate order, advancing
  # from 1.1.1/1.1.1/1.1.1; empty scrolls contribute nothing.
  def dephokenize(stack)
    out = String.new(encoding: Encoding::BINARY)
    loc = [1] * 9
    stack.sort_by(&:coord).each do |ps|
      next if ps.text.empty?

      out << advance(loc, ps.coord)
      out << ps.text.b
    end
    out
  end

  # normalize = phokenize then dephokenize.
  def normalize(buffer)
    dephokenize(phokenize(buffer))
  end

  # fetch: text at +coord+, or "" for a gap coordinate (never a
  # control byte).
  def fetch(buffer, coord)
    phokenize(buffer).each do |ps|
      return ps.text if ps.coord == coord
    end
    String.new(encoding: Encoding::BINARY)
  end

  def update(buffer, coord, text, overwrite)
    result = []
    appended = false
    phokenize(buffer).each do |ps|
      if ps.coord > coord && !appended
        result << PositionedScroll.new(coord, text)
        appended = true
      end
      if ps.coord == coord && !appended
        merged = overwrite ? text : ps.text + text
        result << PositionedScroll.new(coord, merged)
        appended = true
        next
      end
      result << ps
    end
    result << PositionedScroll.new(coord, text) unless appended
    out = String.new(encoding: Encoding::BINARY)
    loc = [1] * 9
    result.each do |ps|
      out << advance(loc, ps.coord)
      out << ps.text.b
    end
    out
  end

  # insert: if a scroll exists at +coord+, the new text is the existing
  # text followed by the inserted text (libphext-py prepends the
  # existing scroll to the inserted one); otherwise create.
  def insert(buffer, coord, text)
    update(buffer, coord, text.b, false)
  end

  # replace: overwrite the scroll at +coord+.
  def replace(buffer, coord, text)
    update(buffer, coord, text.b, true)
  end

  # remove: replace with "" then normalize.
  def remove(buffer, coord)
    normalize(update(buffer, coord, String.new(encoding: Encoding::BINARY), true))
  end

  # explode: map form (Coordinate -> text).
  def explode(buffer)
    out = {}
    phokenize(buffer).each { |ps| out[ps.coord] = ps.text }
    out
  end

  # implode: canonical bytes from a Coordinate -> text map.
  def implode(map)
    dephokenize(map.map { |coord, text| PositionedScroll.new(coord, text) })
  end
end
