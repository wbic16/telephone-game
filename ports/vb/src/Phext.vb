' Phext.vb - libphext port for Visual Basic (.NET) (0.6.1 parity
' semantics; normative reference: libphext-py). 9-dimensional
' plain-text format: scrolls addressed by a coordinate, separated by
' dimension-break bytes. Breaks (dim -> byte): 0 library 0x01,
' 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D, 4 volume 0x1C,
' 5 book 0x1A, 6 chapter 0x19, 7 section 0x18, 8 scroll 0x17.
' Newline is ordinary text. Coordinates are Integer(9), each >= 1.
' All operations are on Byte() (scroll text is bytes, never decoded).
Imports System.Linq
Imports System.Text

Public Class PositionedScroll
    Public Coord As Integer()
    Public Text As Byte()
    Public Sub New(c As Integer(), t As Byte())
        Coord = c
        Text = t
    End Sub
End Class

Public Module Phext
    Public ReadOnly Breaks As Integer() = {&H1, &H1F, &H1E, &H1D, &H1C, &H1A, &H19, &H18, &H17}

    Public Function BreakDim(b As Integer) As Integer
        For d As Integer = 0 To 8
            If Breaks(d) = b Then Return d
        Next
        Return -1
    End Function

    Public Function ParseCoordinate(s As String) As Integer()
        If s Is Nothing Then Return Nothing
        Dim groups = s.Trim().Split("/"c)
        If groups.Length <> 3 Then Return Nothing
        Dim parts As New List(Of Integer)()
        For Each g In groups
            For Each p In g.Split("."c)
                If p.Length = 0 Then Return Nothing
                For Each ch In p
                    If ch < "0"c OrElse ch > "9"c Then Return Nothing
                Next
                Dim n As Integer
                If Not Integer.TryParse(p, n) OrElse n < 1 Then Return Nothing
                parts.Add(n)
            Next
        Next
        If parts.Count <> 9 Then Return Nothing
        Return parts.ToArray()
    End Function

    Public Function FormatCoordinate(c As Integer()) As String
        Return String.Format("{0}.{1}.{2}/{3}.{4}.{5}/{6}.{7}.{8}",
                             c(0), c(1), c(2), c(3), c(4), c(5), c(6), c(7), c(8))
    End Function

    Public Function CompareCoord(a As Integer(), b As Integer()) As Integer
        For i As Integer = 0 To 8
            If a(i) <> b(i) Then Return If(a(i) < b(i), -1, 1)
        Next
        Return 0
    End Function

    Private Sub ApplyBreak(coord As Integer(), d As Integer)
        coord(d) += 1
        For k As Integer = d + 1 To 8
            coord(k) = 1
        Next
    End Sub

    Public Function Phokenize(buffer As Byte()) As List(Of PositionedScroll)
        Dim out As New List(Of PositionedScroll)()
        Dim walker As Integer() = {1, 1, 1, 1, 1, 1, 1, 1, 1}
        Dim i As Integer = 0
        While i < buffer.Length
            Dim d = BreakDim(buffer(i))
            If d >= 0 Then
                ApplyBreak(walker, d)
                i += 1
            Else
                Dim start = i
                While i < buffer.Length AndAlso BreakDim(buffer(i)) < 0
                    i += 1
                End While
                Dim text(i - start - 1) As Byte
                Array.Copy(buffer, start, text, 0, i - start)
                out.Add(New PositionedScroll(DirectCast(walker.Clone(), Integer()), text))
            End If
        End While
        Return out
    End Function

    Private Function Advance(loc As Integer(), target As Integer()) As Byte()
        Dim bytes As New List(Of Byte)()
        If CompareCoord(loc, target) >= 0 Then Return bytes.ToArray()
        Dim d As Integer = 0
        While loc(d) = target(d)
            d += 1
        End While
        For j As Integer = 1 To target(d) - loc(d)
            bytes.Add(CByte(Breaks(d)))
        Next
        Dim reached = DirectCast(loc.Clone(), Integer())
        reached(d) = target(d)
        For k As Integer = d + 1 To 8
            reached(k) = 1
        Next
        For lower As Integer = d + 1 To 8
            For j As Integer = 1 To target(lower) - 1
                bytes.Add(CByte(Breaks(lower)))
            Next
            reached(lower) = target(lower)
        Next
        Array.Copy(reached, loc, 9)
        Return bytes.ToArray()
    End Function

    Public Function Dephokenize(scrolls As List(Of PositionedScroll)) As Byte()
        Dim out As New List(Of Byte)()
        Dim loc As Integer() = {1, 1, 1, 1, 1, 1, 1, 1, 1}
        For Each ps In scrolls
            out.AddRange(Advance(loc, ps.Coord))
            out.AddRange(ps.Text)
        Next
        Return out.ToArray()
    End Function

    Public Function Normalize(buffer As Byte()) As Byte()
        Return Dephokenize(Phokenize(buffer))
    End Function

    Public Function Fetch(buffer As Byte(), coord As Integer()) As Byte()
        For Each ps In Phokenize(buffer)
            If CompareCoord(ps.Coord, coord) = 0 Then Return ps.Text
        Next
        Return New Byte() {}
    End Function

    Private Function Update(buffer As Byte(), coord As Integer(), text As Byte(), overwrite As Boolean) As Byte()
        Dim items = Phokenize(buffer)
        Dim nxt As New PositionedScroll(coord, text)
        Dim result As New List(Of PositionedScroll)()
        Dim appended = False
        For Each ps In items
            If Not appended AndAlso CompareCoord(ps.Coord, coord) > 0 Then
                result.Add(nxt)
                appended = True
            End If
            If Not appended AndAlso CompareCoord(ps.Coord, coord) = 0 Then
                If Not overwrite Then
                    Dim merged(ps.Text.Length + nxt.Text.Length - 1) As Byte
                    Array.Copy(ps.Text, merged, ps.Text.Length)
                    Array.Copy(nxt.Text, 0, merged, ps.Text.Length, nxt.Text.Length)
                    nxt = New PositionedScroll(coord, merged)
                End If
                result.Add(nxt)
                appended = True
                Continue For
            End If
            result.Add(ps)
        Next
        If Not appended Then result.Add(nxt)
        Return Dephokenize(result)
    End Function

    Public Function Insert(buffer As Byte(), coord As Integer(), text As Byte()) As Byte()
        Return Update(buffer, coord, text, False)
    End Function

    Public Function Replace(buffer As Byte(), coord As Integer(), text As Byte()) As Byte()
        Return Update(buffer, coord, text, True)
    End Function

    ' remove is COORDINATE-PRESERVING: the scroll becomes empty,
    ' delimiters stay, later scrolls do NOT shift.
    Public Function Remove(buffer As Byte(), coord As Integer()) As Byte()
        Return Normalize(Update(buffer, coord, New Byte() {}, True))
    End Function

    Public Function Explode(buffer As Byte()) As Dictionary(Of String, Byte())
        Dim map As New Dictionary(Of String, Byte())()
        For Each ps In Phokenize(buffer)
            map(FormatCoordinate(ps.Coord)) = ps.Text
        Next
        Return map
    End Function

    Public Function Implode(map As Dictionary(Of String, Byte())) As Byte()
        Dim scrolls As New List(Of PositionedScroll)()
        For Each kv In map
            Dim c = ParseCoordinate(kv.Key)
            If c IsNot Nothing Then scrolls.Add(New PositionedScroll(c, kv.Value))
        Next
        scrolls.Sort(Function(a, b) CompareCoord(a.Coord, b.Coord))
        Return Dephokenize(scrolls)
    End Function

    Public Function Utf8(s As String) As Byte()
        Return Encoding.UTF8.GetBytes(s)
    End Function

    Public Function FromUtf8(b As Byte()) As String
        Return Encoding.UTF8.GetString(b)
    End Function
End Module

' ---------- DynamicPhext: capacity-managed dynamic array ----------
Public Class DynamicPhext
    Private _data As PositionedScroll()
    Private _n As Integer
    Public Property Capacity As Integer
    Public Property ResizeCount As Integer
    Public Property ElementsCopied As Integer
    Private ReadOnly _shrinkDivisor As Integer

    Public Sub New(Optional buffer As Byte() = Nothing, Optional shrinkDivisor As Integer = 4)
        If shrinkDivisor < 2 Then Throw New ArgumentException("shrink_divisor must be >= 2")
        _shrinkDivisor = shrinkDivisor
        Capacity = 1
        _data = New PositionedScroll(0) {}
        _n = 0
        ResizeCount = 0
        ElementsCopied = 0
        If buffer IsNot Nothing AndAlso buffer.Length > 0 Then Load(buffer)
    End Sub

    Private Sub Resize(newCap As Integer)
        Dim nd = New PositionedScroll(newCap - 1) {}
        Array.Copy(_data, nd, _n)
        _data = nd
        Capacity = newCap
        ResizeCount += 1
        ElementsCopied += _n
    End Sub

    Private Sub GrowIfFull()
        If _n = Capacity Then Resize(2 * Capacity)
    End Sub

    Private Sub ShrinkIfSparse()
        If Capacity > 1 AndAlso _n <= Capacity \ _shrinkDivisor Then
            Resize(Math.Max(1, Capacity \ 2))
        End If
    End Sub

    Public Sub Load(buffer As Byte())
        Capacity = 1
        _data = New PositionedScroll(0) {}
        _n = 0
        ResizeCount = 0
        ElementsCopied = 0
        For Each ps In Phext.Phokenize(buffer)
            Push(ps)
        Next
    End Sub

    Private Sub Push(ps As PositionedScroll)
        GrowIfFull()
        _data(_n) = ps
        _n += 1
    End Sub

    Public Function Scrolls() As List(Of PositionedScroll)
        Dim out As New List(Of PositionedScroll)()
        For i As Integer = 0 To _n - 1
            out.Add(_data(i))
        Next
        Return out
    End Function

    Public Function Serialize() As Byte()
        Return Phext.Dephokenize(Scrolls())
    End Function

    Private Function Find(coord As Integer(), ByRef found As Boolean) As Integer
        Dim lo = 0, hi = _n
        While lo < hi
            Dim mid = (lo + hi) \ 2
            Dim c = Phext.CompareCoord(_data(mid).Coord, coord)
            If c < 0 Then
                lo = mid + 1
            ElseIf c > 0 Then
                hi = mid
            Else
                found = True
                Return mid
            End If
        End While
        found = False
        Return lo
    End Function

    Public Function Fetch(coord As Integer()) As Byte()
        Dim found As Boolean
        Dim idx = Find(coord, found)
        Return If(found, _data(idx).Text, New Byte() {})
    End Function

    Public Function Contains(coord As Integer()) As Boolean
        Dim found As Boolean
        Find(coord, found)
        Return found
    End Function

    Public ReadOnly Property Length As Integer
        Get
            Return _n
        End Get
    End Property

    Public Sub Append(coord As Integer(), text As Byte())
        If _n > 0 AndAlso Phext.CompareCoord(coord, _data(_n - 1).Coord) <= 0 Then
            Throw New ArgumentException("append requires a coordinate past the current tail")
        End If
        If text.Length = 0 Then Return
        Push(New PositionedScroll(coord, text))
    End Sub

    Private Sub RemoveAt(idx As Integer)
        For i As Integer = idx To _n - 2
            _data(i) = _data(i + 1)
        Next
        _n -= 1
        _data(_n) = Nothing
        ShrinkIfSparse()
    End Sub

    Public Sub Update(coord As Integer(), text As Byte(), overwrite As Boolean)
        Dim found As Boolean
        Dim idx = Find(coord, found)
        If found Then
            If text.Length = 0 Then
                If overwrite Then RemoveAt(idx)
                Return
            End If
            Dim t = text
            If Not overwrite Then
                Dim merged(_data(idx).Text.Length + text.Length - 1) As Byte
                Array.Copy(_data(idx).Text, merged, _data(idx).Text.Length)
                Array.Copy(text, 0, merged, _data(idx).Text.Length, text.Length)
                t = merged
            End If
            _data(idx) = New PositionedScroll(coord, t)
            Return
        End If
        If text.Length = 0 Then Return
        GrowIfFull()
        For i As Integer = _n To idx + 1 Step -1
            _data(i) = _data(i - 1)
        Next
        _data(idx) = New PositionedScroll(coord, text)
        _n += 1
    End Sub

    Public Sub Insert(coord As Integer(), text As Byte())
        Update(coord, text, False)
    End Sub

    Public Sub Replace(coord As Integer(), text As Byte())
        Update(coord, text, True)
    End Sub

    Public Sub Remove(coord As Integer())
        Dim found As Boolean
        Dim idx = Find(coord, found)
        If found Then RemoveAt(idx)
    End Sub
End Class

' ---------- TransitivePhext: branching hash map, depth 9 ----------
Public Class BranchNode
    Public Children As New Dictionary(Of Integer, BranchNode)()
    Public Leaf As Byte() = Nothing
    Public HasLeaf As Boolean = False
End Class

Public Class BranchingMap
    Public ReadOnly Depth As Integer
    Private ReadOnly _root As New BranchNode()
    Public Property Count As Integer

    Public Sub New(depth As Integer)
        If depth < 1 Then Throw New ArgumentException("depth must be >= 1")
        Me.Depth = depth
        Count = 0
    End Sub

    Public Function Fetch(key As Integer()) As Byte()
        Dim node = _root
        For level As Integer = 0 To Depth - 1
            Dim child As BranchNode = Nothing
            If Not node.Children.TryGetValue(key(level), child) Then Return Nothing
            If level = Depth - 1 Then Return If(child.HasLeaf, child.Leaf, Nothing)
            node = child
        Next
        Return Nothing
    End Function

    Public Function Put(key As Integer(), value As Byte()) As Boolean
        Dim node = _root
        For level As Integer = 0 To Depth - 1
            Dim child As BranchNode = Nothing
            If Not node.Children.TryGetValue(key(level), child) Then
                child = New BranchNode()
                node.Children(key(level)) = child
            End If
            If level = Depth - 1 Then
                Dim created = Not child.HasLeaf
                child.Leaf = value
                child.HasLeaf = True
                If created Then Count += 1
                Return created
            End If
            node = child
        Next
        Return False
    End Function

    Private Function RemoveRec(node As BranchNode, key As Integer(), level As Integer) As Boolean
        Dim child As BranchNode = Nothing
        If Not node.Children.TryGetValue(key(level), child) Then Return False
        If level = Depth - 1 Then
            If child.HasLeaf Then
                child.HasLeaf = False
                child.Leaf = Nothing
                Return True
            End If
            Return False
        End If
        Dim removed = RemoveRec(child, key, level + 1)
        If removed AndAlso child.Children.Count = 0 AndAlso Not child.HasLeaf Then
            node.Children.Remove(key(level))
        End If
        Return removed
    End Function

    Public Function Remove(key As Integer()) As Boolean
        Dim removed = RemoveRec(_root, key, 0)
        If removed Then Count -= 1
        Return removed
    End Function

    Private Sub ItemsRec(node As BranchNode, level As Integer, prefix As Integer(), res As List(Of PositionedScroll))
        Dim keys = node.Children.Keys.ToList()
        keys.Sort()
        For Each k In keys
            Dim child = node.Children(k)
            prefix(level) = k
            If level = Depth - 1 Then
                If child.HasLeaf Then
                    res.Add(New PositionedScroll(DirectCast(prefix.Clone(), Integer()), child.Leaf))
                End If
            Else
                ItemsRec(child, level + 1, prefix, res)
            End If
        Next
    End Sub

    Public Function Items() As List(Of PositionedScroll)
        Dim res As New List(Of PositionedScroll)()
        ItemsRec(_root, 0, New Integer(Depth - 1) {}, res)
        Return res
    End Function
End Class

Public Class TransitivePhext
    Private _map As BranchingMap

    Public Sub New(Optional buffer As Byte() = Nothing)
        _map = New BranchingMap(9)
        If buffer IsNot Nothing AndAlso buffer.Length > 0 Then Load(buffer)
    End Sub

    Public ReadOnly Property Depth As Integer
        Get
            Return _map.Depth
        End Get
    End Property

    Public Sub Load(buffer As Byte())
        _map = New BranchingMap(9)
        For Each ps In Phext.Phokenize(buffer)
            _map.Put(ps.Coord, ps.Text)
        Next
    End Sub

    Public Function Scrolls() As List(Of PositionedScroll)
        Return _map.Items()
    End Function

    Public Function Serialize() As Byte()
        Return Phext.Dephokenize(Scrolls())
    End Function

    Public Function Fetch(coord As Integer()) As Byte()
        Dim v = _map.Fetch(coord)
        Return If(v Is Nothing, New Byte() {}, v)
    End Function

    Public Function Contains(coord As Integer()) As Boolean
        Return _map.Fetch(coord) IsNot Nothing
    End Function

    Public ReadOnly Property Length As Integer
        Get
            Return _map.Count
        End Get
    End Property

    Public Sub Update(coord As Integer(), text As Byte(), overwrite As Boolean)
        If text.Length = 0 Then
            If overwrite Then _map.Remove(coord)
            Return
        End If
        Dim t = text
        If Not overwrite Then
            Dim ex = _map.Fetch(coord)
            If ex IsNot Nothing Then
                Dim merged(ex.Length + text.Length - 1) As Byte
                Array.Copy(ex, merged, ex.Length)
                Array.Copy(text, 0, merged, ex.Length, text.Length)
                t = merged
            End If
        End If
        _map.Put(coord, t)
    End Sub

    Public Sub Insert(coord As Integer(), text As Byte())
        Update(coord, text, False)
    End Sub

    Public Sub Replace(coord As Integer(), text As Byte())
        Update(coord, text, True)
    End Sub

    Public Sub Remove(coord As Integer())
        _map.Remove(coord)
    End Sub

    Public Sub Append(coord As Integer(), text As Byte())
        Insert(coord, text)
    End Sub
End Class
