with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Phext is

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
      Neg : Boolean;
   begin
      while I <= S'Last loop
         Num := 0;
         Neg := False;
         if S (I) = '-' then
            Neg := True;
            I := I + 1;
         end if;
         if I > S'Last or else S (I) not in '0' .. '9' then
            raise Constraint_Error with "invalid coordinate: " & S;
         end if;
         while I <= S'Last and then S (I) in '0' .. '9' loop
            Num := Num * 10 +
              Long_Long_Integer (Character'Pos (S (I)) -
                                 Character'Pos ('0'));
            I := I + 1;
         end loop;
         if Neg then
            Num := -Num;
         end if;
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

   function Advance (Loc : in out Coord; Target : Coord) return String is
      Out_S : Unbounded_String;
      Dim : Integer := 0;
   begin
      if Coord_Cmp (Loc, Target) >= 0 then
         return "";
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
      return To_String (Out_S);
   end Advance;

   function Dephokenize (Stack : Scroll_List) return String is
      Sorted : Scroll_List := Stack;
      Tmp : Scroll;
      Loc : Coord := Root_Coord;
      Out_S : Unbounded_String;
   begin
      --  insertion sort by coordinate
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
         if Length (S.Text) = 0 then
            goto Continue;
         end if;
         Append (Out_S, Advance (Loc, S.Pos));
         Append (Out_S, S.Text);
         <<Continue>>
      end loop;
      return To_String (Out_S);
   end Dephokenize;

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
      Res : Scroll_List;
      Appended : Boolean := False;
      Next : Scroll := (Pos => C, Text => To_Unbounded_String (Text));
   begin
      for S of Items loop
         if Coord_Cmp (S.Pos, C) > 0 and then not Appended then
            Res.Append (Next);
            Appended := True;
         end if;
         if S.Pos = C and then not Appended then
            if not Overwrite then
               Next.Text := S.Text & Next.Text;
            end if;
            Res.Append (Next);
            Appended := True;
         else
            Res.Append (S);
         end if;
      end loop;
      if not Appended then
         Res.Append (Next);
      end if;
      return Dephokenize (Res);
   end Update;

   function Insert (Buf : String; C : Coord; Text : String)
                    return String is
   begin
      return Update (Buf, C, Text, False);
   end Insert;

   function Replace (Buf : String; C : Coord; Text : String)
                     return String is
   begin
      return Update (Buf, C, Text, True);
   end Replace;

   function Remove (Buf : String; C : Coord) return String is
   begin
      return Normalize (Update (Buf, C, "", True));
   end Remove;

   ---------------------- DynamicPhext ----------------------

   function Dyn_Create (Buf : String) return Dyn_Store is
      D : Dyn_Store;
      Items : constant Scroll_List := Phokenize (Buf);
   begin
      for S of Items loop
         Dyn_Insert (D, S.Pos, To_String (S.Text));
         --  Dyn_Insert merges; phokenize yields unique coords, and
         --  Create loads them in order -- equivalent here.
      end loop;
      return D;
   end Dyn_Create;

   function Dyn_Count (D : Dyn_Store) return Natural is
   begin
      return D.N;
   end Dyn_Count;

   function Dyn_Capacity (D : Dyn_Store) return Natural is
   begin
      return D.Cap;
   end Dyn_Capacity;

   procedure Dyn_Resize (D : in out Dyn_Store; New_Cap : Natural) is
      New_Arr : constant Scroll_Array_Access :=
        new Scroll_Array (0 .. New_Cap - 1);
   begin
      for I in 0 .. D.N - 1 loop
         New_Arr (I) := D.Items (I);
      end loop;
      D.Items := New_Arr;
      D.Cap := New_Cap;
      D.Resize_Count := D.Resize_Count + 1;
      D.Elements_Copied := D.Elements_Copied + D.N;
   end Dyn_Resize;

   procedure Dyn_Grow_If_Full (D : in out Dyn_Store) is
   begin
      if D.N = D.Cap then
         Dyn_Resize (D, D.Cap * 2);
      end if;
   end Dyn_Grow_If_Full;

   procedure Dyn_Shrink_If_Sparse (D : in out Dyn_Store) is
   begin
      if D.Cap > 1 and then D.N <= D.Cap / 4 then
         Dyn_Resize (D, Integer'Max (1, D.Cap / 2));
      end if;
   end Dyn_Shrink_If_Sparse;

   function Dyn_Find (D : Dyn_Store; C : Coord;
                      Found : out Boolean) return Natural
   is
      Lo : Integer := 0;
      Hi : Integer := Integer (D.N) - 1;
      Mid : Integer;
      Cmp : Integer;
   begin
      Found := False;
      while Lo <= Hi loop
         Mid := (Lo + Hi) / 2;
         Cmp := Coord_Cmp (D.Items (Mid).Pos, C);
         if Cmp = 0 then
            Found := True;
            return Natural (Mid);
         elsif Cmp < 0 then
            Lo := Mid + 1;
         else
            Hi := Mid - 1;
         end if;
      end loop;
      return Natural (Lo);
   end Dyn_Find;

   function Dyn_Fetch (D : Dyn_Store; C : Coord) return String is
      Found : Boolean;
      Idx : constant Natural := Dyn_Find (D, C, Found);
   begin
      if Found then
         return To_String (D.Items (Integer (Idx)).Text);
      end if;
      return "";
   end Dyn_Fetch;

   procedure Dyn_Put (D : in out Dyn_Store; C : Coord; Text : String;
                      Merge : Boolean)
   is
      Found : Boolean;
      Idx : constant Natural := Dyn_Find (D, C, Found);
   begin
      if Found then
         if Merge then
            D.Items (Integer (Idx)).Text :=
              D.Items (Integer (Idx)).Text &
              To_Unbounded_String (Text);
         else
            D.Items (Integer (Idx)).Text := To_Unbounded_String (Text);
         end if;
         return;
      end if;
      Dyn_Grow_If_Full (D);
      for J in reverse Integer (Idx) + 1 .. Integer (D.N) - 1 loop
         D.Items (J) := D.Items (J - 1);
      end loop;
      D.Items (Integer (Idx)) :=
        (Pos => C, Text => To_Unbounded_String (Text));
      D.N := D.N + 1;
   end Dyn_Put;

   procedure Dyn_Insert (D : in out Dyn_Store; C : Coord;
                         Text : String) is
   begin
      if Text'Length = 0 then
         return;
      end if;
      Dyn_Put (D, C, Text, Merge => True);
   end Dyn_Insert;

   procedure Dyn_Replace (D : in out Dyn_Store; C : Coord;
                          Text : String) is
   begin
      if Text'Length = 0 then
         Dyn_Remove (D, C);
         return;
      end if;
      Dyn_Put (D, C, Text, Merge => False);
   end Dyn_Replace;

   procedure Dyn_Remove (D : in out Dyn_Store; C : Coord) is
      Found : Boolean;
      Idx : constant Natural := Dyn_Find (D, C, Found);
   begin
      if not Found then
         return;
      end if;
      for J in Integer (Idx) .. Integer (D.N) - 2 loop
         D.Items (J) := D.Items (J + 1);
      end loop;
      D.N := D.N - 1;
      Dyn_Shrink_If_Sparse (D);
   end Dyn_Remove;

   function Dyn_Serialize (D : Dyn_Store) return String is
      List : Scroll_List;
   begin
      for I in 0 .. Integer (D.N) - 1 loop
         List.Append (D.Items (I));
      end loop;
      return Dephokenize (List);
   end Dyn_Serialize;

   ---------------------- TransitivePhext ----------------------

   function Find_Kid (Parent : Node_Access; K : Long_Long_Integer;
                      Create : Boolean) return Node_Access
   is
      Cur : Node_Access := Parent.First_Child;
   begin
      while Cur /= null loop
         if Cur.Key = K then
            return Cur;
         end if;
         Cur := Cur.Next_Sibling;
      end loop;
      if not Create then
         return null;
      end if;
      Cur := new Node;
      Cur.Key := K;
      Cur.Next_Sibling := Parent.First_Child;
      Parent.First_Child := Cur;
      return Cur;
   end Find_Kid;

   function Trans_Walk (D : Trans_Store; C : Coord;
                        Create : Boolean) return Node_Access
   is
      Cur : Node_Access := D.Root;
   begin
      for Dim in 0 .. 8 loop
         Cur := Find_Kid (Cur, C (Dim), Create);
         if Cur = null then
            return null;
         end if;
      end loop;
      return Cur;
   end Trans_Walk;

   function Trans_Create (Buf : String) return Trans_Store is
      D : Trans_Store;
      Items : constant Scroll_List := Phokenize (Buf);
   begin
      for S of Items loop
         Trans_Replace (D, S.Pos, To_String (S.Text));
      end loop;
      return D;
   end Trans_Create;

   function Trans_Count (D : Trans_Store) return Natural is
   begin
      return D.N;
   end Trans_Count;

   function Trans_Fetch (D : Trans_Store; C : Coord) return String is
      N : constant Node_Access := Trans_Walk (D, C, False);
   begin
      if N /= null and then N.Is_Leaf then
         return To_String (N.Leaf);
      end if;
      return "";
   end Trans_Fetch;

   procedure Trans_Insert (D : in out Trans_Store; C : Coord;
                           Text : String)
   is
      N : Node_Access;
   begin
      if Text'Length = 0 then
         return;
      end if;
      N := Trans_Walk (D, C, True);
      if N.Is_Leaf then
         N.Leaf := N.Leaf & To_Unbounded_String (Text);
      else
         N.Is_Leaf := True;
         N.Leaf := To_Unbounded_String (Text);
         D.N := D.N + 1;
      end if;
   end Trans_Insert;

   procedure Trans_Replace (D : in out Trans_Store; C : Coord;
                            Text : String)
   is
      N : Node_Access;
   begin
      if Text'Length = 0 then
         Trans_Remove (D, C);
         return;
      end if;
      N := Trans_Walk (D, C, True);
      if not N.Is_Leaf then
         D.N := D.N + 1;
      end if;
      N.Is_Leaf := True;
      N.Leaf := To_Unbounded_String (Text);
   end Trans_Replace;

   procedure Trans_Remove (D : in out Trans_Store; C : Coord) is
      N : constant Node_Access := Trans_Walk (D, C, False);
   begin
      if N /= null and then N.Is_Leaf then
         N.Is_Leaf := False;
         N.Leaf := Null_Unbounded_String;
         D.N := D.N - 1;
      end if;
   end Trans_Remove;

   procedure Trans_Collect (Node : Node_Access; Depth : Integer;
                            Prefix : in out Coord;
                            Out_List : in out Scroll_List)
   is
      --  collect children sorted by key: repeated min-scan
      Remaining : Natural := 0;
      Cur : Node_Access := Node.First_Child;
      Last_Key : Long_Long_Integer := Long_Long_Integer'First;
      First_Pass : Boolean := True;
   begin
      if Depth = 9 then
         if Node.Is_Leaf then
            Out_List.Append ((Pos => Prefix, Text => Node.Leaf));
         end if;
         return;
      end if;
      while Cur /= null loop
         Remaining := Remaining + 1;
         Cur := Cur.Next_Sibling;
      end loop;
      for Pass in 1 .. Remaining loop
         declare
            Best : Node_Access := null;
            Scan : Node_Access := Node.First_Child;
         begin
            while Scan /= null loop
               if (First_Pass or else Scan.Key > Last_Key) and then
                 (Best = null or else Scan.Key < Best.Key)
               then
                  Best := Scan;
               end if;
               Scan := Scan.Next_Sibling;
            end loop;
            Prefix (Depth) := Best.Key;
            Last_Key := Best.Key;
            First_Pass := False;
            Trans_Collect (Best, Depth + 1, Prefix, Out_List);
         end;
      end loop;
   end Trans_Collect;

   function Trans_Serialize (D : Trans_Store) return String is
      List : Scroll_List;
      Prefix : Coord := Root_Coord;
   begin
      Trans_Collect (D.Root, 0, Prefix, List);
      return Dephokenize (List);
   end Trans_Serialize;

end Phext;
