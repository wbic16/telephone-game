       IDENTIFICATION DIVISION.
       PROGRAM-ID. TESTPHEXT.
      *> Test suite for libphext-cobol -- plain assertions.
      *> Run: test_phext [fixtures_dir]; fixtures are directories
      *> holding input.phext; each must round-trip byte-identically
      *> (implode(explode(input)) = input) and normalize idempotently.
      *> Covers coordinate-preserving REMOVE, DynamicPhext and
      *> TransitivePhext equivalence with the string API.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT BIN-FILE ASSIGN TO BIN-NAME
               ORGANIZATION IS SEQUENTIAL.
           SELECT DIR-FILE ASSIGN TO "/tmp/tel-cobol-fixtures.txt"
               ORGANIZATION IS LINE SEQUENTIAL.
           SELECT DIR-FILE-2 ASSIGN TO "/tmp/tel-cobol-size.txt"
               ORGANIZATION IS LINE SEQUENTIAL.
       DATA DIVISION.
       FILE SECTION.
       FD BIN-FILE.
       01 BIN-REC        PIC X(8192).
       FD DIR-FILE.
       01 DIR-REC        PIC X(1024).
       FD DIR-FILE-2.
       01 SIZE-REC       PIC X(64).
       WORKING-STORAGE SECTION.
       COPY "phextw.cpy".
       COPY "storesw.cpy".
       01 AP-OP          PIC X(16).
       01 AP-TXT-OFF     PIC 9(9) COMP VALUE 1.
       01 NEW-ARENA      PIC X(1048576).
       01 NEW-LEN        PIC 9(9) COMP VALUE 0.
       01 W-OFF          PIC 9(9) COMP VALUE 0.
       01 W-LEN2         PIC 9(9) COMP VALUE 0.
       01 W-KVAL         PIC 9(9) COMP VALUE 0.
       01 TRN-FOUND      PIC 9(4) COMP VALUE 0.
       01 TRN-CREATE     PIC 9(4) COMP VALUE 0.
       01 TRN-MERGE      PIC 9(4) COMP VALUE 0.
       01 DYN-MERGE      PIC 9(4) COMP VALUE 0.
       01 BIN-NAME       PIC X(1024).
       01 COORD-IN       PIC X(64).
       01 LIT-IN         PIC X(256).
       01 LIT-LEN        PIC 9(9) COMP VALUE 0.
       01 LIT2-IN        PIC X(256).
       01 LIT2-LEN       PIC 9(9) COMP VALUE 0.
       01 CMD-STR        PIC X(4096).
       01 SYS-RC         PIC 9(9) COMP.
       01 CHECKS         PIC 9(9) COMP VALUE 0.
       01 FAILURES       PIC 9(9) COMP VALUE 0.
       01 T-NAME         PIC X(128).
       01 T-A            PIC X(256).
       01 T-ALEN         PIC 9(9) COMP.
       01 T-B            PIC X(256).
       01 T-BLEN         PIC 9(9) COMP.
       01 FX-COUNT       PIC 9(9) COMP VALUE 0.
       01 FX-IDENT       PIC 9(9) COMP VALUE 0.
       01 FX-IDEM        PIC 9(9) COMP VALUE 0.
       01 FX-SIZE        PIC 9(18) COMP.
       01 EOF-FLAG       PIC 9(4) COMP VALUE 0.
       01 FIX-DIR        PIC X(1024).
       01 T-I            PIC 9(9) COMP VALUE 0.
       PROCEDURE DIVISION.
       COPY "phextp.cpy".
       COPY "storesp.cpy".
       MAIN.
           PERFORM T-COORD
           PERFORM T-PHOKENIZE
           PERFORM T-FETCH
           PERFORM T-INSERT
           PERFORM T-REMOVE
           PERFORM T-DYN
           PERFORM T-TRN
           ACCEPT FIX-DIR FROM COMMAND-LINE
           IF FUNCTION TRIM (FIX-DIR) NOT = SPACES
               PERFORM T-FIXTURES
           END-IF
           DISPLAY "cobol suite: " CHECKS " checks, " FAILURES
               " failures"
           IF FAILURES > 0
               STOP RUN RETURNING 1
           END-IF
           STOP RUN.
      *>
       OK.
           ADD 1 TO CHECKS
           IF W-FOUND = 0
               ADD 1 TO FAILURES
               DISPLAY "FAIL: " T-NAME UPON SYSERR
           END-IF
           .
       EQ-BUF.
      *>    T-A/T-ALEN vs T-B/T-BLEN -> OK
           MOVE 1 TO W-FOUND
           IF T-ALEN NOT = T-BLEN
               MOVE 0 TO W-FOUND
           ELSE
               IF T-A (1:T-ALEN) NOT = T-B (1:T-BLEN)
                   MOVE 0 TO W-FOUND
               END-IF
           END-IF
           PERFORM OK
           .
       SET-COORD.
      *>    parse COORD-IN (a.b.c/d.e.f/g.h.i) -> W-TGT
           MOVE 1 TO W-I
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 0 TO W-TGT (W-K)
               PERFORM UNTIL COORD-IN (W-I:1) < '0'
                   OR COORD-IN (W-I:1) > '9'
                   COMPUTE W-TGT (W-K) = W-TGT (W-K) * 10
                       + FUNCTION ORD (COORD-IN (W-I:1))
                       - FUNCTION ORD ('0')
                   ADD 1 TO W-I
               END-PERFORM
               ADD 1 TO W-I
           END-PERFORM
           .
       LOAD-SRC.
      *>    load literal LIT-IN/LIT-LEN into SRC-ARENA as state
           MOVE LIT-IN (1:LIT-LEN) TO SRC-ARENA
           MOVE LIT-LEN TO SRC-LEN
           .
       FETCH-INTO-T.
      *>    fetch coord COORD-IN from current SRC state -> T-A/T-ALEN
           PERFORM SET-COORD
           PERFORM EXPLODE
           PERFORM FETCH-TEXT
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           .
       T-COORD.
           MOVE "coord format round trip" TO T-NAME
           MOVE "1.2.3/4.5.6/7.8.9" TO COORD-IN
           PERFORM SET-COORD
           MOVE 1 TO W-FOUND
           IF W-TGT (1) NOT = 1 OR W-TGT (2) NOT = 2
               OR W-TGT (3) NOT = 3 OR W-TGT (4) NOT = 4
               OR W-TGT (5) NOT = 5 OR W-TGT (6) NOT = 6
               OR W-TGT (7) NOT = 7 OR W-TGT (8) NOT = 8
               OR W-TGT (9) NOT = 9
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           .
       T-PHOKENIZE.
           MOVE "hello" TO LIT-IN
           MOVE 5 TO LIT-LEN
           PERFORM LOAD-SRC
           PERFORM EXPLODE
           MOVE "one scroll" TO T-NAME
           IF SC-N = 1
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           MOVE "a" & X"17" & "b" & X"17" & X"17" & "c" & X"0A"
               & "line2" TO LIT-IN
           MOVE 10 TO LIT-LEN
           PERFORM LOAD-SRC
           PERFORM EXPLODE
           MOVE "scroll breaks" TO T-NAME
           IF SC-N = 3
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           MOVE "gap coord advance" TO T-NAME
           IF SC-COORD (3, 9) = 4
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           MOVE "round trip sample" TO T-NAME
           PERFORM IMPLODE
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE LIT-IN (1:LIT-LEN) TO T-B
           MOVE LIT-LEN TO T-BLEN
           PERFORM EQ-BUF
           .
       T-FETCH.
           MOVE "one" & X"17" & "two" & X"17" & X"17" & "four"
               TO LIT-IN
           MOVE 13 TO LIT-LEN
           PERFORM LOAD-SRC
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "fetch 1" TO T-NAME
           MOVE "one" TO T-B
           MOVE 3 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.4" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "fetch 4" TO T-NAME
           MOVE "four" TO T-B
           MOVE 4 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.3" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "gap fetch is empty" TO T-NAME
           MOVE 0 TO T-BLEN
           PERFORM EQ-BUF
           .
       APPLY-LIT.
      *>    apply AP-OP at COORD-IN with text LIT2-IN/LIT2-LEN to
      *>    the current SRC state; result -> SRC (via DST)
           PERFORM SET-COORD
           PERFORM EXPLODE
           MOVE LIT2-IN (1:LIT2-LEN) TO TXT-ARENA
           MOVE LIT2-LEN TO TXT-LEN
           MOVE 1 TO AP-TXT-OFF
           PERFORM APPLY-STEP-TXT
           PERFORM IMPLODE
           MOVE DST-ARENA (1:DST-LEN) TO SRC-ARENA
           MOVE DST-LEN TO SRC-LEN
           .
       T-INSERT.
           MOVE "base" TO LIT-IN
           MOVE 4 TO LIT-LEN
           PERFORM LOAD-SRC
           MOVE "insert" TO AP-OP
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           MOVE "+more" TO LIT2-IN
           MOVE 5 TO LIT2-LEN
           PERFORM APPLY-LIT
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "insert appends after existing" TO T-NAME
           MOVE "base+more" TO T-B
           MOVE 9 TO T-BLEN
           PERFORM EQ-BUF
           MOVE SPACES TO LIT-IN
           MOVE 0 TO LIT-LEN
           PERFORM LOAD-SRC
           MOVE "insert" TO AP-OP
           MOVE "1.1.1/1.1.1/1.1.3" TO COORD-IN
           MOVE "new" TO LIT2-IN
           MOVE 3 TO LIT2-LEN
           PERFORM APPLY-LIT
           MOVE "insert at gap emits breaks" TO T-NAME
           MOVE X"17" & X"17" & "new" TO T-B
           MOVE 5 TO T-BLEN
           MOVE SRC-ARENA (1:SRC-LEN) TO T-A
           MOVE SRC-LEN TO T-ALEN
           PERFORM EQ-BUF
           .
       T-REMOVE.
           MOVE "a" & X"17" & "b" & X"17" & "c" TO LIT-IN
           MOVE 5 TO LIT-LEN
           PERFORM LOAD-SRC
           MOVE "remove" TO AP-OP
           MOVE "1.1.1/1.1.1/1.1.2" TO COORD-IN
           MOVE 0 TO LIT2-LEN
           PERFORM APPLY-LIT
           MOVE "remove leaves a gap" TO T-NAME
           MOVE "a" & X"17" & X"17" & "c" TO T-B
           MOVE 4 TO T-BLEN
           MOVE SRC-ARENA (1:SRC-LEN) TO T-A
           MOVE SRC-LEN TO T-ALEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.2" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "removed coordinate reads empty" TO T-NAME
           MOVE 0 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.3" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "neighbour keeps its coordinate" TO T-NAME
           MOVE "c" TO T-B
           MOVE 1 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM FETCH-INTO-T
           MOVE "earlier neighbour unchanged" TO T-NAME
           MOVE "a" TO T-B
           MOVE 1 TO T-BLEN
           PERFORM EQ-BUF
           .
       T-DYN.
      *>    load a/b/c via string path, then dyn ops
           MOVE 0 TO DYN-N
           MOVE 1 TO DYN-CAP
           MOVE 0 TO TXT-USED
           MOVE "a" & X"17" & "b" & X"17" & "c" TO LIT-IN
           MOVE 5 TO LIT-LEN
           PERFORM LOAD-SRC
           PERFORM EXPLODE
           PERFORM VARYING T-I FROM 1 BY 1 UNTIL T-I > SC-N
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE SC-COORD (T-I, W-K) TO W-TGT (W-K)
               END-PERFORM
               MOVE T-I TO W-IDX
               PERFORM FETCH-TEXT
               MOVE DST-ARENA (1:DST-LEN) TO NEW-ARENA
               MOVE DST-LEN TO NEW-LEN
               PERFORM DYN-REPLACE
           END-PERFORM
           MOVE "1.1.1/1.1.1/1.1.2" TO COORD-IN
           PERFORM SET-COORD
           PERFORM DYN-FETCH
           MOVE "dyn fetch" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE "b" TO T-B
           MOVE 1 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "!" TO NEW-ARENA
           MOVE 1 TO NEW-LEN
           PERFORM DYN-INSERT
           PERFORM DYN-FETCH
           MOVE "dyn insert merges" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE "b!" TO T-B
           MOVE 2 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.5" TO COORD-IN
           PERFORM SET-COORD
           MOVE "deep" TO NEW-ARENA
           MOVE 4 TO NEW-LEN
           PERFORM DYN-REPLACE
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM SET-COORD
           PERFORM DYN-REMOVE
           PERFORM DYN-FETCH
           MOVE "dyn remove is a gap" TO T-NAME
           MOVE 0 TO T-BLEN
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.3" TO COORD-IN
           PERFORM SET-COORD
           PERFORM DYN-FETCH
           MOVE "dyn neighbour unshifted" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE "c" TO T-B
           MOVE 1 TO T-BLEN
           PERFORM EQ-BUF
           PERFORM DYN-SERIALIZE
           MOVE "dyn serialize = string path" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE X"17" & "b!" & X"17" & "c" & X"17" & X"17"
               & "deep" TO T-B
           MOVE 11 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "dyn capacity >= count" TO T-NAME
           IF DYN-CAP >= DYN-N
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           .
       T-TRN.
           PERFORM TRN-INIT
           MOVE "a" & X"17" & "b" & X"17" & "c" TO LIT-IN
           MOVE 5 TO LIT-LEN
           PERFORM LOAD-SRC
           PERFORM EXPLODE
           PERFORM VARYING T-I FROM 1 BY 1 UNTIL T-I > SC-N
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE SC-COORD (T-I, W-K) TO W-TGT (W-K)
               END-PERFORM
               MOVE T-I TO W-IDX
               PERFORM FETCH-TEXT
               MOVE DST-ARENA (1:DST-LEN) TO NEW-ARENA
               MOVE DST-LEN TO NEW-LEN
               PERFORM TRN-REPLACE
           END-PERFORM
           MOVE "1.1.1/1.1.1/1.1.3" TO COORD-IN
           PERFORM SET-COORD
           PERFORM TRN-FETCH
           MOVE "trans fetch" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE "c" TO T-B
           MOVE 1 TO T-BLEN
           PERFORM EQ-BUF
           MOVE "1.1.1/1.1.1/1.1.2" TO COORD-IN
           PERFORM SET-COORD
           MOVE "!" TO NEW-ARENA
           MOVE 1 TO NEW-LEN
           PERFORM TRN-INSERT
           MOVE "2.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM SET-COORD
           MOVE "lib2" TO NEW-ARENA
           MOVE 4 TO NEW-LEN
           PERFORM TRN-REPLACE
           MOVE "1.1.1/1.1.1/1.1.1" TO COORD-IN
           PERFORM SET-COORD
           PERFORM TRN-REMOVE
           PERFORM TRN-FETCH
           MOVE "trans remove is a gap" TO T-NAME
           MOVE 0 TO T-BLEN
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           PERFORM EQ-BUF
           PERFORM TRN-SERIALIZE
           MOVE "trans serialize = string path" TO T-NAME
           MOVE DST-ARENA (1:DST-LEN) TO T-A
           MOVE DST-LEN TO T-ALEN
           MOVE X"17" & "b!" & X"17" & "c" & X"01" & "lib2"
               TO T-B
           MOVE 10 TO T-BLEN
           PERFORM EQ-BUF
           .
       T-FIXTURES.
           STRING "find " DELIMITED BY SIZE
               FUNCTION TRIM (FIX-DIR) DELIMITED BY SIZE
               " -name input.phext | sort > "
               "/tmp/tel-cobol-fixtures.txt" DELIMITED BY SIZE
               INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           OPEN INPUT DIR-FILE
           MOVE 0 TO EOF-FLAG
           PERFORM UNTIL EOF-FLAG = 1
               READ DIR-FILE
                   AT END MOVE 1 TO EOF-FLAG
                   NOT AT END PERFORM T-FIXTURE-ONE
               END-READ
           END-PERFORM
           CLOSE DIR-FILE
           DISPLAY "fixtures: " FX-IDENT "/" FX-COUNT
               " byte-identical, " FX-IDEM "/" FX-COUNT
               " normalize-idempotent"
           MOVE "fixtures all byte-identical" TO T-NAME
           IF FX-IDENT = FX-COUNT AND FX-COUNT > 0
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           MOVE "fixture count is 16" TO T-NAME
           IF FX-COUNT = 16
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           PERFORM OK
           .
       T-FIXTURE-ONE.
           MOVE FUNCTION TRIM (DIR-REC) TO BIN-NAME
           STRING "stat -c %s " DELIMITED BY SIZE
               FUNCTION TRIM (BIN-NAME) DELIMITED BY SIZE
               " > /tmp/tel-cobol-size.txt" DELIMITED BY SIZE
               INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           CALL "SYSTEM" USING
               "cat /tmp/tel-cobol-size.txt > /tmp/tel-cobol-size2.txt"
               RETURNING SYS-RC
           OPEN INPUT DIR-FILE-2
           READ DIR-FILE-2
               AT END MOVE 0 TO FX-SIZE
               NOT AT END
                   COMPUTE FX-SIZE = FUNCTION NUMVAL (SIZE-REC)
           END-READ
           CLOSE DIR-FILE-2
           ADD 1 TO FX-COUNT
      *>    read file in 8192 chunks into SRC-ARENA
           MOVE 0 TO SRC-LEN
           OPEN INPUT BIN-FILE
           PERFORM UNTIL SRC-LEN >= FX-SIZE
               READ BIN-FILE
                   AT END EXIT PERFORM
                   NOT AT END
                       IF FX-SIZE - SRC-LEN >= 8192
                           MOVE BIN-REC TO SRC-ARENA
                               (SRC-LEN + 1:8192)
                           ADD 8192 TO SRC-LEN
                       ELSE
                           MOVE BIN-REC
                               TO SRC-ARENA (SRC-LEN + 1:
                                   FX-SIZE - SRC-LEN)
                           COMPUTE SRC-LEN = FX-SIZE
                       END-IF
               END-READ
           END-PERFORM
           CLOSE BIN-FILE
           PERFORM EXPLODE
           PERFORM IMPLODE
           IF DST-LEN = SRC-LEN
               AND DST-ARENA (1:DST-LEN) = SRC-ARENA (1:SRC-LEN)
               ADD 1 TO FX-IDENT
           ELSE
               DISPLAY "fixture round-trip differs: " BIN-NAME
                   UPON SYSERR
           END-IF
      *>    idempotent: normalize again (explode DST, implode)
           MOVE DST-ARENA (1:DST-LEN) TO SRC-ARENA
           MOVE DST-LEN TO SRC-LEN
           PERFORM EXPLODE
           PERFORM IMPLODE
           MOVE DST-ARENA (1:DST-LEN) TO CAC-ARENA
           MOVE DST-LEN TO CAC-LEN
           PERFORM EXPLODE
           PERFORM IMPLODE
           IF DST-ARENA (1:DST-LEN) = CAC-ARENA (1:CAC-LEN)
               AND DST-LEN = CAC-LEN
               ADD 1 TO FX-IDEM
           END-IF
           .
