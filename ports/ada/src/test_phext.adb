--  Test suite for libphext-ada -- plain assertions.
--  Run: test_phext [fixtures_dir]; fixtures are directories holding
--  input.phext; each must round-trip byte-identically and normalize
--  idempotently. Covers coordinate-preserving REMOVE, DynamicPhext
--  and TransitivePhext equivalence with the string API.
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Directories; use Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Phext; use Phext;

procedure Test_Phext is

   Checks   : Natural := 0;
   Failures : Natural := 0;

   procedure Ok (Cond : Boolean; Name : String) is
   begin
      Checks := Checks + 1;
      if not Cond then
         Failures := Failures + 1;
         Put_Line (Standard_Error, "FAIL: " & Name);
      end if;
   end Ok;

   procedure Eq (A, B, Name : String) is
   begin
      Ok (A = B, Name & " (got len" & Integer'Image (A'Length) &
          ", want len" & Integer'Image (B'Length) & ")");
   end Eq;

   function C (S : String) return Coord is
   begin
      return Parse_Coord (S);
   end C;

   B17 : constant String := (1 => Character'Val (23));
   B18 : constant String := (1 => Character'Val (24));
   B01 : constant String := (1 => Character'Val (1));
   NL  : constant String := (1 => Character'Val (10));

   function Read_File (Path : String) return String is
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
   begin
      SIO.Open (F, SIO.In_File, Path);
      declare
         N : constant Natural := Natural (SIO.Size (F));
         Data : String (1 .. N);
      begin
         if N > 0 then
            String'Read (SIO.Stream (F), Data);
         end if;
         SIO.Close (F);
         return Data;
      end;
   end Read_File;

   Fixture_Count : Natural := 0;
   Identical     : Natural := 0;
   Idem          : Natural := 0;

   procedure Walk_Fixtures (Dir : String) is
      Srch : Search_Type;
      Ent  : Directory_Entry_Type;
   begin
      Start_Search (Srch, Dir, "");
      while More_Entries (Srch) loop
         Get_Next_Entry (Srch, Ent);
         if Simple_Name (Ent) = "." or else Simple_Name (Ent) = ".." then
            null;
         elsif Kind (Ent) = Directory then
            Walk_Fixtures (Full_Name (Ent));
         elsif Simple_Name (Ent) = "input.phext" then
            Fixture_Count := Fixture_Count + 1;
            declare
               Data : constant String := Read_File (Full_Name (Ent));
            begin
               if Normalize (Data) = Data then
                  Identical := Identical + 1;
               else
                  Put_Line (Standard_Error,
                            "fixture round-trip differs: " &
                            Full_Name (Ent));
               end if;
               if Normalize (Normalize (Data)) = Normalize (Data) then
                  Idem := Idem + 1;
               end if;
            end;
         end if;
      end loop;
      End_Search (Srch);
   end Walk_Fixtures;

   Sc : Scroll_List;
   Buf, Out_S : Unbounded_String;
   Dyn : Dyn_Store;
   Trn : Trans_Store;
begin
   --  coordinate
   Eq (Coord_Str (C ("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9",
       "coord format");
   begin
      declare
         X : constant Coord := C ("0.1.1/1.1.1/1.1.1");
      begin
         Ok (False, "coord rejects 0");
      end;
   exception
      when Constraint_Error => Ok (True, "coord rejects 0");
   end;
   begin
      declare
         X : constant Coord := C ("1.1/1.1.1/1.1.1");
      begin
         Ok (False, "coord rejects short");
      end;
   exception
      when Constraint_Error => Ok (True, "coord rejects short");
   end;

   --  phokenize
   Sc := Phokenize ("hello");
   Ok (Natural (Sc.Length) = 1, "one scroll");
   Eq (Coord_Str (Sc (0).Pos), "1.1.1/1.1.1/1.1.1", "first coord");
   Eq (To_String (Sc (0).Text), "hello", "first text");
   Sc := Phokenize ("a" & B17 & "b" & B17 & B17 & "c" & NL & "line2");
   Ok (Natural (Sc.Length) = 3, "scroll breaks");
   Eq (Coord_Str (Sc (1).Pos), "1.1.1/1.1.1/1.1.2", "second coord");
   Eq (Coord_Str (Sc (2).Pos), "1.1.1/1.1.1/1.1.4", "gap coord advance");
   Eq (To_String (Sc (2).Text), "c" & NL & "line2",
       "newline is ordinary text");
   Sc := Phokenize ("x" & B01 & "y");
   Eq (Coord_Str (Sc (1).Pos), "2.1.1/1.1.1/1.1.1",
       "library break resets");
   Sc := Phokenize ("x" & B18 & "y");
   Eq (Coord_Str (Sc (1).Pos), "1.1.1/1.1.1/1.2.1", "section break");
   Ok (Natural (Phokenize ("").Length) = 0, "empty buffer");
   Sc := Phokenize ("a" & Character'Val (0) & Character'Val (255) & "b");
   Ok (Natural (Sc.Length) = 1, "binary text is one scroll");
   Ok (Length (Sc (0).Text) = 4, "binary text preserved");

   --  round trip
   Buf := To_Unbounded_String
     ("alpha" & B17 & "beta" & B18 & "gamma" & B01 & "delta");
   Eq (Dephokenize (Phokenize (To_String (Buf))), To_String (Buf),
       "round trip sample");
   Eq (Normalize (Normalize (B17 & B17 & "lead")),
       Normalize (B17 & B17 & "lead"), "normalize idempotent");

   --  fetch incl. gaps
   Buf := To_Unbounded_String ("one" & B17 & "two" & B17 & B17 & "four");
   Eq (Fetch (To_String (Buf), C ("1.1.1/1.1.1/1.1.1")), "one", "fetch 1");
   Eq (Fetch (To_String (Buf), C ("1.1.1/1.1.1/1.1.4")), "four", "fetch 4");
   Eq (Fetch (To_String (Buf), C ("1.1.1/1.1.1/1.1.3")), "",
       "gap fetch is empty");
   Eq (Fetch (To_String (Buf), C ("9.9.9/9.9.9/9.9.9")), "",
       "far gap fetch is empty");

   --  insert
   Out_S := To_Unbounded_String
     (Insert ("base", C ("1.1.1/1.1.1/1.1.1"), "+more"));
   Eq (Fetch (To_String (Out_S), C ("1.1.1/1.1.1/1.1.1")), "base+more",
       "insert appends after existing");
   Out_S := To_Unbounded_String (Insert ("", C ("1.1.1/1.1.1/1.1.3"), "new"));
   Eq (To_String (Out_S), B17 & B17 & "new", "insert at gap emits breaks");

   --  replace / remove: REMOVE IS COORDINATE-PRESERVING
   Out_S := To_Unbounded_String
     (Replace ("old" & B17 & "keep", C ("1.1.1/1.1.1/1.1.1"),
                     "new"));
   Eq (To_String (Out_S), "new" & B17 & "keep", "replace overwrites");
   Out_S := To_Unbounded_String
     (Remove ("a" & B17 & "b" & B17 & "c", C ("1.1.1/1.1.1/1.1.2")));
   Eq (To_String (Out_S), "a" & B17 & B17 & "c", "remove leaves a gap");
   Eq (Fetch (To_String (Out_S), C ("1.1.1/1.1.1/1.1.2")), "",
       "removed coordinate reads empty");
   Eq (Fetch (To_String (Out_S), C ("1.1.1/1.1.1/1.1.3")), "c",
       "neighbour keeps its coordinate");
   Ok (Remove ("only", C ("1.1.1/1.1.1/1.1.1"))'Length = 0,
       "remove sole scroll");
   Eq (Remove ("a", C ("5.5.5/5.5.5/5.5.5")), "a",
       "remove gap is a no-op");

   --  DynamicPhext equivalence
   Dyn := Dyn_Create ("a" & B17 & "b" & B17 & "c");
   Eq (Dyn_Fetch (Dyn, C ("1.1.1/1.1.1/1.1.2")), "b", "dyn fetch");
   Dyn_Insert (Dyn, C ("1.1.1/1.1.1/1.1.2"), "!");
   Eq (Dyn_Fetch (Dyn, C ("1.1.1/1.1.1/1.1.2")), "b!", "dyn insert merges");
   Dyn_Replace (Dyn, C ("1.1.1/1.1.1/1.1.5"), "deep");
   Dyn_Remove (Dyn, C ("1.1.1/1.1.1/1.1.1"));
   Eq (Dyn_Fetch (Dyn, C ("1.1.1/1.1.1/1.1.1")), "",
       "dyn remove is a gap");
   Eq (Dyn_Fetch (Dyn, C ("1.1.1/1.1.1/1.1.3")), "c",
       "dyn neighbour unshifted");
   Buf := To_Unbounded_String
     (Remove (Insert (Insert ("a" & B17 & "b" & B17 & "c",
                                  C ("1.1.1/1.1.1/1.1.2"), "!"),
                          C ("1.1.1/1.1.1/1.1.5"), "deep"),
                  C ("1.1.1/1.1.1/1.1.1")));
   Eq (Dyn_Serialize (Dyn), To_String (Buf), "dyn serialize = string path");
   Ok (Dyn_Capacity (Dyn) >= Dyn_Count (Dyn), "dyn capacity >= count");

   --  TransitivePhext equivalence
   Trn := Trans_Create ("a" & B17 & "b" & B17 & "c");
   Eq (Trans_Fetch (Trn, C ("1.1.1/1.1.1/1.1.3")), "c", "trans fetch");
   Trans_Insert (Trn, C ("1.1.1/1.1.1/1.1.2"), "!");
   Trans_Replace (Trn, C ("2.1.1/1.1.1/1.1.1"), "lib2");
   Trans_Remove (Trn, C ("1.1.1/1.1.1/1.1.1"));
   Eq (Trans_Fetch (Trn, C ("1.1.1/1.1.1/1.1.1")), "",
       "trans remove is a gap");
   Eq (Trans_Fetch (Trn, C ("1.1.1/1.1.1/1.1.3")), "c",
       "trans neighbour unshifted");
   Eq (Trans_Serialize (Trn), B17 & "b!" & B17 & "c" & B01 & "lib2",
       "trans serialize = string path");

   --  fixtures
   if Ada.Command_Line.Argument_Count >= 1 then
      Walk_Fixtures (Ada.Command_Line.Argument (1));
      Put_Line ("fixtures:" & Natural'Image (Identical) & "/" &
                Natural'Image (Fixture_Count) & " byte-identical," &
                Natural'Image (Idem) & "/" &
                Natural'Image (Fixture_Count) &
                " normalize-idempotent");
      Ok (Identical = Fixture_Count, "fixtures all byte-identical");
      Ok (Fixture_Count = 16, "fixture count is 16");
   end if;

   Put_Line ("ada suite:" & Natural'Image (Checks) & " checks," &
             Natural'Image (Failures) & " failures");
   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Test_Phext;
