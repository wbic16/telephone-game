' Test suite for the VB libphext port. Build/run via
' tests/run_tests.sh; fixtures via PHEXT_FIXTURES env.
Imports System.IO
Imports System.Text

Module TestPhext
    Private failures As Integer = 0

    Private Sub Check(cond As Boolean, name As String)
        If cond Then
            Console.WriteLine("ok - " & name)
        Else
            failures += 1
            Console.WriteLine("FAIL - " & name)
        End If
    End Sub

    Private Function C(s As String) As Integer()
        Dim parsed = Phext.ParseCoordinate(s)
        If parsed Is Nothing Then Throw New Exception("bad coord " & s)
        Return parsed
    End Function

    Private Function B(s As String) As Byte()
        Return Encoding.Latin1.GetBytes(s)
    End Function

    Private Function S(b As Byte()) As String
        Return Encoding.Latin1.GetString(b)
    End Function

    Sub Main()
        Check(Phext.FormatCoordinate(C("1.2.3/4.5.6/7.8.9")) = "1.2.3/4.5.6/7.8.9", "coordinate round trip")
        Check(Phext.ParseCoordinate("0.1.1/1.1.1/1.1.1") Is Nothing, "coordinate rejects 0")
        Check(Phext.ParseCoordinate("1.1.1/1.1.1") Is Nothing, "coordinate rejects short")
        Check(Phext.CompareCoord(C("1.1.1/1.1.1/1.1.9"), C("1.1.1/1.1.2/1.1.1")) = -1, "order: section beats scroll")
        Check(Phext.CompareCoord(C("2.1.1/1.1.1/1.1.1"), C("10.1.1/1.1.1/1.1.1")) = -1, "order: numeric not string")

        Dim buf = B("a" & ChrW(&H17) & "b" & ChrW(&H18) & "c" & ChrW(&H1) & "d")
        Dim scrolls = Phext.Phokenize(buf)
        Dim got As New List(Of String)()
        For Each ps In scrolls
            got.Add(Phext.FormatCoordinate(ps.Coord) & ":" & S(ps.Text))
        Next
        Check(String.Join(",", got) = "1.1.1/1.1.1/1.1.1:a,1.1.1/1.1.1/1.1.2:b,1.1.1/1.1.1/1.2.1:c,2.1.1/1.1.1/1.1.1:d", "phokenize breaks")
        Check(S(Phext.Dephokenize(scrolls)) = S(buf), "dephokenize round trip")
        Dim s1 = Phext.Phokenize(B("line1" & vbLf & "line2"))
        Check(s1.Count = 1 AndAlso S(s1(0).Text) = "line1" & vbLf & "line2", "newline is text")
        Check(Phext.Fetch(B("hello"), C("1.1.1/1.1.1/1.1.2")).Length = 0, "gap fetch is empty")
        Check(Phext.Fetch(B("hello"), C("9.9.9/9.9.9/9.9.9")).Length = 0, "far gap fetch is empty")
        Check(S(Phext.Fetch(B("hello"), C("1.1.1/1.1.1/1.1.1"))) = "hello", "fetch hit")
        buf = Phext.Insert(B("base"), C("1.1.1/1.1.1/1.1.1"), B("+more"))
        Check(S(Phext.Fetch(buf, C("1.1.1/1.1.1/1.1.1"))) = "base+more", "insert merges existing+inserted")
        buf = Phext.Insert(buf, C("1.1.1/1.1.1/1.1.3"), B("third"))
        Check(S(buf) = "base+more" & ChrW(&H17) & ChrW(&H17) & "third", "insert creates in canonical position")
        buf = Phext.Replace(B("a" & ChrW(&H17) & "b" & ChrW(&H17) & "c"), C("1.1.1/1.1.1/1.1.2"), B("B"))
        Check(S(buf) = "a" & ChrW(&H17) & "B" & ChrW(&H17) & "c", "replace overwrites")
        buf = Phext.Remove(buf, C("1.1.1/1.1.1/1.1.2"))
        Check(S(buf) = "a" & ChrW(&H17) & ChrW(&H17) & "c", "remove coordinate-preserving: c stays at scroll 3")
        Check(Phext.Fetch(buf, C("1.1.1/1.1.1/1.1.2")).Length = 0, "fetch after remove is empty")
        Check(S(Phext.Fetch(buf, C("1.1.1/1.1.1/1.1.3"))) = "c", "later scroll did NOT shift after remove")
        Check(S(Phext.Remove(buf, C("5.5.5/5.5.5/5.5.5"))) = S(buf), "remove gap is no-op")
        Dim m = Phext.Explode(B("x" & ChrW(&H17) & "y" & ChrW(&H1) & "z"))
        Check(m.Count = 3 AndAlso S(Phext.Implode(m)) = "x" & ChrW(&H17) & "y" & ChrW(&H1) & "z", "explode/implode round trip")

        Dim ops = {
            New String() {"insert", "1.1.1/1.1.1/1.1.1", "+X"},
            New String() {"insert", "1.1.1/1.1.1/1.1.3", "third"},
            New String() {"replace", "1.1.1/1.1.1/1.1.2", "B"},
            New String() {"remove", "1.1.1/1.1.1/1.1.1", ""},
            New String() {"insert", "2.1.1/1.1.1/1.1.1", "lib2"},
            New String() {"remove", "1.1.1/1.1.1/1.1.3", ""},
            New String() {"replace", "9.9.9/9.9.9/9.9.9", "far"},
            New String() {"insert", "1.1.1/1.1.1/1.1.2", "-tail"}
        }
        Dim dyn As New DynamicPhext(B("a" & ChrW(&H17) & "b"))
        Dim tra As New TransitivePhext(B("a" & ChrW(&H17) & "b"))
        Dim refr = B("a" & ChrW(&H17) & "b")
        For Each op In ops
            Dim cc = C(op(1))
            Select Case op(0)
                Case "insert"
                    dyn.Insert(cc, B(op(2))) : tra.Insert(cc, B(op(2))) : refr = Phext.Insert(refr, cc, B(op(2)))
                Case "replace"
                    dyn.Replace(cc, B(op(2))) : tra.Replace(cc, B(op(2))) : refr = Phext.Replace(refr, cc, B(op(2)))
                Case Else
                    dyn.Remove(cc) : tra.Remove(cc) : refr = Phext.Remove(refr, cc)
            End Select
            Dim want = Phext.Normalize(refr)
            Check(dyn.Serialize().SequenceEqual(want), "DynamicPhext serialize matches after " & op(0) & " " & op(1))
            Check(tra.Serialize().SequenceEqual(want), "TransitivePhext serialize matches after " & op(0) & " " & op(1))
            Check(dyn.Fetch(cc).SequenceEqual(Phext.Fetch(want, cc)), "DynamicPhext fetch matches after " & op(0) & " " & op(1))
            Check(tra.Fetch(cc).SequenceEqual(Phext.Fetch(want, cc)), "TransitivePhext fetch matches after " & op(0) & " " & op(1))
        Next
        Dim d2 As New DynamicPhext()
        For i As Integer = 1 To 20
            d2.Append(C("1.1.1/1.1.1/1.1." & i), B("s" & i))
        Next
        Check(d2.Length = 20 AndAlso d2.Capacity >= 20 AndAlso d2.Capacity < 40, "DynamicPhext capacity doubling (cap=" & d2.Capacity & ")")
        For i As Integer = 20 To 6 Step -1
            d2.Remove(C("1.1.1/1.1.1/1.1." & i))
        Next
        Check(d2.Length = 5, "DynamicPhext removals")
        Check(New TransitivePhext().Depth = 9, "TransitivePhext depth 9")

        Dim dir = Environment.GetEnvironmentVariable("PHEXT_FIXTURES")
        If Not String.IsNullOrEmpty(dir) Then
            Dim count = 0, identical = 0
            Dim paths = Directory.GetFiles(dir, "input.phext", SearchOption.AllDirectories)
            Array.Sort(paths)
            For Each path In paths
                Dim data = File.ReadAllBytes(path)
                count += 1
                If Phext.Dephokenize(Phext.Phokenize(data)).SequenceEqual(data) Then identical += 1
                Dim n1 = Phext.Normalize(data)
                Check(Phext.Normalize(n1).SequenceEqual(n1), "fixture normalize idempotent: " & path)
            Next
            Check(count > 0, "fixtures found (" & count & ")")
            Check(identical >= count - 2, "fixtures byte-identical round-trips (" & identical & "/" & count & ")")
        Else
            Console.WriteLine("skip - fixtures (PHEXT_FIXTURES not set)")
        End If

        Console.WriteLine(If(failures = 0, "PASS", "FAILURES: " & failures))
        Environment.Exit(If(failures = 0, 0, 1))
    End Sub
End Module
