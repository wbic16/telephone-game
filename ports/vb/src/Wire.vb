' Wire.vb - SHA-256 via System.Security.Cryptography, base64 via
' Convert, and a JSON model with canonical serialization (Python
' json.dumps sort_keys=True, separators=(",",":"), ensure_ascii=True).
Imports System.Linq
Imports System.Security.Cryptography
Imports System.Text
Imports System.Text.Json

Public MustInherit Class JVal
End Class

Public Class JNull
    Inherits JVal
    Public Shared ReadOnly Instance As New JNull()
End Class

Public Class JBool
    Inherits JVal
    Public Value As Boolean
    Public Sub New(v As Boolean)
        Value = v
    End Sub
End Class

Public Class JNum
    Inherits JVal
    Public LongValue As Long
    Public DoubleValue As Double
    Public IsLong As Boolean
    Public Sub New(v As Long)
        LongValue = v
        IsLong = True
    End Sub
    Public Sub New(v As Double)
        DoubleValue = v
        IsLong = False
    End Sub
End Class

Public Class JStr
    Inherits JVal
    Public Value As String
    Public Sub New(v As String)
        Value = v
    End Sub
End Class

Public Class JArr
    Inherits JVal
    Public Items As New List(Of JVal)()
End Class

Public Class JObj
    Inherits JVal
    Public Fields As New List(Of KeyValuePair(Of String, JVal))()
    Public Function GetField(key As String) As JVal
        For Each kv In Fields
            If kv.Key = key Then Return kv.Value
        Next
        Return JNull.Instance
    End Function
    Public Sub SetField(key As String, value As JVal)
        For i As Integer = 0 To Fields.Count - 1
            If Fields(i).Key = key Then
                Fields(i) = New KeyValuePair(Of String, JVal)(key, value)
                Return
            End If
        Next
        Fields.Add(New KeyValuePair(Of String, JVal)(key, value))
    End Sub
End Class

Public Module Wire
    Public Function Sha256Hex(data As Byte()) As String
        Using sha = SHA256.Create()
            Dim hash = sha.ComputeHash(data)
            Dim sb As New StringBuilder()
            For Each b In hash
                sb.Append(b.ToString("x2"))
            Next
            Return sb.ToString()
        End Using
    End Function

    Public Function B64Encode(data As Byte()) As String
        Return Convert.ToBase64String(data)
    End Function

    Public Function B64Decode(s As String) As Byte()
        If String.IsNullOrEmpty(s) Then Return New Byte() {}
        Return Convert.FromBase64String(s)
    End Function

    Public Function JStrOf(v As JVal) As String
        Dim s = TryCast(v, JStr)
        Return If(s IsNot Nothing, s.Value, "")
    End Function

    Public Function JIntOf(v As JVal) As Long
        Dim n = TryCast(v, JNum)
        If n Is Nothing Then Return 0
        Return If(n.IsLong, n.LongValue, CLng(n.DoubleValue))
    End Function

    Public Function ParseJson(text As String) As JVal
        Using doc = JsonDocument.Parse(text)
            Return FromElement(doc.RootElement)
        End Using
    End Function

    Private Function FromElement(el As JsonElement) As JVal
        Select Case el.ValueKind
            Case JsonValueKind.Null, JsonValueKind.Undefined
                Return JNull.Instance
            Case JsonValueKind.True
                Return New JBool(True)
            Case JsonValueKind.False
                Return New JBool(False)
            Case JsonValueKind.Number
                Dim l As Long
                If el.TryGetInt64(l) Then Return New JNum(l)
                Return New JNum(el.GetDouble())
            Case JsonValueKind.String
                Return New JStr(el.GetString())
            Case JsonValueKind.Array
                Dim arr As New JArr()
                For Each item In el.EnumerateArray()
                    arr.Items.Add(FromElement(item))
                Next
                Return arr
            Case JsonValueKind.Object
                Dim obj As New JObj()
                For Each prop In el.EnumerateObject()
                    obj.Fields.Add(New KeyValuePair(Of String, JVal)(prop.Name, FromElement(prop.Value)))
                Next
                Return obj
            Case Else
                Return JNull.Instance
        End Select
    End Function

    Private Sub CanonString(sb As StringBuilder, s As String)
        sb.Append(""""c)
        For Each r As Rune In s.EnumerateRunes()
            Dim cp = r.Value
            Select Case cp
                Case &H22
                    sb.Append("\""")
                Case &H5C
                    sb.Append("\\")
                Case &H8
                    sb.Append("\b")
                Case &HC
                    sb.Append("\f")
                Case &HA
                    sb.Append("\n")
                Case &HD
                    sb.Append("\r")
                Case &H9
                    sb.Append("\t")
                Case Else
                    If cp < &H20 OrElse cp > &H7E Then
                        If cp > &HFFFF Then
                            Dim v = cp - &H10000
                            sb.Append("\u" & (&HD800 + (v >> 10)).ToString("x4"))
                            sb.Append("\u" & (&HDC00 + (v And &H3FF)).ToString("x4"))
                        Else
                            sb.Append("\u" & cp.ToString("x4"))
                        End If
                    Else
                        sb.Append(r.ToString())
                    End If
            End Select
        Next
        sb.Append(""""c)
    End Sub

    Private Sub CanonInto(sb As StringBuilder, v As JVal)
        If TypeOf v Is JNull Then
            sb.Append("null")
        ElseIf TypeOf v Is JBool Then
            sb.Append(If(DirectCast(v, JBool).Value, "true", "false"))
        ElseIf TypeOf v Is JNum Then
            Dim n = DirectCast(v, JNum)
            If n.IsLong Then
                sb.Append(n.LongValue.ToString())
            ElseIf n.DoubleValue = Math.Floor(n.DoubleValue) Then
                sb.Append(CLng(n.DoubleValue).ToString())
            Else
                sb.Append(n.DoubleValue.ToString("R", Globalization.CultureInfo.InvariantCulture))
            End If
        ElseIf TypeOf v Is JStr Then
            CanonString(sb, DirectCast(v, JStr).Value)
        ElseIf TypeOf v Is JArr Then
            Dim arr = DirectCast(v, JArr)
            sb.Append("["c)
            For i As Integer = 0 To arr.Items.Count - 1
                If i > 0 Then sb.Append(","c)
                CanonInto(sb, arr.Items(i))
            Next
            sb.Append("]"c)
        ElseIf TypeOf v Is JObj Then
            Dim obj = DirectCast(v, JObj)
            Dim sorted = obj.Fields.OrderBy(Function(kv) kv.Key, StringComparer.Ordinal).ToList()
            sb.Append("{"c)
            For i As Integer = 0 To sorted.Count - 1
                If i > 0 Then sb.Append(","c)
                CanonString(sb, sorted(i).Key)
                sb.Append(":"c)
                CanonInto(sb, sorted(i).Value)
            Next
            sb.Append("}"c)
        End If
    End Sub

    Public Function Canon(v As JVal) As String
        Dim sb As New StringBuilder()
        CanonInto(sb, v)
        Return sb.ToString()
    End Function

    Public Function ObjOf(ParamArray fields As Object()) As JObj
        Dim obj As New JObj()
        For i As Integer = 0 To fields.Length - 1 Step 2
            obj.SetField(CStr(fields(i)), DirectCast(fields(i + 1), JVal))
        Next
        Return obj
    End Function
End Module
