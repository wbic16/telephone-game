--  libphext-ada -- Ada port of libphext, 0.6.1 parity.
--  Semantics normative from libphext-py: a phext is a byte buffer;
--  nine dimension-break bytes walk a 9-component coordinate; scroll
--  text is a maximal run of non-break bytes (newline is ordinary
--  text). Buffers are Ada Strings used as byte strings.
--  REMOVE is coordinate-preserving: the removed coordinate reads "",
--  neighbours do not shift.
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;

package Phext is

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
   --  shrink at quarter-full), kept in coordinate order.
   type Dyn_Store is tagged private;
   function Dyn_Create (Buf : String) return Dyn_Store;
   function Dyn_Count (D : Dyn_Store) return Natural;
   function Dyn_Capacity (D : Dyn_Store) return Natural;
   function Dyn_Fetch (D : Dyn_Store; C : Coord) return String;
   procedure Dyn_Insert (D : in out Dyn_Store; C : Coord; Text : String);
   procedure Dyn_Replace (D : in out Dyn_Store; C : Coord; Text : String);
   procedure Dyn_Remove (D : in out Dyn_Store; C : Coord);
   function Dyn_Serialize (D : Dyn_Store) return String;

   --  TransitivePhext: 9-level branching map -- a tree of nodes, one
   --  level per dimension; each node maps a component value to a
   --  child node (children held as a sibling list at each branch).
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
   type Scroll_Array is array (Natural range <>) of Scroll;
   type Scroll_Array_Access is access Scroll_Array;
   type Dyn_Store is tagged record
      Items           : Scroll_Array_Access := new Scroll_Array (0 .. 0);
      N               : Natural := 0;
      Cap             : Natural := 1;
      Resize_Count    : Natural := 0;
      Elements_Copied : Natural := 0;
   end record;

   type Node;
   type Node_Access is access Node;
   type Node is record
      Key          : Long_Long_Integer := 0;
      Is_Leaf      : Boolean := False;
      Leaf         : Unbounded_String;
      First_Child  : Node_Access := null;
      Next_Sibling : Node_Access := null;
   end record;

   type Trans_Store is tagged record
      Root : Node_Access := new Node;
      N    : Natural := 0;
   end record;

end Phext;
