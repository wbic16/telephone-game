with Interfaces; use Interfaces;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Wire is

   ---------------- SHA-256 ----------------
   type U32_Array is array (Natural range <>) of Unsigned_32;
   K : constant U32_Array :=
     (16#428a2f98#, 16#71374491#, 16#b5c0fbcf#, 16#e9b5dba5#,
      16#3956c25b#, 16#59f111f1#, 16#923f82a4#, 16#ab1c5ed5#,
      16#d807aa98#, 16#12835b01#, 16#243185be#, 16#550c7dc3#,
      16#72be5d74#, 16#80deb1fe#, 16#9bdc06a7#, 16#c19bf174#,
      16#e49b69c1#, 16#efbe4786#, 16#0fc19dc6#, 16#240ca1cc#,
      16#2de92c6f#, 16#4a7484aa#, 16#5cb0a9dc#, 16#76f988da#,
      16#983e5152#, 16#a831c66d#, 16#b00327c8#, 16#bf597fc7#,
      16#c6e00bf3#, 16#d5a79147#, 16#06ca6351#, 16#14292967#,
      16#27b70a85#, 16#2e1b2138#, 16#4d2c6dfc#, 16#53380d13#,
      16#650a7354#, 16#766a0abb#, 16#81c2c92e#, 16#92722c85#,
      16#a2bfe8a1#, 16#a81a664b#, 16#c24b8b70#, 16#c76c51a3#,
      16#d192e819#, 16#d6990624#, 16#f40e3585#, 16#106aa070#,
      16#19a4c116#, 16#1e376c08#, 16#2748774c#, 16#34b0bcb5#,
      16#391c0cb3#, 16#4ed8aa4a#, 16#5b9cca4f#, 16#682e6ff3#,
      16#748f82ee#, 16#78a5636f#, 16#84c87814#, 16#8cc70208#,
      16#90befffa#, 16#a4506ceb#, 16#bef9a3f7#, 16#c67178f2#);

   function Hex8 (V : Unsigned_32) return String is
      Hexdigits : constant String := "0123456789abcdef";
      R : String (1 .. 8);
      X : Unsigned_32 := V;
   begin
      for I in reverse 1 .. 8 loop
         R (I) := Hexdigits (Integer (X and 16#F#) + 1);
         X := Shift_Right (X, 4);
      end loop;
      return R;
   end Hex8;

   function Sha256_Hex (Data : String) return String is
      H : U32_Array (0 .. 7) :=
        (16#6a09e667#, 16#bb67ae85#, 16#3c6ef372#, 16#a54ff53a#,
         16#510e527f#, 16#9b05688c#, 16#1f83d9ab#, 16#5be0cd19#);
      Bit_Len : constant Unsigned_64 :=
        Unsigned_64 (Data'Length) * 8;
      Padded_Len : constant Natural :=
        ((Data'Length + 9 + 63) / 64) * 64;
      Msg : String (1 .. Padded_Len) := (others => Character'Val (0));
      W : U32_Array (0 .. 63);
   begin
      Msg (1 .. Data'Length) := Data;
      Msg (Data'Length + 1) := Character'Val (16#80#);
      for I in 0 .. 7 loop
         Msg (Padded_Len - I) := Character'Val
           (Integer (Shift_Right (Bit_Len, I * 8) and 16#FF#));
      end loop;
      for Block in 0 .. Padded_Len / 64 - 1 loop
         for T in 0 .. 15 loop
            declare
               O : constant Natural := Block * 64 + T * 4;
            begin
               W (T) := Shift_Left
                 (Unsigned_32 (Character'Pos (Msg (O + 1))), 24) or
                 Shift_Left
                   (Unsigned_32 (Character'Pos (Msg (O + 2))), 16) or
                 Shift_Left
                   (Unsigned_32 (Character'Pos (Msg (O + 3))), 8) or
                 Unsigned_32 (Character'Pos (Msg (O + 4)));
            end;
         end loop;
         for T in 16 .. 63 loop
            declare
               S0 : constant Unsigned_32 :=
                 Rotate_Right (W (T - 15), 7) xor
                 Rotate_Right (W (T - 15), 18) xor
                 Shift_Right (W (T - 15), 3);
               S1 : constant Unsigned_32 :=
                 Rotate_Right (W (T - 2), 17) xor
                 Rotate_Right (W (T - 2), 19) xor
                 Shift_Right (W (T - 2), 10);
            begin
               W (T) := W (T - 16) + S0 + W (T - 7) + S1;
            end;
         end loop;
         declare
            A : Unsigned_32 := H (0);
            B : Unsigned_32 := H (1);
            C : Unsigned_32 := H (2);
            D : Unsigned_32 := H (3);
            E : Unsigned_32 := H (4);
            F : Unsigned_32 := H (5);
            G : Unsigned_32 := H (6);
            HH : Unsigned_32 := H (7);
         begin
            for T in 0 .. 63 loop
               declare
                  S1 : constant Unsigned_32 :=
                    Rotate_Right (E, 6) xor Rotate_Right (E, 11) xor
                    Rotate_Right (E, 25);
                  Ch : constant Unsigned_32 :=
                    (E and F) xor ((not E) and G);
                  T1 : constant Unsigned_32 :=
                    HH + S1 + Ch + K (T) + W (T);
                  S0 : constant Unsigned_32 :=
                    Rotate_Right (A, 2) xor Rotate_Right (A, 13) xor
                    Rotate_Right (A, 22);
                  Maj : constant Unsigned_32 :=
                    (A and B) xor (A and C) xor (B and C);
                  T2 : constant Unsigned_32 := S0 + Maj;
               begin
                  HH := G; G := F; F := E; E := D + T1;
                  D := C; C := B; B := A; A := T1 + T2;
               end;
            end loop;
            H (0) := H (0) + A; H (1) := H (1) + B;
            H (2) := H (2) + C; H (3) := H (3) + D;
            H (4) := H (4) + E; H (5) := H (5) + F;
            H (6) := H (6) + G; H (7) := H (7) + HH;
         end;
      end loop;
      return Hex8 (H (0)) & Hex8 (H (1)) & Hex8 (H (2)) & Hex8 (H (3)) &
             Hex8 (H (4)) & Hex8 (H (5)) & Hex8 (H (6)) & Hex8 (H (7));
   end Sha256_Hex;

   ---------------- Base64 ----------------
   B64_Chars : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   function B64_Encode (Data : String) return String is
      Out_S : Unbounded_String;
      I : Integer := Data'First;
      B0, B1, B2 : Integer;
   begin
      while I <= Data'Last loop
         B0 := Character'Pos (Data (I));
         if I + 1 <= Data'Last then
            B1 := Character'Pos (Data (I + 1));
         else
            B1 := -1;
         end if;
         if I + 2 <= Data'Last then
            B2 := Character'Pos (Data (I + 2));
         else
            B2 := -1;
         end if;
         Append (Out_S, B64_Chars (B0 / 4 + 1));
         if B1 < 0 then
            Append (Out_S, B64_Chars ((B0 mod 4) * 16 + 1));
            Append (Out_S, "==");
         else
            Append (Out_S, B64_Chars ((B0 mod 4) * 16 + B1 / 16 + 1));
            if B2 < 0 then
               Append (Out_S, B64_Chars ((B1 mod 16) * 4 + 1));
               Append (Out_S, "=");
            else
               Append (Out_S, B64_Chars ((B1 mod 16) * 4 + B2 / 64 + 1));
               Append (Out_S, B64_Chars (B2 mod 64 + 1));
            end if;
         end if;
         I := I + 3;
      end loop;
      return To_String (Out_S);
   end B64_Encode;

   function B64_Val (C : Character) return Integer is
   begin
      for I in B64_Chars'Range loop
         if B64_Chars (I) = C then
            return I - B64_Chars'First;
         end if;
      end loop;
      return -1;
   end B64_Val;

   function B64_Decode (S : String) return String is
      Out_S : Unbounded_String;
      Acc : Integer := 0;
      N_Bits : Integer := 0;
   begin
      for I in S'Range loop
         if S (I) = '=' then
            exit;
         end if;
         declare
            V : constant Integer := B64_Val (S (I));
         begin
            if V < 0 then
               goto Next;
            end if;
            Acc := Acc * 64 + V;
            N_Bits := N_Bits + 6;
            if N_Bits >= 8 then
               N_Bits := N_Bits - 8;
               Append (Out_S,
                       Character'Val ((Acc / (2 ** N_Bits)) mod 256));
               Acc := Acc mod (2 ** N_Bits);
            end if;
         end;
         <<Next>>
      end loop;
      return To_String (Out_S);
   end B64_Decode;

   ---------------- latin-1 text <-> bytes ----------------
   function UTF8_Decode_At (S : String; I : in out Integer)
                            return Natural
   is
      B : constant Natural := Character'Pos (S (I));
   begin
      if B < 16#80# then
         I := I + 1;
         return B;
      elsif B >= 16#F0# then
         declare
            CP : constant Natural :=
              (B mod 8) * 262144 +
              (Character'Pos (S (I + 1)) mod 64) * 4096 +
              (Character'Pos (S (I + 2)) mod 64) * 64 +
              (Character'Pos (S (I + 3)) mod 64);
         begin
            I := I + 4;
            return CP;
         end;
      elsif B >= 16#E0# then
         declare
            CP : constant Natural :=
              (B mod 16) * 4096 +
              (Character'Pos (S (I + 1)) mod 64) * 64 +
              (Character'Pos (S (I + 2)) mod 64);
         begin
            I := I + 3;
            return CP;
         end;
      else
         declare
            CP : constant Natural :=
              (B mod 32) * 64 + (Character'Pos (S (I + 1)) mod 64);
         begin
            I := I + 2;
            return CP;
         end;
      end if;
   end UTF8_Decode_At;

   function UTF8_Encode (CP : Natural) return String is
   begin
      if CP < 16#80# then
         return (1 => Character'Val (CP));
      elsif CP < 16#800# then
         return (Character'Val (16#C0# + CP / 64),
                 Character'Val (16#80# + CP mod 64));
      elsif CP < 16#10000# then
         return (Character'Val (16#E0# + CP / 4096),
                 Character'Val (16#80# + (CP / 64) mod 64),
                 Character'Val (16#80# + CP mod 64));
      else
         return (Character'Val (16#F0# + CP / 262144),
                 Character'Val (16#80# + (CP / 4096) mod 64),
                 Character'Val (16#80# + (CP / 64) mod 64),
                 Character'Val (16#80# + CP mod 64));
      end if;
   end UTF8_Encode;

   function Text_To_Bytes (S : String) return String is
      Out_S : Unbounded_String;
      I : Integer := S'First;
      CP : Natural;
   begin
      while I <= S'Last loop
         CP := UTF8_Decode_At (S, I);
         if CP < 256 then
            Append (Out_S, Character'Val (CP));
         else
            Append (Out_S, UTF8_Encode (CP));
         end if;
      end loop;
      return To_String (Out_S);
   end Text_To_Bytes;

   function Bytes_To_Text (Data : String) return String is
      Out_S : Unbounded_String;
   begin
      for I in Data'Range loop
         Append (Out_S, UTF8_Encode (Character'Pos (Data (I))));
      end loop;
      return To_String (Out_S);
   end Bytes_To_Text;

   ---------------- JSON parse ----------------
   type Parser is record
      S : Unbounded_String;
      I : Integer := 1;
   end record;

   procedure Skip_WS (P : in out Parser) is
      S : constant String := To_String (P.S);
   begin
      while P.I <= S'Length and then
        (S (P.I) = ' ' or else S (P.I) = Character'Val (9) or else
         S (P.I) = Character'Val (10) or else S (P.I) = Character'Val (13))
      loop
         P.I := P.I + 1;
      end loop;
   end Skip_WS;

   function Parse_Value (P : in out Parser) return JAccess;

   function Parse_String_Raw (P : in out Parser) return String is
      S : constant String := To_String (P.S);
      Out_S : Unbounded_String;
   begin
      --  S (P.I) = '"'
      P.I := P.I + 1;
      while P.I <= S'Length and then S (P.I) /= '"' loop
         if S (P.I) = '\' then
            P.I := P.I + 1;
            case S (P.I) is
               when 'n' => Append (Out_S, Character'Val (10));
               when 'r' => Append (Out_S, Character'Val (13));
               when 't' => Append (Out_S, Character'Val (9));
               when 'b' => Append (Out_S, Character'Val (8));
               when 'f' => Append (Out_S, Character'Val (12));
               when 'u' =>
                  declare
                     CP : Natural := 0;
                  begin
                     for K in 1 .. 4 loop
                        P.I := P.I + 1;
                        CP := CP * 16 +
                          (if S (P.I) in '0' .. '9' then
                              Character'Pos (S (P.I)) -
                              Character'Pos ('0')
                           elsif S (P.I) in 'a' .. 'f' then
                              Character'Pos (S (P.I)) -
                              Character'Pos ('a') + 10
                           else
                              Character'Pos (S (P.I)) -
                              Character'Pos ('A') + 10);
                     end loop;
                     if CP >= 16#D800# and then CP < 16#DC00# then
                        --  surrogate pair: \uXXXX follows
                        P.I := P.I + 2;  --  skip \ u
                        declare
                           Lo : Natural := 0;
                        begin
                           for K in 1 .. 4 loop
                              P.I := P.I + 1;
                              Lo := Lo * 16 +
                                (if S (P.I) in '0' .. '9' then
                                    Character'Pos (S (P.I)) -
                                    Character'Pos ('0')
                                 elsif S (P.I) in 'a' .. 'f' then
                                    Character'Pos (S (P.I)) -
                                    Character'Pos ('a') + 10
                                 else
                                    Character'Pos (S (P.I)) -
                                    Character'Pos ('A') + 10);
                           end loop;
                           CP := 16#10000# + (CP - 16#D800#) * 1024 +
                             (Lo - 16#DC00#);
                        end;
                     end if;
                     Append (Out_S, UTF8_Encode (CP));
                  end;
               when others => Append (Out_S, S (P.I));
            end case;
            P.I := P.I + 1;
         else
            Append (Out_S, S (P.I));
            P.I := P.I + 1;
         end if;
      end loop;
      P.I := P.I + 1;  --  closing quote
      return To_String (Out_S);
   end Parse_String_Raw;

   function Parse_Value (P : in out Parser) return JAccess is
      S : constant String := To_String (P.S);
      V : constant JAccess := new JVal;
   begin
      Skip_WS (P);
      if P.I > S'Length then
         return V;
      end if;
      case S (P.I) is
         when '{' =>
            V.Kind := JObj;
            P.I := P.I + 1;
            Skip_WS (P);
            if P.I <= S'Length and then S (P.I) = '}' then
               P.I := P.I + 1;
               return V;
            end if;
            loop
               Skip_WS (P);
               declare
                  Key : constant String := Parse_String_Raw (P);
               begin
                  Skip_WS (P);
                  P.I := P.I + 1;  --  ':'
                  V.Keys.Append (To_Unbounded_String (Key));
                  V.Vals.Append (Parse_Value (P));
               end;
               Skip_WS (P);
               exit when P.I > S'Length or else S (P.I) = '}';
               P.I := P.I + 1;  --  ','
            end loop;
            P.I := P.I + 1;
         when '[' =>
            V.Kind := JArr;
            P.I := P.I + 1;
            Skip_WS (P);
            if P.I <= S'Length and then S (P.I) = ']' then
               P.I := P.I + 1;
               return V;
            end if;
            loop
               V.Items.Append (Parse_Value (P));
               Skip_WS (P);
               exit when P.I > S'Length or else S (P.I) = ']';
               P.I := P.I + 1;
            end loop;
            P.I := P.I + 1;
         when '"' =>
            V.Kind := JStr;
            V.Str := To_Unbounded_String (Parse_String_Raw (P));
         when 't' =>
            V.Kind := JBool;
            V.B := True;
            P.I := P.I + 4;
         when 'f' =>
            V.Kind := JBool;
            V.B := False;
            P.I := P.I + 5;
         when 'n' =>
            V.Kind := JNull;
            P.I := P.I + 4;
         when others =>
            V.Kind := JNum;
            declare
               Start : constant Integer := P.I;
               Neg : Boolean := False;
               Acc : Long_Long_Integer := 0;
               Is_Float : Boolean := False;
            begin
               if S (P.I) = '-' then
                  Neg := True;
                  P.I := P.I + 1;
               end if;
               while P.I <= S'Length and then
                 (S (P.I) in '0' .. '9' or else S (P.I) = '.' or else
                  S (P.I) = 'e' or else S (P.I) = 'E' or else
                  S (P.I) = '+' or else S (P.I) = '-')
               loop
                  if S (P.I) in '0' .. '9' and then not Is_Float then
                     Acc := Acc * 10 +
                       Long_Long_Integer
                         (Character'Pos (S (P.I)) - Character'Pos ('0'));
                  else
                     Is_Float := True;
                  end if;
                  P.I := P.I + 1;
               end loop;
               if Neg then
                  Acc := -Acc;
               end if;
               if Is_Float then
                  --  coordinates/turns are integral in this protocol;
                  --  keep the raw text and truncate toward zero via
                  --  the integer part already accumulated.
                  null;
               end if;
               V.Num := Acc;
               V.Num_Raw := To_Unbounded_String (S (Start .. P.I - 1));
            end;
      end case;
      return V;
   end Parse_Value;

   function Parse_JSON (S : String) return JAccess is
      P : Parser := (S => To_Unbounded_String (S), I => 1);
   begin
      return Parse_Value (P);
   end Parse_JSON;

   ---------------- JSON accessors ----------------
   function Kind_Of (V : JAccess) return JKind is
   begin
      return V.Kind;
   end Kind_Of;

   function As_Str (V : JAccess) return String is
   begin
      if V = null then
         return "";
      elsif V.Kind = JStr then
         return To_String (V.Str);
      elsif V.Kind = JNum then
         return To_String (V.Num_Raw);
      end if;
      return "";
   end As_Str;

   function As_Int (V : JAccess) return Long_Long_Integer is
   begin
      if V = null then
         return 0;
      end if;
      return V.Num;
   end As_Int;

   function As_Bool (V : JAccess) return Boolean is
   begin
      return V /= null and then V.B;
   end As_Bool;

   function Get (V : JAccess; Key : String) return JAccess is
   begin
      if V = null or else V.Kind /= JObj then
         return null;
      end if;
      for I in 0 .. Natural (V.Keys.Length) - 1 loop
         if To_String (V.Keys (I)) = Key then
            return V.Vals (I);
         end if;
      end loop;
      return null;
   end Get;

   function Get_Str (V : JAccess; Key : String;
                     Default : String := "") return String
   is
      C : constant JAccess := Get (V, Key);
   begin
      if C = null then
         return Default;
      end if;
      return As_Str (C);
   end Get_Str;

   function Get_Int (V : JAccess; Key : String;
                     Default : Long_Long_Integer := 0)
                     return Long_Long_Integer
   is
      C : constant JAccess := Get (V, Key);
   begin
      if C = null then
         return Default;
      end if;
      return C.Num;
   end Get_Int;

   function Arr_Len (V : JAccess) return Natural is
   begin
      if V = null then
         return 0;
      end if;
      return Natural (V.Items.Length);
   end Arr_Len;

   function Arr_Item (V : JAccess; I : Natural) return JAccess is
   begin
      return V.Items (I);
   end Arr_Item;

   function Obj_Len (V : JAccess) return Natural is
   begin
      if V = null then
         return 0;
      end if;
      return Natural (V.Keys.Length);
   end Obj_Len;

   function Obj_Key (V : JAccess; I : Natural) return String is
   begin
      return To_String (V.Keys (I));
   end Obj_Key;

   function Obj_Val (V : JAccess; I : Natural) return JAccess is
   begin
      return V.Vals (I);
   end Obj_Val;

   function New_Obj return JAccess is
      V : constant JAccess := new JVal;
   begin
      V.Kind := JObj;
      return V;
   end New_Obj;

   function New_Str (S : String) return JAccess is
      V : constant JAccess := new JVal;
   begin
      V.Kind := JStr;
      V.Str := To_Unbounded_String (S);
      return V;
   end New_Str;

   function New_Int (N : Long_Long_Integer) return JAccess is
      V : constant JAccess := new JVal;
   begin
      V.Kind := JNum;
      V.Num := N;
      V.Num_Raw := To_Unbounded_String
        (Long_Long_Integer'Image (N));
      if Element (V.Num_Raw, 1) = ' ' then
         V.Num_Raw := To_Unbounded_String
           (Slice (V.Num_Raw, 2, Length (V.Num_Raw)));
      end if;
      return V;
   end New_Int;

   function New_Null return JAccess is
      V : constant JAccess := new JVal;
   begin
      V.Kind := JNull;
      return V;
   end New_Null;

   procedure Obj_Put (Obj : JAccess; Key : String; Val : JAccess) is
   begin
      Obj.Keys.Append (To_Unbounded_String (Key));
      Obj.Vals.Append (Val);
   end Obj_Put;

   procedure Obj_Put_Str (Obj : JAccess; Key : String; Val : String) is
   begin
      Obj_Put (Obj, Key, New_Str (Val));
   end Obj_Put_Str;

   procedure Obj_Put_Int (Obj : JAccess; Key : String;
                          Val : Long_Long_Integer) is
   begin
      Obj_Put (Obj, Key, New_Int (Val));
   end Obj_Put_Int;

   ---------------- canonical JSON ----------------
   function Canon_Str (S : String) return String is
      Out_S : Unbounded_String := To_Unbounded_String ("""");
      I : Integer := S'First;
      CP : Natural;
      Hex : constant String := "0123456789abcdef";
      function U4 (V : Natural) return String is
      begin
         return "\u" & Hex (V / 4096 + 1) & Hex ((V / 256) mod 16 + 1) &
           Hex ((V / 16) mod 16 + 1) & Hex (V mod 16 + 1);
      end U4;
   begin
      while I <= S'Last loop
         CP := UTF8_Decode_At (S, I);
         case CP is
            when 16#22# => Append (Out_S, "\""");
            when 16#5C# => Append (Out_S, "\\");
            when 16#0A# => Append (Out_S, "\n");
            when 16#0D# => Append (Out_S, "\r");
            when 16#09# => Append (Out_S, "\t");
            when 16#08# => Append (Out_S, "\b");
            when 16#0C# => Append (Out_S, "\f");
            when others =>
               if CP >= 16#20# and then CP < 16#7F# then
                  Append (Out_S, Character'Val (CP));
               elsif CP <= 16#FFFF# then
                  Append (Out_S, U4 (CP));
               else
                  declare
                     X : constant Natural := CP - 16#10000#;
                  begin
                     Append (Out_S, U4 (16#D800# + X / 1024));
                     Append (Out_S, U4 (16#DC00# + X mod 1024));
                  end;
               end if;
         end case;
      end loop;
      Append (Out_S, """");
      return To_String (Out_S);
   end Canon_Str;

   function Canon (V : JAccess) return String is
   begin
      if V = null then
         return "null";
      end if;
      case V.Kind is
         when JNull => return "null";
         when JBool => return (if V.B then "true" else "false");
         when JNum => return To_String (V.Num_Raw);
         when JStr => return Canon_Str (To_String (V.Str));
         when JArr =>
            declare
               Out_S : Unbounded_String := To_Unbounded_String ("[");
            begin
               for I in 0 .. Natural (V.Items.Length) - 1 loop
                  if I > 0 then
                     Append (Out_S, ",");
                  end if;
                  Append (Out_S, Canon (V.Items (I)));
               end loop;
               Append (Out_S, "]");
               return To_String (Out_S);
            end;
         when JObj =>
            declare
               Out_S : Unbounded_String := To_Unbounded_String ("{");
               N : constant Natural := Natural (V.Keys.Length);
               Order : array (0 .. Integer'Max (0, Integer (N) - 1)) of
                 Natural := (others => 0);
               Tmp : Natural;
            begin
               for I in 0 .. Integer (N) - 1 loop
                  Order (I) := Natural (I);
               end loop;
               for I in 1 .. Integer (N) - 1 loop
                  Tmp := Order (I);
                  declare
                     J : Integer := I - 1;
                  begin
                     while J >= 0 and then
                       To_String (V.Keys (Order (J))) >
                       To_String (V.Keys (Tmp))
                     loop
                        Order (J + 1) := Order (J);
                        J := J - 1;
                     end loop;
                     Order (J + 1) := Tmp;
                  end;
               end loop;
               for I in 0 .. Integer (N) - 1 loop
                  if I > 0 then
                     Append (Out_S, ",");
                  end if;
                  Append (Out_S,
                          Canon_Str (To_String (V.Keys (Order (I)))));
                  Append (Out_S, ":");
                  Append (Out_S, Canon (V.Vals (Order (I))));
               end loop;
               Append (Out_S, "}");
               return To_String (Out_S);
            end;
      end case;
   end Canon;

end Wire;
