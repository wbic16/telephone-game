--  Hub-side CLI for libphext-ada (Exocortical Telephone Game,
--  contract v2). Transport: no argument = one JSON object on stdin,
--  one JSON response on stdout; argument `serve` = one JSON request
--  per line. State travels as base64. Phext logic is this port's own
--  package (phext.adb); SHA-256 and Base64 are native (wire.adb);
--  JSON parsing/canonicalization is native (wire.adb). PGP: subprocess
--  gpg with per-port GNUPGHOME ~/telephone-spark/keys on the hub.
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Directories;
with GNAT.OS_Lib;
with Interfaces.C;
with Phext; use Phext;
with Wire; use Wire;

procedure Cli is

   Impl : constant String := "spark";
   Key_Home : constant String := "/home/wbic16/telephone-spark/keys";
   Index_C : constant Coord := (1, 1, 1, 1, 1, 1, 1, 1, 1);
   Keys_C  : constant Coord := (1, 1, 1, 1, 1, 1, 1, 1, 2);
   KH_C    : constant Coord := (1, 1, 1, 1, 1, 1, 1, 1, 3);

   Cache_Map : Scroll_List;
   Cache_OK  : Boolean := False;

   function Getchar return Integer is
      function C_Getchar return Interfaces.C.int
        with Import, Convention => C, External_Name => "getchar";
   begin
      return Integer (C_Getchar);
   end Getchar;

   procedure Write_File (Path : String; Data : String) is
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
   begin
      SIO.Create (F, SIO.Out_File, Path);
      if Data'Length > 0 then
         String'Write (SIO.Stream (F), Data);
      end if;
      SIO.Close (F);
   end Write_File;

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

   function Run_Prog (Prog : String; Args_Str : String;
                      Out_Path : String) return Integer
   is
      use GNAT.OS_Lib;
      Args : Argument_List_Access := Argument_String_To_List (Args_Str);
      FD : File_Descriptor;
      RC : Integer;
   begin
      if Out_Path = "" then
         FD := Standout;
      else
         FD := Create_Output_Text_File (Out_Path);
      end if;
      Spawn (Prog, Args.all, FD, RC, Err_To_Out => True);
      if Out_Path /= "" then
         Close (FD);
      end if;
      Free (Args);
      return RC;
   end Run_Prog;

   procedure Gpg_Set_Home (Home : String) is
   begin
      GNAT.OS_Lib.Setenv ("GNUPGHOME", Home);
   end Gpg_Set_Home;

   function Gpg_Out (Args_Str : String; Home : String;
                     Out_Path : String) return Integer is
   begin
      Gpg_Set_Home (Home);
      return Run_Prog ("/usr/bin/gpg", "--batch --yes " & Args_Str,
                       Out_Path);
   end Gpg_Out;

   procedure Ensure_Key_Home is
      RC : Integer;
   begin
      if not Ada.Directories.Exists (Key_Home) then
         Ada.Directories.Create_Path (Key_Home);
      end if;
      --  gpg warns (into the merged output) on a non-700 homedir
      RC := Run_Prog ("/bin/chmod", "700 " & Key_Home, "");
   end Ensure_Key_Home;

   function Ensure_Key return String is
      Tmp : constant String := "/tmp/tel-ada-keys.txt";
      Tmp2 : constant String := "/tmp/tel-ada-pub.txt";
      RC : Integer;
   begin
      Ensure_Key_Home;
      RC := Gpg_Out ("--list-keys --with-colons", Key_Home, Tmp);
      declare
         Listing : constant String :=
           (if Ada.Directories.Exists (Tmp) then Read_File (Tmp)
            else "");
         Has_Pub : Boolean := False;
      begin
         for I in Listing'First .. Listing'Last - 3 loop
            if Listing (I .. I + 3) = "pub:" then
               Has_Pub := True;
            end if;
         end loop;
         if not Has_Pub then
            RC := Gpg_Out
              ("--pinentry-mode loopback --passphrase= " &
               "--quick-generate-key telephone-spark ed25519 sign never",
               Key_Home, "/tmp/tel-ada-gen.txt");
         end if;
      end;
      RC := Gpg_Out ("--armor --export telephone-spark", Key_Home, Tmp2);
      declare
         Pub : constant String := Read_File (Tmp2);
         --  trim trailing whitespace/newlines
         Last : Integer := Pub'Last;
      begin
         while Last >= Pub'First and then
           (Pub (Last) = Character'Val (10) or else
            Pub (Last) = Character'Val (13) or else Pub (Last) = ' ')
         loop
            Last := Last - 1;
         end loop;
         return Pub (Pub'First .. Last);
      end;
   end Ensure_Key;

   function Sign_Descriptor (Desc : JAccess) return String is
      Data_F : constant String := "/tmp/tel-ada-desc.json";
      Sig_F  : constant String := "/tmp/tel-ada-desc.sig";
      RC : Integer;
   begin
      Ensure_Key_Home;
      declare
         Pub : constant String := Ensure_Key;
      begin
         null;
      end;
      Write_File (Data_F, Canon (Desc));
      RC := Gpg_Out
        ("--pinentry-mode loopback --passphrase= --detach-sign " &
         "--armor --output " & Sig_F & " " & Data_F, Key_Home,
         "/tmp/tel-ada-sign.txt");
      if RC /= 0 then
         raise Program_Error with "attest signing failed";
      end if;
      declare
         Sig : constant String := Read_File (Sig_F);
         Last : Integer := Sig'Last;
      begin
         while Last >= Sig'First and then
           (Sig (Last) = Character'Val (10) or else
            Sig (Last) = Character'Val (13) or else Sig (Last) = ' ')
         loop
            Last := Last - 1;
         end loop;
         return Sig (Sig'First .. Last);
      end;
   end Sign_Descriptor;

   function Verify_Signature (Pubkeys : String; Sig_B64 : String;
                              Data : String) return Boolean
   is
      Home : constant String := "/tmp/tel-ada-verify-gnupg";
      Keys_F : constant String := "/tmp/tel-ada-verify-keys.asc";
      Sig_F  : constant String := "/tmp/tel-ada-verify-sig.asc";
      Data_F : constant String := "/tmp/tel-ada-verify-data";
      RC : Integer;
   begin
      if Ada.Directories.Exists (Home) then
         Ada.Directories.Delete_Tree (Home);
      end if;
      Ada.Directories.Create_Path (Home);
      Write_File (Keys_F, Pubkeys);
      Write_File (Sig_F, B64_Decode (Sig_B64));
      Write_File (Data_F, Data);
      RC := Gpg_Out ("--import " & Keys_F, Home,
                     "/tmp/tel-ada-import.txt");
      if RC /= 0 then
         return False;
      end if;
      RC := Gpg_Out ("--verify " & Sig_F & " " & Data_F, Home,
                     "/tmp/tel-ada-verify.txt");
      Gpg_Set_Home (Key_Home);
      return RC = 0;
   end Verify_Signature;

   function State_Of (Req : JAccess) return String is
      S : constant String := Get_Str (Req, "state");
   begin
      if S'Length > 0 then
         return B64_Decode (S);
      end if;
      return B64_Decode (Get_Str (Req, "state_b64"));
   end State_Of;

   function Map_Find (Map : Scroll_List; C : Coord;
                      Text : out Unbounded_String) return Boolean is
   begin
      for S of Map loop
         if S.Pos = C then
            Text := S.Text;
            return True;
         end if;
      end loop;
      Text := Null_Unbounded_String;
      return False;
   end Map_Find;

   function Apply_Step (Data : String; Step : JAccess;
                        Fetch_Sha : out Unbounded_String) return String
   is
      Op : constant String := Get_Str (Step, "op");
      C : constant Coord :=
        Parse_Coord (Get_Str (Step, "coordinate", "1.1.1/1.1.1/1.1.1"));
      Map : Scroll_List := Phokenize (Data);
      Done : Boolean := False;
   begin
      Fetch_Sha := Null_Unbounded_String;
      if Op = "fetch" or else Op = "navigate" then
         Fetch_Sha := To_Unbounded_String
           (Sha256_Hex (Fetch (Data, C)));
         return Data;
      end if;
      for S of Map loop
         if S.Pos = C then
            Done := True;
            if Op = "insert" then
               S.Text := S.Text & To_Unbounded_String
                 (Text_To_Bytes (Get_Str (Step, "text")));
            elsif Op = "replace" then
               S.Text := To_Unbounded_String
                 (Text_To_Bytes (Get_Str (Step, "text")));
            elsif Op = "remove" then
               S.Text := Null_Unbounded_String;
            else
               raise Program_Error with "unknown op " & Op;
            end if;
         end if;
      end loop;
      if not Done and then Op /= "remove" then
         Map.Append ((Pos => C, Text => To_Unbounded_String
           (Text_To_Bytes (Get_Str (Step, "text")))));
      end if;
      return Dephokenize (Map);
   end Apply_Step;

   function VFail (N : Natural; Msg : String) return JAccess is
      R : constant JAccess := New_Obj;
      F : constant JAccess := New_Obj;
   begin
      Obj_Put_Str (R, "impl", Impl);
      Obj_Put_Str (R, "verdict", "fail");
      Obj_Put_Int (R, "placements_checked", Long_Long_Integer (N));
      Obj_Put_Str (F, "detail", Msg);
      Obj_Put (R, "first_failure", F);
      return R;
   end VFail;

   function Verify_Stress (Data : String) return JAccess is
      Map : constant Scroll_List := Phokenize (Data);
      Keys_Text : Unbounded_String;
      KH_Text : Unbounded_String;
      Idx_Text : Unbounded_String;
      Txt : Unbounded_String;
      Checked : Natural := 0;
      Prev_Hash : Unbounded_String;
      Prev_Set : Boolean := False;
      --  placements recorded as "coord=hash" lines
      Placed : Unbounded_String;
   begin
      if not Map_Find (Map, Keys_C, Keys_Text) then
         Keys_Text := Null_Unbounded_String;
      end if;
      if Map_Find (Map, KH_C, KH_Text) then
         if Sha256_Hex (To_String (Keys_Text)) /=
           To_String (Trim (KH_Text, Ada.Strings.Both))
         then
            return VFail (0, "keys-hash scroll does not match keys");
         end if;
      end if;
      --  events in seq order: seqs are 1..N contiguous
      for Seq in 1 .. 100000 loop
         declare
            EC : Coord := (1, 1, 1, 1, 1, 1, 2, 1,
                           Long_Long_Integer (Seq));
            Ev_Text : Unbounded_String;
         begin
            if not Map_Find (Map, EC, Ev_Text) then
               exit;
            end if;
            declare
               Ev : constant JAccess :=
                 Parse_JSON (Bytes_To_Text (To_String (Ev_Text)));
               Prev : constant JAccess := Get (Ev, "prev");
               EvBody : constant JAccess := Get (Ev, "body");
            begin
               if not Prev_Set then
                  if Prev = null or else Kind_Of (Prev) /= JNull then
                     return VFail (Checked, "event chain broken");
                  end if;
               else
                  if Prev = null or else Kind_Of (Prev) /= JStr or else
                    As_Str (Prev) /= To_String (Prev_Hash)
                  then
                     return VFail (Checked, "event chain broken");
                  end if;
               end if;
               Prev_Hash := To_Unbounded_String
                 (Sha256_Hex (Canon (EvBody)));
               Prev_Set := True;
               if Get_Str (EvBody, "type") = "placement" then
                  declare
                     Coord_S : constant String := Get_Str (EvBody, "coord");
                     C : constant Coord := Parse_Coord (Coord_S);
                     Desc : constant JAccess := New_Obj;
                  begin
                     if Index (Placed, Coord_S & "=") > 0 then
                        return VFail (Checked, "coordinate reused");
                     end if;
                     if not Map_Find (Map, C, Txt) then
                        return VFail (Checked,
                                      "placement scroll missing");
                     end if;
                     if Sha256_Hex (To_String (Txt)) /=
                       Get_Str (EvBody, "text_sha256")
                     then
                        return VFail (Checked,
                                      "placement scroll hash mismatch");
                     end if;
                     Obj_Put_Int (Desc, "turn", Get_Int (EvBody, "turn"));
                     Obj_Put_Str (Desc, "coordinate", Coord_S);
                     Obj_Put_Str (Desc, "scroll_sha256",
                                  Get_Str (EvBody, "text_sha256"));
                     Obj_Put_Str (Desc, "file_sha256",
                                  Get_Str (EvBody, "file_sha256"));
                     if not Verify_Signature
                       (Bytes_To_Text (To_String (Keys_Text)),
                        Get_Str (EvBody, "att"),
                        Canon (Desc))
                     then
                        return VFail (Checked, "attestation fails");
                     end if;
                     Append (Placed, Coord_S & "=" &
                             Get_Str (EvBody, "text_sha256") &
                             Character'Val (10));
                     Checked := Checked + 1;
                  end;
               end if;
            end;
         end;
      end loop;
      --  index check
      if not Map_Find (Map, Index_C, Idx_Text) then
         Idx_Text := Null_Unbounded_String;
      end if;
      declare
         Lines : constant String :=
           Bytes_To_Text (To_String (Idx_Text));
         I : Integer := Lines'First;
         Count : Natural := 0;
         Line_Start : Integer;
      begin
         while I <= Lines'Last loop
            Line_Start := I;
            while I <= Lines'Last and then
              Lines (I) /= Character'Val (10)
            loop
               I := I + 1;
            end loop;
            declare
               Line : constant String := Lines (Line_Start .. I - 1);
            begin
               if Line'Length > 0 and then Line (Line'First) /= '#' then
                  Count := Count + 1;
                  --  format: <turn> <coord> <sha256> <actor>
                  declare
                     Sp1 : Integer := Line'First;
                     Sp2 : Integer := Line'First;
                     Sp3 : Integer := Line'First;
                  begin
                     while Sp1 <= Line'Last and then Line (Sp1) /= ' ' loop
                        Sp1 := Sp1 + 1;
                     end loop;
                     Sp2 := Sp1 + 1;
                     while Sp2 <= Line'Last and then Line (Sp2) /= ' ' loop
                        Sp2 := Sp2 + 1;
                     end loop;
                     Sp3 := Sp2 + 1;
                     while Sp3 <= Line'Last and then Line (Sp3) /= ' ' loop
                        Sp3 := Sp3 + 1;
                     end loop;
                     if Index (Placed,
                               Line (Sp1 + 1 .. Sp2 - 1) & "=" &
                               Line (Sp2 + 1 .. Sp3 - 1)) = 0
                     then
                        return VFail (Checked, "index hash mismatch");
                     end if;
                  end;
               end if;
            end;
            I := I + 1;
         end loop;
         if Count /= Checked then
            return VFail (Checked, "index lines != placements");
         end if;
      end;
      declare
         R : constant JAccess := New_Obj;
      begin
         Obj_Put_Str (R, "impl", Impl);
         Obj_Put_Str (R, "verdict", "pass");
         Obj_Put_Int (R, "placements_checked",
                      Long_Long_Integer (Checked));
         Obj_Put (R, "first_failure", New_Null);
         return R;
      end;
   end Verify_Stress;

   function Dispatch (Req : JAccess) return JAccess is
      Cmd : constant String := Get_Str (Req, "cmd");
      O : constant JAccess := New_Obj;
   begin
      if Cmd = "id" then
         Obj_Put_Str (O, "impl", Impl);
         return O;
      elsif Cmd = "keygen" then
         Obj_Put_Str (O, "impl", Impl);
         Obj_Put_Str (O, "pubkey", Ensure_Key);
         return O;
      elsif Cmd = "echo" then
         Obj_Put_Str (O, "impl", Impl);
         Obj_Put_Str (O, "echo", Sha256_Hex
           ("{""impl"":""" & Impl & """,""ping"":" &
            Canon (Get (Req, "ping")) & "}"));
         return O;
      elsif Cmd = "elect" then
         declare
            Cands : constant JAccess := Get (Req, "candidates");
            Pool : Unbounded_String;
            Pool_N : Natural := 0;
            CSV : Unbounded_String;
            Hash : constant String := Sha256_Hex
              (Impl & "-elect:" & Get_Str (Req, "position") & ":" &
               Long_Long_Integer'Image (Get_Int (Req, "turn")) & ":");
            --  note: hash seed uses csv appended below; see Elect_Seed
            Seed_Hash : String (1 .. 64);
            Idx : Natural;
         begin
            for I in 0 .. Arr_Len (Cands) - 1 loop
               if I > 0 then
                  Append (CSV, ",");
               end if;
               Append (CSV, As_Str (Arr_Item (Cands, I)));
            end loop;
            Seed_Hash := Sha256_Hex
              (Impl & "-elect:" & Get_Str (Req, "position") & ":" &
               Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Get_Int (Req, "turn")),
                     Ada.Strings.Left) & ":" & To_String (CSV));
            for I in 0 .. Arr_Len (Cands) - 1 loop
               if As_Str (Arr_Item (Cands, I)) /= Impl then
                  Append (Pool, As_Str (Arr_Item (Cands, I)) &
                          Character'Val (10));
                  Pool_N := Pool_N + 1;
               end if;
            end loop;
            if Pool_N = 0 then
               Pool := CSV;
               Pool_N := Arr_Len (Cands);
               --  pool entries comma separated in this fallback
               declare
                  Pick : constant Natural :=
                    Natural (Long_Long_Integer'Value
                      ("16#" & Seed_Hash (1 .. 8) & "#") mod
                      Long_Long_Integer (Pool_N));
                  Start : Integer := 1;
                  Cur : Natural := 0;
                  S : constant String := To_String (Pool);
               begin
                  for I in S'Range loop
                     if S (I) = ',' then
                        if Cur = Pick then
                           Obj_Put_Str (O, "elect", S (Start .. I - 1));
                           return O;
                        end if;
                        Cur := Cur + 1;
                        Start := I + 1;
                     end if;
                  end loop;
                  Obj_Put_Str (O, "elect", S (Start .. S'Last));
                  return O;
               end;
            end if;
            Idx := Natural (Long_Long_Integer'Value
              ("16#" & Seed_Hash (1 .. 8) & "#") mod
              Long_Long_Integer (Pool_N));
            declare
               S : constant String := To_String (Pool);
               Start : Integer := S'First;
               Cur : Natural := 0;
            begin
               for I in S'Range loop
                  if S (I) = Character'Val (10) then
                     if Cur = Idx then
                        Obj_Put_Str (O, "elect", S (Start .. I - 1));
                        return O;
                     end if;
                     Cur := Cur + 1;
                     Start := I + 1;
                  end if;
               end loop;
            end;
            Obj_Put_Str (O, "elect", Impl);
            return O;
         end;
      elsif Cmd = "choose" then
         declare
            Data : constant String := State_Of (Req);
            Map : constant Scroll_List := Phokenize (Data);
            C : Coord := Parse_Coord
              (Get_Str (Req, "position", "1.1.1/1.1.1/1.1.1"));
            T : Unbounded_String;
         begin
            while Map_Find (Map, C, T) loop
               C (8) := C (8) + 1;
            end loop;
            Obj_Put_Str (O, "op", "insert");
            Obj_Put_Str (O, "coordinate", Coord_Str (C));
            Obj_Put_Str (O, "text", Impl & " was here, turn " &
              Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Get_Int (Req, "turn")),
                    Ada.Strings.Left));
            return O;
         end;
      elsif Cmd = "apply" then
         declare
            FS : Unbounded_String;
            Data : constant String :=
              Apply_Step (State_Of (Req), Get (Req, "step"), FS);
         begin
            Obj_Put_Str (O, "state_b64", B64_Encode (Data));
            Obj_Put_Str (O, "state_sha256", Sha256_Hex (Data));
            if Length (FS) > 0 then
               Obj_Put_Str (O, "fetch_sha256", To_String (FS));
            end if;
            return O;
         end;
      elsif Cmd = "attest" then
         Obj_Put_Str (O, "signature",
                      B64_Encode (Sign_Descriptor
                        (Get (Req, "descriptor"))));
         return O;
      elsif Cmd = "init" then
         Cache_Map := Phokenize (State_Of (Req));
         Cache_OK := True;
         Obj_Put_Str (O, "impl", Impl);
         Obj_Put_Str (O, "verdict", "pass");
         return O;
      elsif Cmd = "validate" then
         Obj_Put_Str (O, "impl", Impl);
         if Get (Req, "prior_state") /= null then
            declare
               Step : constant JAccess := Get (Req, "step");
               CC : constant Coord :=
                 Parse_Coord (Get_Str (Step, "coordinate"));
               New_Map : constant Scroll_List :=
                 Phokenize (State_Of (Req));
               Prior : constant Scroll_List :=
                 Phokenize (B64_Decode (Get_Str (Req, "prior_state")));
               PT : Unbounded_String;
               Bad : Unbounded_String;
               Added : Natural := 0;
            begin
               if not Map_Find (New_Map, CC, PT) then
                  Bad := To_Unbounded_String ("placed scroll missing");
               elsif To_String (PT) /=
                 Text_To_Bytes (Get_Str (Step, "text"))
               then
                  Bad := To_Unbounded_String
                    ("placed scroll text != step text");
               else
                  for S of Prior loop
                     if not Map_Find (New_Map, S.Pos, PT) or else
                       PT /= S.Text
                     then
                        Bad := To_Unbounded_String
                          ("prior scroll overwritten");
                        exit;
                     end if;
                  end loop;
                  if Length (Bad) = 0 then
                     for S of New_Map loop
                        if not Map_Find (Prior, S.Pos, PT) then
                           Added := Added + 1;
                        end if;
                     end loop;
                     if Added /= 1 then
                        Bad := To_Unbounded_String
                          ("expected exactly one added scroll");
                     end if;
                  end if;
               end if;
               if Length (Bad) = 0 then
                  Obj_Put_Str (O, "verdict", "pass");
               else
                  Obj_Put_Str (O, "verdict", "fail");
                  Obj_Put_Str (O, "detail", To_String (Bad));
               end if;
               return O;
            end;
         end if;
         if not Cache_OK then
            Obj_Put_Str (O, "verdict", "fail");
            Obj_Put_Str (O, "detail", "validate before init");
            return O;
         end if;
         declare
            Step : constant JAccess := Get (Req, "step");
            CC : constant Coord :=
              Parse_Coord (Get_Str (Step, "coordinate"));
            EV : constant Coord :=
              Parse_Coord (Get_Str (Req, "event_coord"));
            New_Map : constant Scroll_List :=
              Phokenize (State_Of (Req));
            PT : Unbounded_String;
            Bad : Unbounded_String;
         begin
            if not Map_Find (New_Map, CC, PT) or else
              To_String (PT) /= Text_To_Bytes (Get_Str (Step, "text"))
            then
               Bad := To_Unbounded_String
                 ("placed scroll missing or altered");
            else
               for S of Cache_Map loop
                  if S.Pos /= Index_C then
                     if not Map_Find (New_Map, S.Pos, PT) or else
                       PT /= S.Text
                     then
                        Bad := To_Unbounded_String
                          ("prior scroll overwritten");
                        exit;
                     end if;
                  end if;
               end loop;
               if Length (Bad) = 0 then
                  for S of New_Map loop
                     if not Map_Find (Cache_Map, S.Pos, PT) and then
                       S.Pos /= CC and then S.Pos /= EV
                     then
                        Bad := To_Unbounded_String
                          ("unexpected new scroll");
                        exit;
                     end if;
                  end loop;
               end if;
               if Length (Bad) = 0 then
                  if not Map_Find (New_Map, Index_C, PT) then
                     Bad := To_Unbounded_String ("index missing");
                  elsif Ada.Strings.Fixed.Index
                          (Bytes_To_Text (To_String (PT)),
                           Get_Str (Req, "index_line")) = 0
                  then
                     Bad := To_Unbounded_String
                       ("index does not record the placement");
                  end if;
               end if;
            end if;
            if Length (Bad) = 0 then
               Obj_Put_Str (O, "verdict", "pass");
               Cache_Map := New_Map;
            else
               Obj_Put_Str (O, "verdict", "fail");
               Obj_Put_Str (O, "detail", To_String (Bad));
            end if;
            return O;
         end;
      elsif Cmd = "verify" then
         return Verify_Stress (State_Of (Req));
      elsif Cmd = "fetch" then
         declare
            T : constant String := Fetch
              (State_Of (Req),
               Parse_Coord (Get_Str (Req, "coordinate")));
         begin
            Obj_Put_Str (O, "text_b64", B64_Encode (T));
            Obj_Put_Str (O, "text", Bytes_To_Text (T));
            return O;
         end;
      elsif Cmd = "explode" then
         declare
            Map : constant Scroll_List := Phokenize (State_Of (Req));
            Inner : constant JAccess := New_Obj;
         begin
            for S of Map loop
               Obj_Put_Str (Inner, Coord_Str (S.Pos),
                            B64_Encode (To_String (S.Text)));
            end loop;
            Obj_Put (O, "map", Inner);
            return O;
         end;
      elsif Cmd = "implode" then
         declare
            Inner : constant JAccess := Get (Req, "map");
            List : Scroll_List;
            Data : Unbounded_String;
         begin
            for I in 0 .. Obj_Len (Inner) - 1 loop
               List.Append ((Pos => Parse_Coord (Obj_Key (Inner, I)),
                             Text => To_Unbounded_String
                               (B64_Decode (As_Str
                                  (Obj_Val (Inner, I))))));
            end loop;
            Data := To_Unbounded_String (Dephokenize (List));
            Obj_Put_Str (O, "state_b64", B64_Encode (To_String (Data)));
            Obj_Put_Str (O, "state_sha256",
                         Sha256_Hex (To_String (Data)));
            return O;
         end;
      elsif Cmd = "insert" then
         declare
            Data : constant String := State_Of (Req);
            C : constant Coord :=
              Parse_Coord (Get_Str (Req, "coordinate"));
            Map : constant Scroll_List := Phokenize (Data);
            T : Unbounded_String;
            Out_Data : Unbounded_String;
         begin
            if Map_Find (Map, C, T) then
               Obj_Put_Str (O, "error", "coordinate already occupied");
               return O;
            end if;
            Out_Data := To_Unbounded_String
              (Insert (Data, C, B64_Decode (Get_Str (Req, "text_b64"))));
            Obj_Put_Str (O, "state_b64",
                         B64_Encode (To_String (Out_Data)));
            Obj_Put_Str (O, "state_sha256",
                         Sha256_Hex (To_String (Out_Data)));
            return O;
         end;
      end if;
      raise Program_Error with "unknown cmd " & Cmd;
   end Dispatch;

   --  Game-scale framing (wave-2 pattern): lines over 8 KB may
   --  arrive as "GZ1:" + base64(gzip(line)) over the slow fleet-ssh
   --  channel; large replies are framed the same way. (De)compression
   --  shells to gzip/base64 through a helper script (Fortran
   --  precedent: no zlib binding in play).
   GZ_Script : constant String := "/tmp/tel-ada-gz.sh";

   procedure Ensure_GZ_Script is
      NL : constant String := (1 => Character'Val (10));
   begin
      Write_File (GZ_Script,
        "#!/bin/sh" & NL &
        "if [ $1 = un ]; then" & NL &
        "  sed s/^GZ1:// $2 | base64 -d 2>/dev/null | gzip -dc > $3" & NL &
        "else" & NL &
        "  gzip -c $2 | base64 -w0 > $3" & NL &
        "fi" & NL);
   end Ensure_GZ_Script;

   function GZ_Unframe (Line : String) return String is
      RC : Integer;
   begin
      if Line'Length >= 4 and then Line (Line'First .. Line'First + 3)
        = "GZ1:"
      then
         Write_File ("/tmp/tel-ada-gz.b64", Line);
         RC := Run_Prog ("/bin/sh",
           GZ_Script & " un /tmp/tel-ada-gz.b64 /tmp/tel-ada-req.bin",
           "");
         return Read_File ("/tmp/tel-ada-req.bin");
      end if;
      return Line;
   end GZ_Unframe;

   function GZ_Frame (Resp : String) return String is
      RC : Integer;
   begin
      if Resp'Length > 8192 then
         Write_File ("/tmp/tel-ada-resp.bin", Resp);
         RC := Run_Prog ("/bin/sh",
           GZ_Script & " gz /tmp/tel-ada-resp.bin /tmp/tel-ada-resp.b64",
           "");
         declare
            B64 : constant String := Read_File ("/tmp/tel-ada-resp.b64");
            Last : Natural := B64'Last;
         begin
            while Last >= B64'First and then
              (B64 (Last) = Character'Val (10) or else B64 (Last) = ' ')
            loop
               Last := Last - 1;
            end loop;
            if Last < B64'First then
               return Resp;
            end if;
            return "GZ1:" & B64 (B64'First .. Last);
         end;
      end if;
      return Resp;
   end GZ_Frame;

   procedure Handle_Line (Line : String) is
   begin
      begin
         declare
            Req : constant JAccess := Parse_JSON (GZ_Unframe (Line));
            Resp : constant JAccess := Dispatch (Req);
         begin
            Put_Line (GZ_Frame (Canon (Resp)));
         end;
      exception
         when E : others =>
            declare
               Err : constant JAccess := New_Obj;
            begin
               Obj_Put_Str (Err, "error", "dispatch error");
               Put_Line (Canon (Err));
            end;
      end;
      Flush;
   end Handle_Line;

   Serve_Mode : constant Boolean :=
     Ada.Command_Line.Argument_Count >= 1 and then
     Ada.Command_Line.Argument (1) = "serve";

   Line : Unbounded_String;
   Ch : Integer;
   Saw_Any : Boolean := False;
begin
   Ensure_GZ_Script;
   loop
      Line := Null_Unbounded_String;
      loop
         Ch := Getchar;
         exit when Ch < 0 or else Ch = 10;
         Append (Line, Character'Val (Ch));
         Saw_Any := True;
      end loop;
      if Length (Line) > 0 then
         Handle_Line (To_String (Line));
      end if;
      exit when Ch < 0;
      exit when not Serve_Mode;
   end loop;
end Cli;
