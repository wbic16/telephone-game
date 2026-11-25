--  Wire helpers for libphext-ada's hub CLI: SHA-256 (native, FIPS
--  180-4), Base64 (RFC 4648), a JSON parser, and the canonical JSON
--  serializer (sorted keys, "," / ":" separators, ensure_ascii
--  escaping) matching the telephone game's pinned formats.
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;

package Wire is

   function Sha256_Hex (Data : String) return String;
   function B64_Encode (Data : String) return String;
   function B64_Decode (S : String) return String;

   --  latin-1 convention for JSON text <-> phext bytes
   function Text_To_Bytes (S : String) return String;
   function Bytes_To_Text (Data : String) return String;

   type JKind is (JNull, JBool, JNum, JStr, JArr, JObj);
   type JVal is private;
   type JAccess is access JVal;

   function Parse_JSON (S : String) return JAccess;
   function Kind_Of (V : JAccess) return JKind;
   function As_Str (V : JAccess) return String;
   function As_Int (V : JAccess) return Long_Long_Integer;
   function As_Bool (V : JAccess) return Boolean;
   function Get (V : JAccess; Key : String) return JAccess;  --  null if absent
   function Get_Str (V : JAccess; Key : String;
                     Default : String := "") return String;
   function Get_Int (V : JAccess; Key : String;
                     Default : Long_Long_Integer := 0)
                     return Long_Long_Integer;
   function Arr_Len (V : JAccess) return Natural;
   function Arr_Item (V : JAccess; I : Natural) return JAccess;
   function Obj_Len (V : JAccess) return Natural;
   function Obj_Key (V : JAccess; I : Natural) return String;
   function Obj_Val (V : JAccess; I : Natural) return JAccess;

   function New_Obj return JAccess;
   function New_Str (S : String) return JAccess;
   function New_Int (N : Long_Long_Integer) return JAccess;
   function New_Null return JAccess;
   procedure Obj_Put (Obj : JAccess; Key : String; Val : JAccess);
   procedure Obj_Put_Str (Obj : JAccess; Key : String; Val : String);
   procedure Obj_Put_Int (Obj : JAccess; Key : String;
                          Val : Long_Long_Integer);

   function Canon (V : JAccess) return String;
   function Canon_Str (S : String) return String;

private
   package JVec is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => JAccess);
   package StrVec is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Unbounded_String);

   type JVal is record
      Kind     : JKind := JNull;
      Str      : Unbounded_String;
      Num      : Long_Long_Integer := 0;
      Num_Raw  : Unbounded_String;
      B        : Boolean := False;
      Items    : JVec.Vector;
      Keys     : StrVec.Vector;
      Vals     : JVec.Vector;
   end record;

end Wire;
