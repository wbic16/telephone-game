with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Interfaces;

package body Phext with SPARK_Mode => On is

   Dim_Breaks : constant array (0 .. 8) of Character :=
     (Character'Val (1), Character'Val (31), Character'Val (30),
      Character'Val (29), Character'Val (28), Character'Val (26),
      Character'Val (25), Character'Val (24), Character'Val (23));

   function Break_Dim (B : Character) return Integer is
   begin
      for D in 0 .. 8 loop
         if Dim_Breaks (D) = B then
            return D;
         end if;
      end loop;
      return -1;
   end Break_Dim;

   function Root_Coord return Coord is
   begin
      return (others => 1);
   end Root_Coord;

   function Coord_Str (C : Coord) return String is
      function N (V : Long_Long_Integer) return String is
         S : constant String := Long_Long_Integer'Image (V);
      begin
         if S (S'First) = ' ' then
            return S (S'First + 1 .. S'Last);
         end if;
         return S;
      end N;
   begin
      return N (C (0)) & "." & N (C (1)) & "." & N (C (2)) & "/" &
             N (C (3)) & "." & N (C (4)) & "." & N (C (5)) & "/" &
             N (C (6)) & "." & N (C (7)) & "." & N (C (8));
   end Coord_Str;

   function Parse_Coord (S : String) return Coord is
      R : Coord;
      N : Natural := 0;
      I : Integer := S'First;
      Num : Long_Long_Integer;
   begin
      while I <= S'Last loop
         Num := 0;
         if I > S'Last or else S (I) not in '0' .. '9' then
            raise Constraint_Error with "invalid coordinate: " & S;
         end if;
         while I <= S'Last and then S (I) in '0' .. '9' loop
            Num := Num * 10 +
              Long_Long_Integer (Character'Pos (S (I)) -
                                 Character'Pos ('0'));
            I := I + 1;
         end loop;
         if N > 8 or else Num < 1 then
            raise Constraint_Error with "invalid coordinate: " & S;
         end if;
         R (Integer (N)) := Num;
         N := N + 1;
         if I <= S'Last then
            if S (I) /= '.' and then S (I) /= '/' then
               raise Constraint_Error with "invalid coordinate: " & S;
            end if;
            I := I + 1;
         end if;
      end loop;
      if N /= 9 then
         raise Constraint_Error with "invalid coordinate: " & S;
      end if;
      return R;
   end Parse_Coord;

   function Coord_Cmp (A, B : Coord) return Integer is
   begin
      for I in 0 .. 8 loop
         if A (I) < B (I) then
            return -1;
         elsif A (I) > B (I) then
            return 1;
         end if;
      end loop;
      return 0;
   end Coord_Cmp;

   procedure Apply_Break (C : in out Coord; D : Integer) is
   begin
      C (D) := C (D) + 1;
      for K in D + 1 .. 8 loop
         C (K) := 1;
      end loop;
   end Apply_Break;

   function Phokenize (Buf : String) return Scroll_List is
      Out_List : Scroll_List;
      C : Coord := Root_Coord;
      Run_Start : Integer := Buf'First;
      D : Integer;
   begin
      for I in Buf'Range loop
         D := Break_Dim (Buf (I));
         if D >= 0 then
            if I > Run_Start then
               Out_List.Append
                 ((Pos => C,
                   Text => To_Unbounded_String
                     (Buf (Run_Start .. I - 1))));
            end if;
            Apply_Break (C, D);
            Run_Start := I + 1;
         end if;
      end loop;
      if Buf'Last >= Run_Start then
         Out_List.Append
           ((Pos => C,
             Text => To_Unbounded_String (Buf (Run_Start .. Buf'Last))));
      end if;
      return Out_List;
   end Phokenize;

   procedure Advance (Loc : in out Coord; Target : Coord;
                        Result : out Unbounded_String)
   is
      Out_S : Unbounded_String;
      Dim : Integer := 0;
   begin
      Result := To_Unbounded_String ("");
      if Coord_Cmp (Loc, Target) >= 0 then
         return;
      end if;
      while Loc (Dim) = Target (Dim) loop
         Dim := Dim + 1;
      end loop;
      for J in 1 .. Target (Dim) - Loc (Dim) loop
         Append (Out_S, Dim_Breaks (Dim));
      end loop;
      Loc (Dim) := Target (Dim);
      for Lower in Dim + 1 .. 8 loop
         Loc (Lower) := 1;
      end loop;
      for Lower in Dim + 1 .. 8 loop
         for J in 1 .. Target (Lower) - 1 loop
            Append (Out_S, Dim_Breaks (Lower));
         end loop;
         Loc (Lower) := Target (Lower);
      end loop;
      Result := Out_S;
   end Advance;

   function Dephokenize (Stack : Scroll_List) return String is
      Sorted : Scroll_List := Stack;
      Tmp : Scroll;
      Loc : Coord := Root_Coord;
      Out_S : Unbounded_String;
   begin
      for I in 1 .. Integer (Sorted.Length) - 1 loop
         Tmp := Sorted (I);
         declare
            J : Integer := I - 1;
         begin
            while J >= 0 and then
              Coord_Cmp (Sorted (J).Pos, Tmp.Pos) > 0
            loop
               Sorted (J + 1) := Sorted (J);
               J := J - 1;
            end loop;
            Sorted (J + 1) := Tmp;
         end;
      end loop;
      for S of Sorted loop
         if Length (S.Text) > 0 then
            declare
               Adv : Unbounded_String;
            begin
               Advance (Loc, S.Pos, Adv);
               Append (Out_S, Adv);
            end;
            Append (Out_S, S.Text);
         end if;
      end loop;
      return To_String (Out_S);
   end Dephokenize;

   function Dephokenize_In_Order (Stack : Scroll_List) return String is
      Loc : Coord := Root_Coord;
      Out_S : Unbounded_String;
   begin
      for S of Stack loop
         declare
            Adv : Unbounded_String;
         begin
            Advance (Loc, S.Pos, Adv);
            Append (Out_S, Adv);
         end;
         Append (Out_S, S.Text);
      end loop;
      return To_String (Out_S);
   end Dephokenize_In_Order;

   function Normalize (Buf : String) return String is
   begin
      return Dephokenize (Phokenize (Buf));
   end Normalize;

   function Fetch (Buf : String; C : Coord) return String is
   begin
      for S of Phokenize (Buf) loop
         if S.Pos = C then
            return To_String (S.Text);
         end if;
      end loop;
      return "";
   end Fetch;

   function Update (Buf : String; C : Coord; Text : String;
                    Overwrite : Boolean) return String
   is
      Items : constant Scroll_List := Phokenize (Buf);
      Result : Scroll_List;
      Next_S : constant Scroll := (Pos => C,
                                   Text => To_Unbounded_String (Text));
      Appended : Boolean := False;
   begin
      for Ps of Items loop
         declare
            Cmp : constant Integer := Coord_Cmp (Ps.Pos, C);
         begin
            if Cmp > 0 and then not Appended then
               Result.Append (Next_S);
               Appended := True;
               Result.Append (Ps);
            elsif Cmp = 0 and then not Appended then
               if Overwrite then
                  Result.Append (Next_S);
               else
                  Result.Append
                    ((Pos => C, Text => Ps.Text & Next_S.Text));
               end if;
               Appended := True;
            else
               Result.Append (Ps);
            end if;
         end;
      end loop;
      if not Appended then
         Result.Append (Next_S);
      end if;
      return Dephokenize_In_Order (Result);
   end Update;

   function Insert (Buf : String; C : Coord; Text : String) return String is
   begin
      return Update (Buf, C, Text, False);
   end Insert;

   function Replace (Buf : String; C : Coord; Text : String) return String is
   begin
      return Update (Buf, C, Text, True);
   end Replace;

   --  remove: replace with "" then normalize -- coordinate-preserving.
   function Remove (Buf : String; C : Coord) return String is
   begin
      return Normalize (Update (Buf, C, "", True));
   end Remove;

   ------------------------------------------------------------------
   --  DynamicPhext over a vector with explicit capacity discipline.
   ------------------------------------------------------------------

   function Dyn_Create (Buf : String) return Dyn_Store is
      D : Dyn_Store;
   begin
      D.Items.Reserve_Capacity (Ada.Containers.Count_Type (D.Cap));
      for Ps of Phokenize (Buf) loop
         if Natural (D.Items.Length) = D.Cap then
            D.Cap := D.Cap * 2;
            D.Items.Reserve_Capacity (Ada.Containers.Count_Type (D.Cap));
         end if;
         D.Items.Append (Ps);
      end loop;
      return D;
   end Dyn_Create;

   function Dyn_Count (D : Dyn_Store) return Natural is
   begin
      return Natural (D.Items.Length);
   end Dyn_Count;

   function Dyn_Capacity (D : Dyn_Store) return Natural is
   begin
      return D.Cap;
   end Dyn_Capacity;

   --  Binary search: index of C, or its insertion point; Found set.
   procedure Dyn_Find (D : Dyn_Store; C : Coord;
                       Idx : out Natural; Found : out Boolean)
   is
      Lo : Natural := 0;
      Hi : Natural := Natural (D.Items.Length);
      Mid : Natural;
   begin
      Found := False;
      Idx := 0;
      while Lo < Hi loop
         Mid := (Lo + Hi) / 2;
         declare
            Cmp : constant Integer :=
              Coord_Cmp (D.Items (Integer (Mid)).Pos, C);
         begin
            if Cmp < 0 then
               Lo := Mid + 1;
            elsif Cmp > 0 then
               Hi := Mid;
            else
               Idx := Mid;
               Found := True;
               return;
            end if;
         end;
      end loop;
      Idx := Lo;
   end Dyn_Find;

   function Dyn_Fetch (D : Dyn_Store; C : Coord) return String is
      Idx : Natural;
      Found : Boolean;
   begin
      Dyn_Find (D, C, Idx, Found);
      if Found then
         return To_String (D.Items (Integer (Idx)).Text);
      end if;
      return "";
   end Dyn_Fetch;

   procedure Dyn_Grow_If_Full (D : in out Dyn_Store) is
   begin
      if Natural (D.Items.Length) = D.Cap then
         D.Cap := D.Cap * 2;
         D.Items.Reserve_Capacity (Ada.Containers.Count_Type (D.Cap));
      end if;
   end Dyn_Grow_If_Full;

   procedure Dyn_Shrink_If_Sparse (D : in out Dyn_Store) is
   begin
      if D.Cap > 1
        and then Natural (D.Items.Length) <= D.Cap / 4
      then
         D.Cap := Natural'Max (1, D.Cap / 2);
         D.Items.Reserve_Capacity (Ada.Containers.Count_Type (D.Cap));
      end if;
   end Dyn_Shrink_If_Sparse;

   procedure Dyn_Update (D : in out Dyn_Store; C : Coord; Text : String;
                         Overwrite : Boolean)
   is
      Idx : Natural;
      Found : Boolean;
   begin
      Dyn_Find (D, C, Idx, Found);
      if Found then
         if Text'Length = 0 then
            if Overwrite then
               D.Items.Delete (Integer (Idx));
               Dyn_Shrink_If_Sparse (D);
            end if;
         elsif Overwrite then
            D.Items (Integer (Idx)) :=
              (Pos => C, Text => To_Unbounded_String (Text));
         else
            D.Items (Integer (Idx)) :=
              (Pos => C,
               Text => D.Items (Integer (Idx)).Text &
                       To_Unbounded_String (Text));
         end if;
      elsif Text'Length > 0 then
         Dyn_Grow_If_Full (D);
         D.Items.Insert
           (Integer (Idx), (Pos => C, Text => To_Unbounded_String (Text)));
      end if;
   end Dyn_Update;

   procedure Dyn_Insert (D : in out Dyn_Store; C : Coord; Text : String) is
   begin
      Dyn_Update (D, C, Text, False);
   end Dyn_Insert;

   procedure Dyn_Replace (D : in out Dyn_Store; C : Coord; Text : String) is
   begin
      Dyn_Update (D, C, Text, True);
   end Dyn_Replace;

   procedure Dyn_Remove (D : in out Dyn_Store; C : Coord) is
      Idx : Natural;
      Found : Boolean;
   begin
      Dyn_Find (D, C, Idx, Found);
      if Found then
         D.Items.Delete (Integer (Idx));
         Dyn_Shrink_If_Sparse (D);
      end if;
   end Dyn_Remove;

   function Dyn_Serialize (D : Dyn_Store) return String is
   begin
      return Dephokenize (D.Items);
   end Dyn_Serialize;

   ------------------------------------------------------------------
   --  TransitivePhext over a hashed branching store.
   ------------------------------------------------------------------

   function Coord_Hash (C : Coord) return Ada.Containers.Hash_Type is
      use type Interfaces.Unsigned_64;
      H : Interfaces.Unsigned_64 := 1469598103934665603;
   begin
      for I in 0 .. 8 loop
         H := (H xor Interfaces.Unsigned_64
                 (C (I) mod 4294967296)) * 1099511628211;
      end loop;
      return Ada.Containers.Hash_Type (H mod 2147483647);
   end Coord_Hash;

   function Trans_Create (Buf : String) return Trans_Store is
      D : Trans_Store;
   begin
      for Ps of Phokenize (Buf) loop
         D.Map.Include (Ps.Pos, Ps.Text);
      end loop;
      return D;
   end Trans_Create;

   function Trans_Count (D : Trans_Store) return Natural is
   begin
      return Natural (D.Map.Length);
   end Trans_Count;

   function Trans_Fetch (D : Trans_Store; C : Coord) return String is
      Cur : constant Coord_Maps.Cursor := D.Map.Find (C);
   begin
      if Coord_Maps.Has_Element (Cur) then
         return To_String (Coord_Maps.Element (Cur));
      end if;
      return "";
   end Trans_Fetch;

   procedure Trans_Update (D : in out Trans_Store; C : Coord;
                           Text : String; Overwrite : Boolean)
   is
      Cur : Coord_Maps.Cursor := D.Map.Find (C);
   begin
      if Text'Length = 0 then
         if Overwrite and then Coord_Maps.Has_Element (Cur) then
            D.Map.Delete (Cur);
         end if;
      elsif Overwrite then
         D.Map.Include (C, To_Unbounded_String (Text));
      elsif Coord_Maps.Has_Element (Cur) then
         D.Map.Replace_Element
           (Cur, Coord_Maps.Element (Cur) & To_Unbounded_String (Text));
      else
         D.Map.Include (C, To_Unbounded_String (Text));
      end if;
   end Trans_Update;

   procedure Trans_Insert (D : in out Trans_Store; C : Coord;
                           Text : String)
   is
   begin
      Trans_Update (D, C, Text, False);
   end Trans_Insert;

   procedure Trans_Replace (D : in out Trans_Store; C : Coord;
                            Text : String)
   is
   begin
      Trans_Update (D, C, Text, True);
   end Trans_Replace;

   procedure Trans_Remove (D : in out Trans_Store; C : Coord) is
      Cur : Coord_Maps.Cursor := D.Map.Find (C);
   begin
      if Coord_Maps.Has_Element (Cur) then
         D.Map.Delete (Cur);
      end if;
   end Trans_Remove;

   function Trans_Serialize (D : Trans_Store) return String is
      List : Scroll_List;
      Cur : Coord_Maps.Cursor := D.Map.First;
   begin
      while Coord_Maps.Has_Element (Cur) loop
         List.Append
           ((Pos => Coord_Maps.Key (Cur),
             Text => Coord_Maps.Element (Cur)));
         Cur := Coord_Maps.Next (Cur);
      end loop;
      return Dephokenize (List);
   end Trans_Serialize;

end Phext;
