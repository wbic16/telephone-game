// Hub-side CLI for libphext-scala (Exocortical Telephone Game,
// contract v2).
//
// Transport: with the argument `serve`, stdin carries one JSON
// request per line and stdout carries one JSON response per line.
// With no argument, stdin carries ONE JSON object and stdout ONE
// response. This CLI serves the four libphext hooks the local adapter
// (ports/scala/adapter, harness/adapter_base.py) plugs into its
// shared game machinery: explode / implode / insert / fetch. Requests
// carry phext state as base64 under "state" (v2) or "state_b64".
// Base64 and SHA-256 are the JDK's (java.util.Base64,
// java.security.MessageDigest); JSON is hand-written here (the Scala
// standard library has none).
package phext

import java.security.MessageDigest
import java.util.Base64 as JBase64
import scala.collection.mutable

object Json:
  // Parsed JSON: objects Map[String, Any], arrays List[Any], strings
  // String, numbers Long, true/false Boolean, null null.
  def parse(text: String): Any =
    val p = new Parser(text)
    p.skipWs()
    val v = p.value()
    p.skipWs()
    v

  private class Parser(text: String):
    var pos: Int = 0
    def skipWs(): Unit =
      while pos < text.length && " \t\n\r".contains(text(pos)) do pos += 1
    def peek: Char = text(pos)
    def next(): Char = { val c = text(pos); pos += 1; c }
    def expect(c: Char): Unit =
      val got = next()
      if got != c then throw new IllegalArgumentException(s"expected $c got $got")
    def value(): Any =
      skipWs()
      peek match
        case '{' => obj()
        case '[' => arr()
        case '"' => str()
        case 't' => literal("true", true)
        case 'f' => literal("false", false)
        case 'n' => literal("null", null)
        case _   => number()
    def literal(word: String, v: Any): Any =
      for ch <- word do expect(ch)
      v
    def obj(): Map[String, Any] =
      expect('{')
      skipWs()
      val out = mutable.LinkedHashMap.empty[String, Any]
      if peek == '}' then { next(); return out.toMap }
      var done = false
      while !done do
        skipWs()
        val key = str()
        skipWs()
        expect(':')
        out(key) = value()
        skipWs()
        next() match
          case '}' => done = true
          case ',' => ()
          case c   => throw new IllegalArgumentException(s"expected , or } got $c")
      out.toMap
    def arr(): List[Any] =
      expect('[')
      skipWs()
      val out = mutable.ListBuffer.empty[Any]
      if peek == ']' then { next(); return out.toList }
      var done = false
      while !done do
        out += value()
        skipWs()
        next() match
          case ']' => done = true
          case ',' => ()
          case c   => throw new IllegalArgumentException(s"expected , or ] got $c")
      out.toList
    def str(): String =
      expect('"')
      val out = new StringBuilder
      var done = false
      while !done do
        next() match
          case '"' => done = true
          case '\\' =>
            next() match
              case 'n' => out += '\n'
              case 'r' => out += '\r'
              case 't' => out += '\t'
              case 'b' => out += '\b'
              case 'f' => out += '\f'
              case 'u' =>
                val cp = Integer.parseInt(text.substring(pos, pos + 4), 16)
                pos += 4
                out += cp.toChar
              case c => out += c
          case c => out += c
      out.toString
    def number(): Long =
      val start = pos
      while pos < text.length && "-+0123456789.eE".contains(text(pos)) do
        pos += 1
      text.substring(start, pos).toLong

  def write(v: Any): String =
    val out = new StringBuilder
    writeInto(v, out)
    out.toString

  private def escape(s: String, out: StringBuilder): Unit =
    out += '"'
    for ch <- s do
      ch match
        case '"'  => out ++= "\\\""
        case '\\' => out ++= "\\\\"
        case '\n' => out ++= "\\n"
        case '\r' => out ++= "\\r"
        case '\t' => out ++= "\\t"
        case c if c < 0x20 => out ++= "\\u%04x".format(c.toInt)
        case c    => out += c
    out += '"'

  private def writeInto(v: Any, out: StringBuilder): Unit =
    v match
      case null      => out ++= "null"
      case b: Boolean => out ++= b.toString
      case n: Long   => out ++= n.toString
      case n: Int    => out ++= n.toString
      case s: String => escape(s, out)
      case m: Map[?, ?] =>
        out += '{'
        var first = true
        for (k, value) <- m do
          if !first then out += ','
          first = false
          escape(k.toString, out)
          out += ':'
          writeInto(value, out)
        out += '}'
      case xs: List[?] =>
        out += '['
        var first = true
        for x <- xs do
          if !first then out += ','
          first = false
          writeInto(x, out)
        out += ']'
      case other => throw new IllegalArgumentException(s"cannot write $other")

object Cli:
  val Impl = "scala"

  def sha256hex(bytes: Array[Byte]): String =
    MessageDigest.getInstance("SHA-256").digest(bytes)
      .map(b => "%02x".format(b & 0xff)).mkString

  def b64(bytes: Array[Byte]): String = JBase64.getEncoder.encodeToString(bytes)

  def stateOf(req: Map[String, Any]): Array[Byte] =
    val s = req.getOrElse("state", req("state_b64")).asInstanceOf[String]
    JBase64.getDecoder.decode(s)

  def dispatch(req: Map[String, Any]): Map[String, Any] =
    req("cmd").asInstanceOf[String] match
      case "id" => Map("impl" -> Impl)
      case "explode" =>
        val map = Phext.explode(stateOf(req))
        Map("map" -> map.map { case (c, t) => Phext.coordString(c) -> b64(t) })
      case "implode" =>
        val in = req("map").asInstanceOf[Map[String, Any]]
        val map = in.map { case (k, v) =>
          Phext.coordParse(k) -> JBase64.getDecoder.decode(v.asInstanceOf[String]) }
        val bytes = Phext.implode(map)
        Map("state_b64" -> b64(bytes), "state_sha256" -> sha256hex(bytes))
      case "insert" =>
        // Game insert (adapter_base hook semantics): unused coord only.
        val coord = Phext.coordParse(req("coordinate").asInstanceOf[String])
        val map = Phext.explode(stateOf(req))
        if map.contains(coord) then Map("error" -> "coordinate already occupied")
        else
          val bytes = Phext.implode(
            map + (coord -> JBase64.getDecoder.decode(
              req("text_b64").asInstanceOf[String])))
          Map("state_b64" -> b64(bytes), "state_sha256" -> sha256hex(bytes))
      case "fetch" =>
        val got = Phext.fetch(stateOf(req),
          Phext.coordParse(req("coordinate").asInstanceOf[String]))
        Map("text_b64" -> b64(got))
      case other => throw new IllegalArgumentException(s"unknown cmd $other")

  // Wire compression (see ports/scala/adapter): requests over
  // 64 KiB may arrive as {"gz_b64": "<base64 gzip of the request
  // JSON>"} and large responses are returned the same way. Gzip is
  // the JDK's java.util.zip.
  def gunzip(bytes: Array[Byte]): Array[Byte] =
    val in = new java.util.zip.GZIPInputStream(
      new java.io.ByteArrayInputStream(bytes))
    in.readAllBytes()

  def gzip(bytes: Array[Byte]): Array[Byte] =
    val buf = new java.io.ByteArrayOutputStream()
    val out = new java.util.zip.GZIPOutputStream(buf)
    out.write(bytes)
    out.close()
    buf.toByteArray

  def handle(line: String): String =
    try
      var req = Json.parse(line).asInstanceOf[Map[String, Any]]
      if req.contains("gz_b64") then
        val raw = JBase64.getDecoder.decode(
          req("gz_b64").asInstanceOf[String])
        req = Json.parse(new String(gunzip(raw), "UTF-8"))
          .asInstanceOf[Map[String, Any]]
      val resp = Json.write(dispatch(req))
      if resp.length > 65536 then
        Json.write(Map("gz_b64" -> b64(gzip(resp.getBytes("UTF-8")))))
      else resp
    catch
      case e: Exception =>
        Json.write(Map("error" -> String.valueOf(e.getMessage)))

  def main(args: Array[String]): Unit =
    if args.contains("serve") then
      var line = scala.io.StdIn.readLine()
      while line != null do
        if line.nonEmpty then
          println(handle(line))
          System.out.flush()
        line = scala.io.StdIn.readLine()
    else
      val text = scala.io.Source.stdin.mkString
      println(handle(text))
