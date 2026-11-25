      *> libphext-cobol -- GnuCOBOL port of libphext, 0.6.1 parity.
      *> Core storage + paragraphs, COPY-included by the hub CLI and
      *> by the native test program. Semantics normative from
      *> libphext-py: a phext is a byte buffer; nine dimension-break
      *> bytes walk a 9-component coordinate; scroll text is a maximal
      *> run of non-break bytes (newline is ordinary text).
      *> Scrolls live in a table of (coordinate, arena offset, length)
      *> over byte arenas -- no per-scroll text copies. REMOVE is
      *> coordinate-preserving: the removed coordinate reads "",
      *> neighbours do not shift (remove = replace "" + normalize,
      *> i.e. the entry's length drops to zero and implode skips it,
      *> leaving the break gap in the output).
      *>
      *> Working-storage (include in WORKING-STORAGE SECTION):
       78 MAXS        VALUE 8192.
       01 SRC-ARENA   PIC X(16777216).
       01 SRC-LEN     PIC 9(9) COMP VALUE 0.
       01 DST-ARENA   PIC X(16777216).
       01 DST-LEN     PIC 9(9) COMP VALUE 0.
       01 TXT-ARENA   PIC X(1048576).
       01 TXT-LEN     PIC 9(9) COMP VALUE 0.
       01 SC-N        PIC 9(9) COMP VALUE 0.
       01 SC-TABLE.
           05 SC-ENTRY OCCURS MAXS TIMES.
               10 SC-COORD PIC 9(9) COMP OCCURS 9 TIMES.
               10 SC-SRC   PIC 9(4) COMP.
      *>        SRC: 1 = slice of SRC-ARENA at OFF/LEN
      *>             2 = slice of TXT-ARENA at OFF/LEN
      *>             3 = SRC-ARENA slice OFF/LEN then TXT slice OFF2/LEN2
               10 SC-OFF   PIC 9(9) COMP.
               10 SC-LEN   PIC 9(9) COMP.
               10 SC-OFF2  PIC 9(9) COMP.
               10 SC-LEN2  PIC 9(9) COMP.
       01 SC-IDX      OCCURS MAXS TIMES PIC 9(9) COMP.
      *> cache table (init/validate): a second table + arena copy
       01 CAC-ARENA   PIC X(16777216).
       01 CAC-LEN     PIC 9(9) COMP VALUE 0.
       01 CAC-N       PIC 9(9) COMP VALUE 0.
       01 CAC-TABLE.
           05 CAC-ENTRY OCCURS MAXS TIMES.
               10 CAC-COORD PIC 9(9) COMP OCCURS 9 TIMES.
               10 CAC-OFF   PIC 9(9) COMP.
               10 CAC-LEN-E PIC 9(9) COMP.
      *> scratch
       01 W-COORD     PIC 9(9) COMP OCCURS 9 TIMES.
       01 W-LOC       PIC 9(9) COMP OCCURS 9 TIMES.
       01 W-TGT       PIC 9(9) COMP OCCURS 9 TIMES.
       01 W-I         PIC 9(9) COMP.
       01 W-J         PIC 9(9) COMP.
       01 W-K         PIC 9(9) COMP.
       01 W-D         PIC S9(9) COMP.
       01 W-BYTE      PIC X.
       01 W-FOUND     PIC 9(4) COMP.
       01 W-IDX       PIC 9(9) COMP.
       01 CMP-RES     PIC S9(4) COMP.
       01 CA-COORD    PIC 9(9) COMP OCCURS 9 TIMES.
       01 CB-COORD    PIC 9(9) COMP OCCURS 9 TIMES.
       01 BRK-BYTES.
           05 BRK-1 PIC X VALUE X"01".
           05 BRK-2 PIC X VALUE X"1F".
           05 BRK-3 PIC X VALUE X"1E".
           05 BRK-4 PIC X VALUE X"1D".
           05 BRK-5 PIC X VALUE X"1C".
           05 BRK-6 PIC X VALUE X"1A".
           05 BRK-7 PIC X VALUE X"19".
           05 BRK-8 PIC X VALUE X"18".
           05 BRK-9 PIC X VALUE X"17".
       01 BRK-TAB REDEFINES BRK-BYTES PIC X OCCURS 9 TIMES.
      *>
      