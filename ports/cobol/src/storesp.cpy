*> Paragraphs:
       TXT-STORE.
      *>    append TXT-ARENA content? No: store the slice currently in
      *>    DST-ARENA/DST-LEN at the bump pointer -> W-OFF, W-LEN2 out
      *>    (uses W-OFF/W-LEN2 scratch declared by includer)
           MOVE TXT-USED TO W-OFF
           COMPUTE TXT-USED = TXT-USED + DST-LEN
           MOVE DST-ARENA (1:DST-LEN) TO TXT-ARENA (W-OFF + 1:DST-LEN)
           MOVE DST-LEN TO W-LEN2
           .
       DYN-FIND.
      *>    W-TGT -> W-FOUND, W-IDX (insertion point when not found)
           MOVE 0 TO W-FOUND
           MOVE 0 TO W-IDX
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > DYN-N
               IF W-FOUND = 0 AND W-IDX = 0
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE DYN-COORD (W-I, W-K) TO CA-COORD (W-K)
                       MOVE W-TGT (W-K) TO CB-COORD (W-K)
                   END-PERFORM
                   PERFORM COORD-CMP
                   IF CMP-RES = 0
                       MOVE 1 TO W-FOUND
                       MOVE W-I TO W-IDX
                   ELSE
                       IF CMP-RES > 0
                           MOVE W-I TO W-IDX
                       END-IF
                   END-IF
               END-IF
           END-PERFORM
           IF W-FOUND = 0 AND W-IDX = 0
               COMPUTE W-IDX = DYN-N + 1
           END-IF
           .
       DYN-FETCH.
      *>    W-TGT -> DST-ARENA/DST-LEN
           MOVE 0 TO DST-LEN
           PERFORM DYN-FIND
           IF W-FOUND = 1
               MOVE TXT-ARENA (DYN-OFF (W-IDX) + 1:DYN-LEN (W-IDX))
                   TO DST-ARENA (1:DYN-LEN (W-IDX))
               MOVE DYN-LEN (W-IDX) TO DST-LEN
           END-IF
           .
       DYN-PUT.
      *>    text in NEW-ARENA/NEW-LEN (includer scratch), coord W-TGT;
      *>    DYN-MERGE = 1 to append after existing, 0 to replace
           PERFORM DYN-FIND
           IF W-FOUND = 1
               IF DYN-MERGE = 1
      *>            new slice = old slice bytes + new text
                   MOVE TXT-ARENA (DYN-OFF (W-IDX) + 1:DYN-LEN (W-IDX))
                       TO DST-ARENA (1:DYN-LEN (W-IDX))
                   MOVE DYN-LEN (W-IDX) TO DST-LEN
                   MOVE NEW-ARENA (1:NEW-LEN)
                       TO DST-ARENA (DST-LEN + 1:NEW-LEN)
                   ADD NEW-LEN TO DST-LEN
                   PERFORM TXT-STORE
                   MOVE W-OFF TO DYN-OFF (W-IDX)
                   MOVE W-LEN2 TO DYN-LEN (W-IDX)
               ELSE
                   MOVE NEW-ARENA (1:NEW-LEN) TO DST-ARENA (1:NEW-LEN)
                   MOVE NEW-LEN TO DST-LEN
                   PERFORM TXT-STORE
                   MOVE W-OFF TO DYN-OFF (W-IDX)
                   MOVE W-LEN2 TO DYN-LEN (W-IDX)
               END-IF
           ELSE
               IF DYN-N = DYN-CAP
                   COMPUTE DYN-CAP = DYN-CAP * 2
                   ADD 1 TO DYN-RESIZES
                   ADD DYN-N TO DYN-COPIED
               END-IF
               PERFORM VARYING W-J FROM DYN-N BY -1
                   UNTIL W-J < W-IDX
                   MOVE DYN-ENTRY (W-J) TO DYN-ENTRY (W-J + 1)
               END-PERFORM
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE W-TGT (W-K) TO DYN-COORD (W-IDX, W-K)
               END-PERFORM
               MOVE NEW-ARENA (1:NEW-LEN) TO DST-ARENA (1:NEW-LEN)
               MOVE NEW-LEN TO DST-LEN
               PERFORM TXT-STORE
               MOVE W-OFF TO DYN-OFF (W-IDX)
               MOVE W-LEN2 TO DYN-LEN (W-IDX)
               ADD 1 TO DYN-N
           END-IF
           .
       DYN-INSERT.
           IF NEW-LEN > 0
               MOVE 1 TO DYN-MERGE
               PERFORM DYN-PUT
           END-IF
           .
       DYN-REPLACE.
           IF NEW-LEN = 0
               PERFORM DYN-REMOVE
           ELSE
               MOVE 0 TO DYN-MERGE
               PERFORM DYN-PUT
           END-IF
           .
       DYN-REMOVE.
           PERFORM DYN-FIND
           IF W-FOUND = 1
               PERFORM VARYING W-J FROM W-IDX BY 1
                   UNTIL W-J >= DYN-N
                   MOVE DYN-ENTRY (W-J + 1) TO DYN-ENTRY (W-J)
               END-PERFORM
               SUBTRACT 1 FROM DYN-N
               IF DYN-CAP > 1 AND DYN-N <= DYN-CAP / 4
                   COMPUTE DYN-CAP = FUNCTION MAX(1, DYN-CAP / 2)
                   ADD 1 TO DYN-RESIZES
                   ADD DYN-N TO DYN-COPIED
               END-IF
           END-IF
           .
       DYN-SERIALIZE.
      *>    load SC-TABLE from DYN entries (already sorted), IMPLODE
           MOVE DYN-N TO SC-N
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > DYN-N
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE DYN-COORD (W-I, W-K) TO SC-COORD (W-I, W-K)
               END-PERFORM
               MOVE 2 TO SC-SRC (W-I)
               COMPUTE SC-OFF (W-I) = DYN-OFF (W-I) + 1
               MOVE DYN-LEN (W-I) TO SC-LEN (W-I)
               MOVE 0 TO SC-LEN2 (W-I)
           END-PERFORM
           PERFORM IMPLODE
           .
       TRN-INIT.
           MOVE 1 TO TRN-N
           MOVE 0 TO TRN-COUNT
           MOVE 0 TO TRN-KEY (1) TRN-PARENT (1) TRN-DEPTH (1)
               TRN-LEAF (1) TRN-OFF (1) TRN-LEN (1)
           .
       TRN-FIND-KID.
      *>    parent TRN-NODE, key in W-KVAL -> TRN-NODE (child or 0);
      *>    TRN-CREATE = 1 to create when missing
           MOVE 0 TO TRN-FOUND
           PERFORM VARYING W-I FROM 2 BY 1 UNTIL W-I > TRN-N
               IF TRN-FOUND = 0
                   IF TRN-PARENT (W-I) = TRN-NODE
                       AND TRN-KEY (W-I) = W-KVAL
                       MOVE W-I TO TRN-NODE
                       MOVE 1 TO TRN-FOUND
                   END-IF
               END-IF
           END-PERFORM
           IF TRN-FOUND = 0
               IF TRN-CREATE = 1
                   ADD 1 TO TRN-N
                   MOVE W-KVAL TO TRN-KEY (TRN-N)
                   MOVE TRN-NODE TO TRN-PARENT (TRN-N)
                   COMPUTE TRN-DEPTH (TRN-N) = TRN-DEPTH (TRN-NODE) + 1
                   MOVE 0 TO TRN-LEAF (TRN-N)
                   MOVE TRN-N TO TRN-NODE
                   MOVE 1 TO TRN-FOUND
               ELSE
                   MOVE 0 TO TRN-NODE
               END-IF
           END-IF
           .
       TRN-WALK.
      *>    W-TGT, TRN-CREATE -> TRN-NODE = leaf node (0 if absent)
           MOVE 1 TO TRN-NODE
           PERFORM VARYING TRN-D FROM 1 BY 1 UNTIL TRN-D > 9
               IF TRN-NODE > 0
                   MOVE W-TGT (TRN-D) TO W-KVAL
                   PERFORM TRN-FIND-KID
               END-IF
           END-PERFORM
           .
       TRN-FETCH.
           MOVE 0 TO TRN-CREATE
           PERFORM TRN-WALK
           MOVE 0 TO DST-LEN
           IF TRN-NODE > 0 AND TRN-LEAF (TRN-NODE) = 1
               MOVE TXT-ARENA (TRN-OFF (TRN-NODE) + 1:TRN-LEN (TRN-NODE))
                   TO DST-ARENA (1:TRN-LEN (TRN-NODE))
               MOVE TRN-LEN (TRN-NODE) TO DST-LEN
           END-IF
           .
       TRN-PUT.
      *>    text in NEW-ARENA/NEW-LEN, coord W-TGT; TRN-MERGE as DYN
           IF NEW-LEN = 0 AND TRN-MERGE = 0
               PERFORM TRN-REMOVE
               EXIT PARAGRAPH
           END-IF
           IF NEW-LEN = 0
               EXIT PARAGRAPH
           END-IF
           MOVE 1 TO TRN-CREATE
           PERFORM TRN-WALK
           IF TRN-LEAF (TRN-NODE) = 1 AND TRN-MERGE = 1
               MOVE TXT-ARENA (TRN-OFF (TRN-NODE) + 1:TRN-LEN (TRN-NODE))
                   TO DST-ARENA (1:TRN-LEN (TRN-NODE))
               MOVE TRN-LEN (TRN-NODE) TO DST-LEN
               MOVE NEW-ARENA (1:NEW-LEN)
                   TO DST-ARENA (DST-LEN + 1:NEW-LEN)
               ADD NEW-LEN TO DST-LEN
               PERFORM TXT-STORE
               MOVE W-OFF TO TRN-OFF (TRN-NODE)
               MOVE W-LEN2 TO TRN-LEN (TRN-NODE)
           ELSE
               IF TRN-LEAF (TRN-NODE) = 0
                   ADD 1 TO TRN-COUNT
               END-IF
               MOVE NEW-ARENA (1:NEW-LEN) TO DST-ARENA (1:NEW-LEN)
               MOVE NEW-LEN TO DST-LEN
               PERFORM TXT-STORE
               MOVE W-OFF TO TRN-OFF (TRN-NODE)
               MOVE W-LEN2 TO TRN-LEN (TRN-NODE)
               MOVE 1 TO TRN-LEAF (TRN-NODE)
           END-IF
           .
       TRN-INSERT.
           MOVE 1 TO TRN-MERGE
           PERFORM TRN-PUT
           .
       TRN-REPLACE.
           MOVE 0 TO TRN-MERGE
           PERFORM TRN-PUT
           .
       TRN-REMOVE.
           MOVE 0 TO TRN-CREATE
           PERFORM TRN-WALK
           IF TRN-NODE > 0 AND TRN-LEAF (TRN-NODE) = 1
               MOVE 0 TO TRN-LEAF (TRN-NODE)
               MOVE 0 TO TRN-LEN (TRN-NODE)
               SUBTRACT 1 FROM TRN-COUNT
           END-IF
           .
       TRN-SERIALIZE.
      *>    gather leaves: reconstruct each leaf's coordinate by
      *>    walking parents to the root, load SC-TABLE, IMPLODE
           MOVE 0 TO SC-N
           PERFORM VARYING W-I FROM 2 BY 1 UNTIL W-I > TRN-N
               IF TRN-DEPTH (W-I) = 9 AND TRN-LEAF (W-I) = 1
                   ADD 1 TO SC-N
                   MOVE 2 TO SC-SRC (SC-N)
                   COMPUTE SC-OFF (SC-N) = TRN-OFF (W-I) + 1
                   MOVE TRN-LEN (W-I) TO SC-LEN (SC-N)
                   MOVE 0 TO SC-LEN2 (SC-N)
                   MOVE W-I TO TRN-NODE
                   PERFORM VARYING TRN-D FROM 9 BY -1 UNTIL TRN-D < 1
                       MOVE TRN-KEY (TRN-NODE)
                           TO SC-COORD (SC-N, TRN-D)
                       MOVE TRN-PARENT (TRN-NODE) TO TRN-NODE
                   END-PERFORM
               END-IF
           END-PERFORM
           PERFORM IMPLODE
           .
