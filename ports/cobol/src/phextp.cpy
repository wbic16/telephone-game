*> Paragraphs (include in PROCEDURE DIVISION):
       COORD-CMP.
      *>    compares CA-COORD vs CB-COORD -> CMP-RES -1/0/1
           MOVE 0 TO CMP-RES
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               IF CMP-RES = 0
                   IF CA-COORD (W-K) < CB-COORD (W-K)
                       MOVE -1 TO CMP-RES
                   ELSE
                       IF CA-COORD (W-K) > CB-COORD (W-K)
                           MOVE 1 TO CMP-RES
                       END-IF
                   END-IF
               END-IF
           END-PERFORM
           .
       BREAK-DIM.
      *>    W-BYTE -> W-D (0 if not a break, else dimension 1..9)
           MOVE 0 TO W-D
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               IF W-D = 0 AND W-BYTE = BRK-TAB (W-K)
                   MOVE W-K TO W-D
               END-IF
           END-PERFORM
           .
       APPLY-BREAK.
      *>    W-COORD advanced at dimension W-D
           ADD 1 TO W-COORD (W-D)
           PERFORM VARYING W-K FROM W-D BY 1 UNTIL W-K > 9
               IF W-K > W-D
                   MOVE 1 TO W-COORD (W-K)
               END-IF
           END-PERFORM
           .
       EXPLODE.
      *>    SRC-ARENA/SRC-LEN -> SC-TABLE (slices of SRC-ARENA)
           MOVE 0 TO SC-N
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 1 TO W-COORD (W-K)
           END-PERFORM
           MOVE 1 TO W-I
           MOVE 1 TO W-J
           PERFORM UNTIL W-I > SRC-LEN
               MOVE SRC-ARENA (W-I:1) TO W-BYTE
               PERFORM BREAK-DIM
               IF W-D > 0
                   IF W-I > W-J
                       ADD 1 TO SC-N
                       PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                           MOVE W-COORD (W-K) TO SC-COORD (SC-N, W-K)
                       END-PERFORM
                       MOVE 1 TO SC-SRC (SC-N)
                       MOVE W-J TO SC-OFF (SC-N)
                       COMPUTE SC-LEN (SC-N) = W-I - W-J
                       MOVE 0 TO SC-OFF2 (SC-N) SC-LEN2 (SC-N)
                   END-IF
                   PERFORM APPLY-BREAK
                   COMPUTE W-J = W-I + 1
               END-IF
               ADD 1 TO W-I
           END-PERFORM
           IF SRC-LEN >= W-J
               ADD 1 TO SC-N
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE W-COORD (W-K) TO SC-COORD (SC-N, W-K)
               END-PERFORM
               MOVE 1 TO SC-SRC (SC-N)
               MOVE W-J TO SC-OFF (SC-N)
               COMPUTE SC-LEN (SC-N) = SRC-LEN - W-J + 1
               MOVE 0 TO SC-OFF2 (SC-N) SC-LEN2 (SC-N)
           END-IF
           .
       FIND-COORD.
      *>    W-TGT -> W-FOUND (1/0), W-IDX = entry index when found
           MOVE 0 TO W-FOUND
           MOVE 0 TO W-IDX
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > SC-N
               IF W-FOUND = 0
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE SC-COORD (W-I, W-K) TO CA-COORD (W-K)
                       MOVE W-TGT (W-K) TO CB-COORD (W-K)
                   END-PERFORM
                   PERFORM COORD-CMP
                   IF CMP-RES = 0
                       MOVE 1 TO W-FOUND
                       MOVE W-I TO W-IDX
                   END-IF
               END-IF
           END-PERFORM
           .
       SORT-IDX.
      *>    insertion sort of SC-IDX by coordinate
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > SC-N
               MOVE W-I TO SC-IDX (W-I)
           END-PERFORM
           PERFORM VARYING W-I FROM 2 BY 1 UNTIL W-I > SC-N
               MOVE SC-IDX (W-I) TO W-IDX
               COMPUTE W-J = W-I - 1
               MOVE 0 TO W-FOUND
               PERFORM UNTIL W-J < 1 OR W-FOUND = 1
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE SC-COORD (SC-IDX (W-J), W-K)
                           TO CA-COORD (W-K)
                       MOVE SC-COORD (W-IDX, W-K) TO CB-COORD (W-K)
                   END-PERFORM
                   PERFORM COORD-CMP
                   IF CMP-RES > 0
                       MOVE SC-IDX (W-J) TO SC-IDX (W-J + 1)
                       COMPUTE W-J = W-J - 1
                   ELSE
                       MOVE 1 TO W-FOUND
                   END-IF
               END-PERFORM
               MOVE W-IDX TO SC-IDX (W-J + 1)
           END-PERFORM
           .
       ADVANCE.
      *>    W-LOC -> W-TGT: append break bytes to DST-ARENA
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE W-LOC (W-K) TO CA-COORD (W-K)
               MOVE W-TGT (W-K) TO CB-COORD (W-K)
           END-PERFORM
           PERFORM COORD-CMP
           IF CMP-RES < 0
               MOVE 1 TO W-D
               PERFORM UNTIL W-LOC (W-D) NOT = W-TGT (W-D)
                   ADD 1 TO W-D
               END-PERFORM
               PERFORM VARYING W-J FROM 1 BY 1
                   UNTIL W-J > W-TGT (W-D) - W-LOC (W-D)
                   ADD 1 TO DST-LEN
                   MOVE BRK-TAB (W-D) TO DST-ARENA (DST-LEN:1)
               END-PERFORM
               MOVE W-TGT (W-D) TO W-LOC (W-D)
               PERFORM VARYING W-K FROM W-D BY 1 UNTIL W-K > 9
                   IF W-K > W-D
                       MOVE 1 TO W-LOC (W-K)
                   END-IF
               END-PERFORM
               PERFORM VARYING W-K FROM W-D BY 1 UNTIL W-K > 9
                   IF W-K > W-D
                       PERFORM VARYING W-J FROM 1 BY 1
                           UNTIL W-J > W-TGT (W-K) - 1
                           ADD 1 TO DST-LEN
                           MOVE BRK-TAB (W-K) TO DST-ARENA (DST-LEN:1)
                       END-PERFORM
                       MOVE W-TGT (W-K) TO W-LOC (W-K)
                   END-IF
               END-PERFORM
           END-IF
           .
       IMPLODE.
      *>    SC-TABLE -> DST-ARENA (canonical bytes; empty scrolls
      *>    contribute nothing, so removed coordinates leave gaps)
           MOVE 0 TO DST-LEN
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 1 TO W-LOC (W-K)
           END-PERFORM
           PERFORM SORT-IDX
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > SC-N
               MOVE SC-IDX (W-I) TO W-IDX
               IF SC-LEN (W-IDX) + SC-LEN2 (W-IDX) > 0
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE SC-COORD (W-IDX, W-K) TO W-TGT (W-K)
                   END-PERFORM
                   PERFORM ADVANCE
                   IF SC-SRC (W-IDX) = 1 OR SC-SRC (W-IDX) = 3
                       MOVE SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                           TO DST-ARENA (DST-LEN + 1:SC-LEN (W-IDX))
                       ADD SC-LEN (W-IDX) TO DST-LEN
                   END-IF
                   IF SC-SRC (W-IDX) = 2
                       MOVE TXT-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                           TO DST-ARENA (DST-LEN + 1:SC-LEN (W-IDX))
                       ADD SC-LEN (W-IDX) TO DST-LEN
                   END-IF
                   IF SC-SRC (W-IDX) = 3
                       MOVE TXT-ARENA
                           (SC-OFF2 (W-IDX):SC-LEN2 (W-IDX))
                           TO DST-ARENA (DST-LEN + 1:SC-LEN2 (W-IDX))
                       ADD SC-LEN2 (W-IDX) TO DST-LEN
                   END-IF
               END-IF
           END-PERFORM
           .
       FETCH-TEXT.
      *>    W-TGT -> text copied to DST-ARENA, DST-LEN (0 if gap)
           MOVE 0 TO DST-LEN
           PERFORM FIND-COORD
           IF W-FOUND = 1
               IF SC-SRC (W-IDX) = 1 OR SC-SRC (W-IDX) = 3
                   MOVE SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                       TO DST-ARENA (1:SC-LEN (W-IDX))
                   MOVE SC-LEN (W-IDX) TO DST-LEN
               END-IF
               IF SC-SRC (W-IDX) = 2
                   MOVE TXT-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                       TO DST-ARENA (1:SC-LEN (W-IDX))
                   MOVE SC-LEN (W-IDX) TO DST-LEN
               END-IF
               IF SC-SRC (W-IDX) = 3
                   MOVE TXT-ARENA (SC-OFF2 (W-IDX):SC-LEN2 (W-IDX))
                       TO DST-ARENA (DST-LEN + 1:SC-LEN2 (W-IDX))
                   ADD SC-LEN2 (W-IDX) TO DST-LEN
               END-IF
           END-IF
           .
       APPLY-STEP-TXT.
      *>    OP in AP-OP ("insert"/"replace"/"remove"), coord in
      *>    W-TGT, step text in TXT-ARENA/TXT-LEN. Updates SC-TABLE;
      *>    caller IMPLODEs. Insert at an existing coordinate appends
      *>    the new text after the existing scroll (libphext-py).
           PERFORM FIND-COORD
           IF AP-OP = "remove"
               IF W-FOUND = 1
                   MOVE 0 TO SC-LEN (W-IDX) SC-LEN2 (W-IDX)
               END-IF
           ELSE
               IF W-FOUND = 1
                   IF AP-OP = "insert"
                       IF SC-SRC (W-IDX) = 2
      *>                    existing text already in TXT at OFF/LEN;
      *>                    step text follows it in TXT (caller laid
      *>                    out TXT as existing||new is NOT assumed) --
      *>                    treat as replace-with-concat is caller's
      *>                    job; here: keep src slice, add second slice
                           MOVE 3 TO SC-SRC (W-IDX)
                           MOVE TXT-LEN TO SC-LEN2 (W-IDX)
                           MOVE AP-TXT-OFF TO SC-OFF2 (W-IDX)
                       ELSE
                           MOVE 3 TO SC-SRC (W-IDX)
                           MOVE AP-TXT-OFF TO SC-OFF2 (W-IDX)
                           MOVE TXT-LEN TO SC-LEN2 (W-IDX)
                       END-IF
                   ELSE
                       MOVE 2 TO SC-SRC (W-IDX)
                       MOVE AP-TXT-OFF TO SC-OFF (W-IDX)
                       MOVE TXT-LEN TO SC-LEN (W-IDX)
                       MOVE 0 TO SC-LEN2 (W-IDX)
                   END-IF
               ELSE
                   ADD 1 TO SC-N
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE W-TGT (W-K) TO SC-COORD (SC-N, W-K)
                   END-PERFORM
                   MOVE 2 TO SC-SRC (SC-N)
                   MOVE AP-TXT-OFF TO SC-OFF (SC-N)
                   MOVE TXT-LEN TO SC-LEN (SC-N)
                   MOVE 0 TO SC-LEN2 (SC-N)
               END-IF
           END-IF
           .
