--  libphext-spark -- SPARK port of libphext, 0.6.1 parity.
--
--  The whole package is in SPARK mode: no access types, no aliased
--  heap structures; both scroll stores are built from the standard
--  containers only. Semantics normative from libphext-py: a phext is
--  a byte buffer; nine dimension-break bytes walk a 9-component
--  coordinate; scroll text is a maximal run of non-break bytes
--  (newline is ordinary text). Buffers are Ada Strings used as byte
--  strings.
--  REMOVE is coordinate-preserving: the removed coordinate reads "",
--  neighbours do not shift.
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
with Ada.Containers.Hashed_Maps;

package Phext with SPARK_Mode => On is

   type Coord is array (0 .. 8) of Long_Long_Integer;

   type Scroll is record
      Pos  : Coord;
      Text : Unbounded_String;
   end record;

   package Scroll_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Scroll);
   subtype Scroll_List is Scroll_Vectors.Vector;

   function Coord_Str (C : Coord) return String;
   function Parse_Coord (S : String) return Coord;
   function Root_Coord return Coord;

   function Phokenize (Buf : String) return Scroll_List;
   function Dephokenize (Stack : Scroll_List) return String;
   function Normalize (Buf : String) return String;
   function Fetch (Buf : String; C : Coord) return String;
   function Update (Buf : String; C : Coord; Text : String;
                    Overwrite : Boolean) return String;
   function Insert (Buf : String; C : Coord; Text : String) return String;
   function Replace (Buf : String; C : Coord; Text : String) return String;
   function Remove (Buf : String; C : Coord) return String;

   --  DynamicPhext: capacity-managed dynamic array (double on full,
   --  shrink at quarter-full), kept in coordinate order. Capacity is
   --  tracked explicitly; the backing vector is reserved to Cap.
   type Dyn_Store is tagged private;
   function Dyn_Create (Buf : String) return Dyn_Store;
   function Dyn_Count (D : Dyn_Store) return Natural;
   function Dyn_Capacity (D : Dyn_Store) return Natural;
   function Dyn_Fetch (D : Dyn_Store; C : Coord) return String;
   procedure Dyn_Insert (D : in out Dyn_Store; C : Coord; Text : String);
   procedure Dyn_Replace (D : in out Dyn_Store; C : Coord; Text : String);
   procedure Dyn_Remove (D : in out Dyn_Store; C : Coord);
   function Dyn_Serialize (D : Dyn_Store) return String;

   --  TransitivePhext: transitive closure over a hashed branching
   --  store keyed by the full 9-component coordinate (FNV-1a over the
   --  components); enumeration is always in coordinate order.
   type Trans_Store is tagged private;
   function Trans_Create (Buf : String) return Trans_Store;
   function Trans_Count (D : Trans_Store) return Natural;
   function Trans_Fetch (D : Trans_Store; C : Coord) return String;
   procedure Trans_Insert (D : in out Trans_Store; C : Coord;
                           Text : String);
   procedure Trans_Replace (D : in out Trans_Store; C : Coord;
                            Text : String);
   procedure Trans_Remove (D : in out Trans_Store; C : Coord);
   function Trans_Serialize (D : Trans_Store) return String;

private

   type Dyn_Store is tagged record
      Items : Scroll_List;
      Cap   : Natural := 1;
   end record;

   function Coord_Hash (C : Coord) return Ada.Containers.Hash_Type;

   package Coord_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Coord,
      Element_Type    => Unbounded_String,
      Hash            => Coord_Hash,
      Equivalent_Keys => "=");

   type Trans_Store is tagged record
      Map : Coord_Maps.Map;
   end record;

end Phext;
