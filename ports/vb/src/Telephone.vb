' Telephone.vb - Exocortical Telephone Game CLI (contract v2) for
' the Visual Basic libphext port. Wire: one JSON request in, one
' response out; arg "serve" loops over JSON lines. PGP via this
' language's own subprocess gpg calls (System.Diagnostics.Process),
' key home $TELEPHONE_GNUPG_HOME or ~/telephone-vb/gnupg.
Imports System.Diagnostics
Imports System.IO
Imports System.IO.Compression
Imports System.Text

Module Telephone
    Private Const Impl As String = "vb"
    Private Const KeyUid As String = "libphext telephone vb"
    Private Const IndexCoord As String = "1.1.1/1.1.1/1.1.1"
    Private Const KeysCoord As String = "1.1.1/1.1.1/1.1.2"
    Private Const KeysHashCoord As String = "1.1.1/1.1.1/1.1.3"
    Private ReadOnly Reserved As String() = {IndexCoord, KeysCoord, KeysHashCoord}

    Private Function StateBytes(req As JObj) As Byte()
        Dim s = JStrOf(req.GetField("state"))
        If s = "" Then s = JStrOf(req.GetField("state_b64"))
        Return B64Decode(s)
    End Function

    ' ---- gpg via subprocess ----
    Private Function GnupgHome() As String
        Dim e = Environment.GetEnvironmentVariable("TELEPHONE_GNUPG_HOME")
        If Not String.IsNullOrEmpty(e) Then Return e
        Return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                            "telephone-" & Impl, "gnupg")
    End Function

    Private Function RunProcess(fileName As String, args As List(Of String), Optional input As Byte() = Nothing) As Tuple(Of Integer, Byte())
        Dim psi As New ProcessStartInfo(fileName) With {
            .RedirectStandardInput = True,
            .RedirectStandardOutput = True,
            .RedirectStandardError = True,
            .UseShellExecute = False
        }
        For Each a In args
            psi.ArgumentList.Add(a)
        Next
        Using p = Process.Start(psi)
            If input IsNot Nothing Then
                p.StandardInput.BaseStream.Write(input, 0, input.Length)
            End If
            p.StandardInput.Close()
            Dim outMs As New MemoryStream()
            p.StandardOutput.BaseStream.CopyTo(outMs)
            Dim err = p.StandardError.ReadToEnd()
            p.WaitForExit()
            If p.ExitCode <> 0 Then
                Throw New IOException("process " & fileName & " failed: " & err)
            End If
            Return Tuple.Create(p.ExitCode, outMs.ToArray())
        End Using
    End Function

    Private Function RunGpg(args As List(Of String), Optional input As Byte() = Nothing) As Byte()
        Dim home = GnupgHome()
        Directory.CreateDirectory(home)
        Dim all As New List(Of String) From {"--batch", "--yes", "--pinentry-mode", "loopback",
                                            "--passphrase", "", "--homedir", home}
        all.AddRange(args)
        Return RunProcess("gpg", all, input).Item2
    End Function

    Private Function Keygen() As String
        Dim listing = Encoding.UTF8.GetString(RunGpg(New List(Of String) From {"--list-keys", "--with-colons"}))
        If Not listing.Contains("pub:") Then
            RunGpg(New List(Of String) From {"--quick-gen-key", KeyUid, "ed25519", "sign", "never"})
        End If
        Return Encoding.UTF8.GetString(RunGpg(New List(Of String) From {"--armor", "--export", KeyUid}))
    End Function

    Private Function DetachSign(data As Byte()) As String
        Dim dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName())
        Directory.CreateDirectory(dir)
        Try
            Dim descPath = Path.Combine(dir, "descriptor.json")
            Dim sigPath = Path.Combine(dir, "descriptor.asc")
            File.WriteAllBytes(descPath, data)
            RunGpg(New List(Of String) From {"--detach-sign", "--armor", "--local-user", KeyUid,
                                             "--output", sigPath, descPath})
            Return Encoding.UTF8.GetString(File.ReadAllBytes(sigPath))
        Finally
            Directory.Delete(dir, True)
        End Try
    End Function

    Private Function VerifySignature(pubkeys As String, data As Byte(), signature As Byte()) As Boolean
        Dim dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName())
        Dim home = Path.Combine(dir, "gnupg")
        Directory.CreateDirectory(home)
        Try
            Dim keysPath = Path.Combine(dir, "keys.asc")
            Dim descPath = Path.Combine(dir, "descriptor.json")
            Dim sigPath = Path.Combine(dir, "descriptor.asc")
            File.WriteAllBytes(keysPath, Encoding.UTF8.GetBytes(pubkeys))
            File.WriteAllBytes(descPath, data)
            File.WriteAllBytes(sigPath, signature)
            Try
                RunProcess("gpg", New List(Of String) From {"--batch", "--yes", "--homedir", home,
                                                            "--import", keysPath})
            Catch ex As IOException
                Return False
            End Try
            Try
                RunProcess("gpg", New List(Of String) From {"--batch", "--yes", "--homedir", home,
                                                            "--verify", sigPath, descPath})
            Catch ex As IOException
                Return False
            End Try
            Return True
        Finally
            Directory.Delete(dir, True)
        End Try
    End Function

    ' ---- game logic ----
    Private Function EchoValue(ping As JVal) As String
        Dim obj = TryCast(ping, JObj)
        Dim game = "", round = "", nonce = ""
        If obj IsNot Nothing Then
            game = JStrOf(obj.GetField("game"))
            Dim r = obj.GetField("round")
            If TypeOf r Is JNum Then round = JIntOf(r).ToString() Else round = JStrOf(r)
            If round = "" Then
                Dim t = obj.GetField("turn")
                If TypeOf t Is JNum Then round = JIntOf(t).ToString() Else round = JStrOf(t)
            End If
            nonce = JStrOf(obj.GetField("nonce"))
        End If
        Return Sha256Hex(Encoding.UTF8.GetBytes(Impl & "|" & game & "|" & round & "|" & nonce))
    End Function

    Private Function SeedByte(hex As String, i As Integer) As Integer
        Return Convert.ToInt32(hex.Substring(i * 2, 2), 16)
    End Function

    Private Function ElectWinner(position As String, candidates As List(Of String), turn As Long) As String
        Dim seed = position & ChrW(CInt(turn Mod 256)) & String.Join(",", candidates)
        Dim hex = Sha256Hex(Encoding.UTF8.GetBytes(seed))
        Return candidates(SeedByte(hex, 0) Mod candidates.Count)
    End Function

    Private Function NextCoord(c As Integer()) As Integer()
        Dim out = DirectCast(c.Clone(), Integer())
        For d As Integer = 8 To 0 Step -1
            If out(d) < 999 Then
                out(d) += 1
                Return out
            End If
            out(d) = 1
        Next
        Return out
    End Function

    Private Function ChooseAdventure(state As Byte(), position As String, turn As Long) As JVal
        Dim pos = Phext.ParseCoordinate(position)
        If pos Is Nothing Then Throw New ArgumentException("invalid position " & position)
        Dim used = Phext.Explode(state)
        For Each r In Reserved
            used(r) = New Byte() {0}
        Next
        Dim seedBytes = Phext.Utf8(position)
        Dim seedList As New List(Of Byte)(seedBytes)
        seedList.Add(CByte(turn Mod 256))
        seedList.AddRange(state)
        Dim hex = Sha256Hex(seedList.ToArray())
        Dim cand = DirectCast(pos.Clone(), Integer())
        Dim dIdx = SeedByte(hex, 1) Mod 9
        cand(dIdx) = (cand(dIdx) - 1 + 1 + (SeedByte(hex, 2) Mod 3)) Mod 999 + 1
        While used.ContainsKey(Phext.FormatCoordinate(cand))
            cand = NextCoord(cand)
        End While
        Dim cs = Phext.FormatCoordinate(cand)
        Return ObjOf("op", New JStr("insert"), "coordinate", New JStr(cs),
                     "text", New JStr(Impl & " turn " & turn.ToString() & " at " & cs))
    End Function

    Private Function ApplyStep(state As Byte(), stp As JObj) As Tuple(Of Byte(), JVal)
        Dim coord = Phext.ParseCoordinate(JStrOf(stp.GetField("coordinate")))
        If coord Is Nothing Then Return Tuple.Create(state, DirectCast(JNull.Instance, JVal))
        Dim text = Phext.Utf8(JStrOf(stp.GetField("text")))
        Select Case JStrOf(stp.GetField("op"))
            Case "insert"
                Return Tuple.Create(Phext.Insert(state, coord, text), DirectCast(JNull.Instance, JVal))
            Case "replace"
                Return Tuple.Create(Phext.Replace(state, coord, text), DirectCast(JNull.Instance, JVal))
            Case "remove"
                Return Tuple.Create(Phext.Remove(state, coord), DirectCast(JNull.Instance, JVal))
            Case "fetch"
                Return Tuple.Create(state, DirectCast(New JStr(Sha256Hex(Phext.Fetch(state, coord))), JVal))
            Case Else
                Return Tuple.Create(state, DirectCast(JNull.Instance, JVal))
        End Select
    End Function

    Private Function ValidateStep(newState As Byte(), stp As JObj, prior As Byte(), hasPrior As Boolean) As JVal
        Dim fail = Function(detail As String) ObjOf("impl", New JStr(Impl), "verdict", New JStr("fail"), "detail", New JStr(detail))
        If JStrOf(stp.GetField("op")) <> "insert" Then Return fail("step op is not insert")
        Dim coord = Phext.ParseCoordinate(JStrOf(stp.GetField("coordinate")))
        If coord Is Nothing Then Return fail("unparseable coordinate")
        If Not Phext.Fetch(newState, coord).SequenceEqual(Phext.Utf8(JStrOf(stp.GetField("text")))) Then
            Return fail("placed scroll absent or content differs at " & JStrOf(stp.GetField("coordinate")))
        End If
        If hasPrior Then
            If Phext.Fetch(prior, coord).Length <> 0 Then Return fail("coordinate was not unused in the prior state")
            Dim before = Phext.Explode(prior)
            Dim after = Phext.Explode(newState)
            If after.Count <> before.Count + 1 Then Return fail("scroll count did not grow by exactly one")
            For Each kv In before
                Dim v As Byte() = Nothing
                If Not after.TryGetValue(kv.Key, v) OrElse Not v.SequenceEqual(kv.Value) Then
                    Return fail("a prior scroll was overwritten: " & kv.Key)
                End If
            Next
            Return ObjOf("impl", New JStr(Impl), "verdict", New JStr("pass"),
                         "detail", New JStr("placed at unused coordinate; all prior scrolls intact"))
        End If
        Return ObjOf("impl", New JStr(Impl), "verdict", New JStr("pass"),
                     "detail", New JStr("placed scroll present with attested content (no prior state supplied)"))
    End Function

    ' ---- serve-mode validator cache (init / driver-form validate) ----
    Private CacheMap As Dictionary(Of String, Byte()) = Nothing

    Private Function InitCache(state As Byte()) As JVal
        CacheMap = Phext.Explode(state)
        Return ObjOf("impl", New JStr(Impl), "verdict", New JStr("pass"))
    End Function

    Private Function ValidateDriver(newState As Byte(), stp As JObj, eventCoordS As String, indexLine As String) As JVal
        Dim fail = Function(detail As String) ObjOf("impl", New JStr(Impl), "verdict", New JStr("fail"), "detail", New JStr(detail))
        If CacheMap Is Nothing Then Return fail("no prior state (init not called)")
        Dim newMap = Phext.Explode(newState)
        Dim coord = Phext.ParseCoordinate(JStrOf(stp.GetField("coordinate")))
        If coord Is Nothing Then Return fail("unparseable coordinate")
        Dim coordS = Phext.FormatCoordinate(coord)
        Dim placed As Byte() = Nothing
        If Not newMap.TryGetValue(coordS, placed) OrElse Not placed.SequenceEqual(Phext.Utf8(JStrOf(stp.GetField("text")))) Then
            Return fail("placed scroll missing or altered")
        End If
        For Each kv In CacheMap
            If kv.Key = IndexCoord Then Continue For
            Dim v As Byte() = Nothing
            If Not newMap.TryGetValue(kv.Key, v) OrElse Not v.SequenceEqual(kv.Value) Then
                Return fail("prior scroll overwritten at " & kv.Key)
            End If
        Next
        For Each c In newMap.Keys
            If Not CacheMap.ContainsKey(c) AndAlso c <> coordS AndAlso c <> eventCoordS Then
                Return fail("unexpected new scroll at " & c)
            End If
        Next
        Dim idxBytes As Byte() = Nothing
        Dim idx = If(newMap.TryGetValue(IndexCoord, idxBytes), Phext.FromUtf8(idxBytes), "")
        If Not idx.TrimEnd(ChrW(10)).EndsWith(indexLine.TrimEnd(ChrW(10))) Then
            Return fail("index does not record the placement")
        End If
        CacheMap = newMap
        Return ObjOf("impl", New JStr(Impl), "verdict", New JStr("pass"))
    End Function

    Private Function VerifyGame(state As Byte(), pubkeys As String) As JVal
        Dim fail = Function(msg As String, nChecked As Integer) ObjOf(
            "impl", New JStr(Impl), "verdict", New JStr("fail"),
            "placements_checked", New JNum(CLng(nChecked)),
            "first_failure", ObjOf("detail", New JStr(msg)))
        Dim scrolls = Phext.Explode(state)
        Dim keysBytes As Byte() = Nothing
        If Not scrolls.TryGetValue(KeysCoord, keysBytes) OrElse keysBytes.Length = 0 Then
            Return fail("no public-keys scroll at " & KeysCoord, 0)
        End If
        Dim keysText = Phext.FromUtf8(keysBytes)
        If pubkeys.Trim() <> keysText.Trim() Then
            Return fail("supplied pubkeys do not match the inscribed keys scroll", 0)
        End If
        Dim khBytes As Byte() = Nothing
        If Not scrolls.TryGetValue(KeysHashCoord, khBytes) Then
            Return fail("no keys-hash scroll at " & KeysHashCoord, 0)
        End If
        If Phext.FromUtf8(khBytes).Trim() <> Sha256Hex(keysBytes) Then
            Return fail("keys-hash scroll does not match the keys scroll", 0)
        End If
        Dim index As New Dictionary(Of String, Tuple(Of String, String, String))()
        Dim indexBytes As Byte() = Nothing
        Dim indexText = If(scrolls.TryGetValue(IndexCoord, indexBytes), Phext.FromUtf8(indexBytes), "")
        For Each rawLine In indexText.Split(ChrW(10))
            Dim line = rawLine.Trim()
            If line = "" OrElse line.StartsWith("#") Then Continue For
            Dim flds = line.Split(New Char() {" "c, ChrW(9)}, StringSplitOptions.RemoveEmptyEntries)
            If flds.Length <> 4 Then Return fail("malformed index line: " & line, 0)
            index(flds(1)) = Tuple.Create(flds(0), flds(2), flds(3))
        Next
        Dim checked = 0
        Dim seen As New Dictionary(Of String, Boolean)()
        Dim prevHash As String = Nothing
        Dim seq = 1
        While True
            Dim ecoord = Phext.FormatCoordinate(New Integer() {1, 1, 1, 1, 1, 1, 2, 1, seq})
            Dim evBytes As Byte() = Nothing
            If Not scrolls.TryGetValue(ecoord, evBytes) Then Exit While
            Dim ev As JVal
            Try
                ev = ParseJson(Phext.FromUtf8(evBytes))
            Catch ex As Exception
                Return fail("event " & seq & " is not a JSON object", checked)
            End Try
            Dim evObj = TryCast(ev, JObj)
            If evObj Is Nothing Then Return fail("event " & seq & " is not a JSON object", checked)
            Dim body = TryCast(evObj.GetField("body"), JObj)
            If body Is Nothing Then Return fail("event " & seq & " is not a JSON object", checked)
            If seq = 1 Then
                If Not TypeOf evObj.GetField("prev") Is JNull Then
                    Return fail("event 1 prev is not null", checked)
                End If
            Else
                Dim p = JStrOf(evObj.GetField("prev"))
                If p <> prevHash Then Return fail("event chain broken at seq " & seq, checked)
            End If
            prevHash = Sha256Hex(Encoding.UTF8.GetBytes(Canon(body)))
            If JStrOf(body.GetField("type")) = "placement" Then
                Dim coordStr = JStrOf(body.GetField("coord"))
                Dim textHash = JStrOf(body.GetField("text_sha256"))
                Dim fileHash = JStrOf(body.GetField("file_sha256"))
                Dim attB64 = JStrOf(body.GetField("att"))
                Dim turn = JIntOf(body.GetField("turn"))
                Dim actor = JStrOf(body.GetField("actor"))
                If coordStr = "" OrElse textHash = "" OrElse fileHash = "" OrElse attB64 = "" Then
                    Return fail("event " & seq & " lacks coord/text_sha256/file_sha256/att", checked)
                End If
                If seen.ContainsKey(coordStr) Then Return fail("coordinate reused at " & coordStr, checked)
                Dim placed As Byte() = Nothing
                If Not scrolls.TryGetValue(coordStr, placed) Then
                    Return fail("placement missing at " & coordStr, checked)
                End If
                If Sha256Hex(placed) <> textHash Then
                    Return fail("placement hash mismatch at " & coordStr, checked)
                End If
                Dim ie As Tuple(Of String, String, String) = Nothing
                If Not index.TryGetValue(coordStr, ie) OrElse ie.Item2 <> textHash OrElse
                   ie.Item1 <> turn.ToString() OrElse ie.Item3 <> actor Then
                    Return fail("index mismatch at " & coordStr, checked)
                End If
                Dim desc = ObjOf("turn", New JNum(turn), "coordinate", New JStr(coordStr),
                                 "scroll_sha256", New JStr(textHash), "file_sha256", New JStr(fileHash))
                Dim signature = B64Decode(attB64)
                If Not VerifySignature(pubkeys, Encoding.UTF8.GetBytes(Canon(desc)), signature) Then
                    Return fail("event " & seq & " signature invalid", checked)
                End If
                seen(coordStr) = True
                checked += 1
            End If
            seq += 1
        End While
        If checked = 0 Then Return fail("no placement events found", 0)
        For Each cs In index.Keys
            If Not seen.ContainsKey(cs) Then
                Return fail("index lists a placement with no event: " & cs, checked)
            End If
        Next
        Return ObjOf("impl", New JStr(Impl), "verdict", New JStr("pass"),
                     "placements_checked", New JNum(CLng(checked)),
                     "first_failure", JNull.Instance)
    End Function

    Private Function Handle(req As JObj) As JVal
        Dim cmd = JStrOf(req.GetField("cmd"))
        Select Case cmd
            Case "id"
                Return ObjOf("impl", New JStr(Impl))
            Case "echo"
                Return ObjOf("impl", New JStr(Impl), "echo", New JStr(EchoValue(req.GetField("ping"))))
            Case "elect"
                Dim cands As New List(Of String)()
                Dim arr = TryCast(req.GetField("candidates"), JArr)
                If arr IsNot Nothing Then
                    For Each c In arr.Items
                        cands.Add(JStrOf(c))
                    Next
                End If
                If cands.Count = 0 Then Throw New ArgumentException("elect: no candidates")
                Return ObjOf("elect", New JStr(ElectWinner(JStrOf(req.GetField("position")), cands,
                                                           JIntOf(req.GetField("turn")))))
            Case "choose"
                Return ChooseAdventure(StateBytes(req), JStrOf(req.GetField("position")),
                                       JIntOf(req.GetField("turn")))
            Case "apply"
                Dim res = ApplyStep(StateBytes(req), DirectCast(req.GetField("step"), JObj))
                Return ObjOf("state_b64", New JStr(B64Encode(res.Item1)),
                             "state_sha256", New JStr(Sha256Hex(res.Item1)),
                             "fetch_sha256", res.Item2)
            Case "keygen"
                Return ObjOf("impl", New JStr(Impl), "pubkey", New JStr(Keygen()))
            Case "attest"
                Dim sig = DetachSign(Encoding.UTF8.GetBytes(Canon(req.GetField("descriptor"))))
                Return ObjOf("signature", New JStr(sig))
            Case "init"
                Return InitCache(StateBytes(req))
            Case "validate"
                Dim evField = req.GetField("event_coord")
                If TypeOf evField Is JStr Then
                    Return ValidateDriver(StateBytes(req), DirectCast(req.GetField("step"), JObj),
                                          JStrOf(evField), JStrOf(req.GetField("index_line")))
                End If
                Dim priorField = req.GetField("prior_state")
                Dim hasPrior = TypeOf priorField Is JStr
                Dim prior = If(hasPrior, B64Decode(JStrOf(priorField)), New Byte() {})
                Return ValidateStep(StateBytes(req), DirectCast(req.GetField("step"), JObj), prior, hasPrior)
            Case "verify"
                Return VerifyGame(StateBytes(req), JStrOf(req.GetField("pubkeys")))
            Case Else
                Throw New ArgumentException("unknown cmd " & cmd)
        End Select
    End Function

    ' Game-scale framing (2026-11-24): lines over 8 KB may arrive
    ' gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh
    ' channel is ~25-70 KB/s and raw base64 state lines took minutes
    ' at 1,000 placements. Lossless; plain lines unchanged.
    Private Function GzUnframe(s As String) As String
        Dim raw = Convert.FromBase64String(s.Substring(4))
        Using msIn As New MemoryStream(raw),
              gz As New GZipStream(msIn, CompressionMode.Decompress),
              msOut As New MemoryStream()
            gz.CopyTo(msOut)
            Return Encoding.UTF8.GetString(msOut.ToArray())
        End Using
    End Function

    Private Function GzFrame(s As String) As String
        Dim bytes = Encoding.UTF8.GetBytes(s)
        Using msOut As New MemoryStream()
            Using gz As New GZipStream(msOut, CompressionMode.Compress, True)
                gz.Write(bytes, 0, bytes.Length)
            End Using
            Return "GZ1:" & Convert.ToBase64String(msOut.ToArray())
        End Using
    End Function

    Sub Main(args As String())
        If args.Length > 0 AndAlso args(0) = "serve" Then
            Dim line As String
            line = Console.ReadLine()
            While line IsNot Nothing
                If line.Trim() <> "" Then
                    Dim lineIn = line.Trim()
                    If lineIn.StartsWith("GZ1:") Then lineIn = GzUnframe(lineIn)
                    Dim out As JVal
                    Try
                        out = Handle(DirectCast(ParseJson(lineIn), JObj))
                    Catch ex As Exception
                        out = ObjOf("error", New JStr(ex.GetType().Name & ": " & ex.Message))
                    End Try
                    Dim outs = Canon(out)
                    If outs.Length > 8192 Then outs = GzFrame(outs)
                    Console.Out.Write(outs & vbLf)
                    Console.Out.Flush()
                End If
                line = Console.ReadLine()
            End While
        Else
            Dim raw = Console.In.ReadToEnd()
            Dim req = DirectCast(ParseJson(raw), JObj)
            Console.Out.Write(Canon(Handle(req)) & vbLf)
        End If
    End Sub
End Module
