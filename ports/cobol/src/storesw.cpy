      *> DynamicPhext + TransitivePhext for libphext-cobol.
      *> COPY-included after phext.cpy (shares its scratch + TXT-ARENA
      *> as the text store: slices are offsets into TXT-ARENA with a
      *> bump pointer TXT-USED; superseded slices are abandoned, the
      *> classic append-only arena trade).
      *>
      *> Working-storage additions:
       01 TXT-USED    PIC 9(9) COMP VALUE 0.
      *> DynamicPhext: dynamic array, capacity doubles when full on
      *> append, halves when the load drops to one quarter.
       01 DYN-N       PIC 9(9) COMP VALUE 0.
       01 DYN-CAP     PIC 9(9) COMP VALUE 1.
       01 DYN-RESIZES PIC 9(9) COMP VALUE 0.
       01 DYN-COPIED  PIC 9(9) COMP VALUE 0.
       01 DYN-TABLE.
           05 DYN-ENTRY OCCURS 4096 TIMES.
               10 DYN-COORD PIC 9(9) COMP OCCURS 9 TIMES.
               10 DYN-OFF   PIC 9(9) COMP.
               10 DYN-LEN   PIC 9(9) COMP.
      *> TransitivePhext: node table; each node is one branch of the
      *> 9-level map (parent index + component key + depth). Leaves at
      *> depth 9 hold text slices in TXT-ARENA.
       01 TRN-N       PIC 9(9) COMP VALUE 1.
       01 TRN-COUNT   PIC 9(9) COMP VALUE 0.
       01 TRN-TABLE.
           05 TRN-ENTRY OCCURS 8192 TIMES.
               10 TRN-KEY    PIC 9(9) COMP.
               10 TRN-PARENT PIC 9(9) COMP.
               10 TRN-DEPTH  PIC 9(9) COMP.
               10 TRN-LEAF   PIC 9(4) COMP.
               10 TRN-OFF    PIC 9(9) COMP.
               10 TRN-LEN    PIC 9(9) COMP.
       01 TRN-NODE    PIC 9(9) COMP.
       01 TRN-D       PIC 9(9) COMP.
      *>
      