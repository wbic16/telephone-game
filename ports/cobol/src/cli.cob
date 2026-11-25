       IDENTIFICATION DIVISION.
       PROGRAM-ID. TELCOBOL.
      *> Hub-side CLI for libphext-cobol (Exocortical Telephone Game,
      *> contract v2). Transport: no argument = one JSON object on
      *> stdin, one JSON response on stdout; argument "serve" = one
      *> JSON request per line. State travels as base64 (native codec
      *> below). Phext logic is this port's own phext.cpy. SHA-256 and
      *> Base64 file work use the standard command-line tools where
      *> COBOL lacks them (sha256sum, truncate); JSON is extracted with
      *> a native targeted parser (the wire schema is fixed). PGP:
      *> subprocess gpg with per-port GNUPGHOME
      *> /home/wbic16/telephone-cobol/keys on the hub.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT IN-FILE ASSIGN TO "/dev/stdin"
               ORGANIZATION IS LINE SEQUENTIAL.
           SELECT OUT-FILE ASSIGN TO "/dev/stdout"
               ORGANIZATION IS LINE SEQUENTIAL.
           SELECT BIN-FILE ASSIGN TO BIN-NAME
               ORGANIZATION IS SEQUENTIAL.
           SELECT TXT-FILE ASSIGN TO TXT-NAME
               ORGANIZATION IS LINE SEQUENTIAL.
       DATA DIVISION.
       FILE SECTION.
       FD IN-FILE.
       01 IN-LINE        PIC X(8388608).
       FD OUT-FILE.
       01 OUT-REC        PIC X(8388608).
       FD BIN-FILE.
       01 BIN-REC        PIC X(8192).
       FD TXT-FILE.
       01 TXT-REC        PIC X(65536).
       WORKING-STORAGE SECTION.
       COPY "phextw.cpy".
       01 AP-OP          PIC X(16).
       01 AP-TXT-OFF     PIC 9(9) COMP VALUE 1.
      *> CLI scratch
       01 BIN-NAME       PIC X(128) VALUE "/tmp/tel-cobol-bin".
       01 TXT-NAME       PIC X(128) VALUE "/tmp/tel-cobol-txt".
       01 EOF-FLAG       PIC 9(4) COMP VALUE 0.
       01 SERVE-MODE     PIC 9(4) COMP VALUE 0.
       01 REQ-CMD        PIC X(32).
       01 J-BUF          PIC X(8388608).
       01 J-BUF-LEN      PIC 9(9) COMP VALUE 0.
       01 OUT-LINE       PIC X(8388608).
       01 OUT-LEN        PIC 9(9) COMP VALUE 0.
       01 DEC-BUF        PIC X(8388608).
       01 DEC-LEN        PIC 9(9) COMP VALUE 0.
       01 ESC-BUF        PIC X(1048576).
       01 ESC-LEN        PIC 9(9) COMP VALUE 0.
       01 SMALL-BUF      PIC X(65536).
       01 SMALL-LEN      PIC 9(9) COMP VALUE 0.
       01 HASH-BUF       PIC X(64).
       01 B64C           PIC X(64) VALUE
           "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".
       01 B64C-TAB REDEFINES B64C PIC X OCCURS 64 TIMES.
       01 CMD-LINE-TXT   PIC X(64).
       01 NUM-DISP       PIC 9(9).
       01 NUM-STR        PIC X(20).
       01 CMD-STR        PIC X(4096).
       01 SYS-RC         PIC 9(9) COMP.
      *> JSON extraction scratch (operates on IN-LINE)
       01 J-KEY          PIC X(32).
       01 J-KEYLEN       PIC 9(9) COMP.
       01 J-S0           PIC 9(9) COMP.
       01 J-S1           PIC 9(9) COMP.
       01 J-FOUND        PIC 9(4) COMP.
       01 J-VPOS         PIC 9(9) COMP.
       01 J-AFTER        PIC 9(9) COMP.
       01 J-NUM          PIC S9(18) COMP.
       01 J-SPAN0        PIC 9(9) COMP.
       01 J-SPAN1        PIC 9(9) COMP.
       01 J-I            PIC 9(9) COMP.
       01 J-CP           PIC 9(9) COMP.
       01 J-CP2          PIC 9(9) COMP.
       01 LIT-BUF        PIC X(256).
       01 LIT-LEN        PIC 9(9) COMP.
      *> request fields
       01 R-TURN         PIC S9(18) COMP.
       01 R-POS          PIC X(64).
       01 R-POSLEN       PIC 9(9) COMP.
       01 STEP-SPAN0     PIC 9(9) COMP.
       01 STEP-SPAN1     PIC 9(9) COMP.
       01 COORD-TXT      PIC X(64).
       01 COORD-LEN      PIC 9(9) COMP.
      *> verify scratch
       01 V-SEQ          PIC 9(9) COMP.
       01 V-CHECKED      PIC 9(9) COMP VALUE 0.
       01 V-FAIL         PIC X(256).
       01 V-PREV         PIC X(64).
       01 V-PREVSET      PIC 9(4) COMP VALUE 0.
       01 PL-N           PIC 9(9) COMP VALUE 0.
       01 PL-TABLE.
           05 PL-ENTRY OCCURS 4096 TIMES.
               10 PL-COORD PIC X(64).
               10 PL-HASH  PIC X(64).
               10 PL-LEN   PIC 9(9) COMP.
       01 A-IDX          PIC 9(9) COMP VALUE 0.
       01 B-IDX          PIC 9(9) COMP VALUE 0.
       01 V-FAILLEN      PIC 9(9) COMP VALUE 0.
       01 STEP-C9        PIC 9(9) COMP OCCURS 9 TIMES.
       01 EV-C9          PIC 9(9) COMP OCCURS 9 TIMES.
       01 V-IDXEND       PIC 9(9) COMP VALUE 0.
       01 LINE0          PIC 9(9) COMP VALUE 0.
       01 F2-0           PIC 9(9) COMP VALUE 0.
       01 E-IDX          PIC 9(9) COMP VALUE 0.
       01 W-LITLEN       PIC 9(9) COMP VALUE 0.
       01 W-SUB          PIC 9(9) COMP VALUE 0.
       01 GZ-LEN         PIC 9(9) COMP VALUE 0.
       01 F2-LEN         PIC 9(9) COMP VALUE 0.
       01 F-HASH         PIC X(64).
       01 S-HASH         PIC X(64).
       01 EV-BODY0       PIC 9(9) COMP.
       01 EV-BODY1       PIC 9(9) COMP.
       01 DESC-BUF       PIC X(1024).
       01 DESC-LEN       PIC 9(9) COMP.
       01 GAME-BUF       PIC X(256).
       01 GAME-LEN       PIC 9(9) COMP VALUE 0.
       01 CAND-N         PIC 9(9) COMP VALUE 0.
       01 CAND-TABLE.
           05 CAND-ENTRY OCCURS 64 TIMES.
               10 CAND-TXT PIC X(256).
               10 CAND-LEN PIC 9(9) COMP.
       01 POOL-N         PIC 9(9) COMP VALUE 0.
       01 POOL-IDX       OCCURS 64 TIMES PIC 9(9) COMP.
       01 DEC2-OFF       PIC 9(9) COMP VALUE 0.
       01 DEC2-LEN       PIC 9(9) COMP VALUE 0.
       PROCEDURE DIVISION.
       COPY "phextp.cpy".
       MAIN.
           ACCEPT CMD-LINE-TXT FROM COMMAND-LINE
           IF FUNCTION UPPER-CASE (FUNCTION TRIM (CMD-LINE-TXT))
               = "SERVE"
               MOVE 1 TO SERVE-MODE
           END-IF
           OPEN INPUT IN-FILE
           OPEN OUTPUT OUT-FILE
           PERFORM UNTIL EOF-FLAG = 1
               READ IN-FILE
                   AT END MOVE 1 TO EOF-FLAG
                   NOT AT END
                       PERFORM GZ-UNFRAME
                       PERFORM HANDLE-REQUEST
               END-READ
               IF SERVE-MODE = 0
                   MOVE 1 TO EOF-FLAG
               END-IF
           END-PERFORM
           CLOSE IN-FILE OUT-FILE
           STOP RUN.
      *>
      *> ---------- generic output builders ----------
       OUT-LIT.
      *>    append literal in LIT-BUF (length = trailing-trimmed
      *>    length of LIT-BUF; declared LIT-LEN is not trusted)
           COMPUTE W-LITLEN = FUNCTION LENGTH (
               FUNCTION TRIM (LIT-BUF TRAILING))
           MOVE LIT-BUF (1:W-LITLEN) TO OUT-LINE (OUT-LEN + 1:W-LITLEN)
           ADD W-LITLEN TO OUT-LEN
           .
       OUT-DEC.
      *>    append DEC-BUF(1:DEC-LEN) raw
           MOVE DEC-BUF (1:DEC-LEN) TO OUT-LINE (OUT-LEN + 1:DEC-LEN)
           ADD DEC-LEN TO OUT-LEN
           .
       OUT-ESC.
      *>    append ESC-BUF(1:ESC-LEN) JSON-escaped ( quotes included )
           ADD 1 TO OUT-LEN
           MOVE '"' TO OUT-LINE (OUT-LEN:1)
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > ESC-LEN
               MOVE ESC-BUF (W-I:1) TO W-BYTE
               EVALUATE W-BYTE
                   WHEN '"'
                       MOVE '\"' TO OUT-LINE (OUT-LEN + 1:2)
                       ADD 2 TO OUT-LEN
                   WHEN '\'
                       MOVE '\\' TO OUT-LINE (OUT-LEN + 1:2)
                       ADD 2 TO OUT-LEN
                   WHEN X"0A"
                       MOVE '\n' TO OUT-LINE (OUT-LEN + 1:2)
                       ADD 2 TO OUT-LEN
                   WHEN X"0D"
                       MOVE '\r' TO OUT-LINE (OUT-LEN + 1:2)
                       ADD 2 TO OUT-LEN
                   WHEN X"09"
                       MOVE '\t' TO OUT-LINE (OUT-LEN + 1:2)
                       ADD 2 TO OUT-LEN
                   WHEN OTHER
                       ADD 1 TO OUT-LEN
                       MOVE W-BYTE TO OUT-LINE (OUT-LEN:1)
               END-EVALUATE
           END-PERFORM
           ADD 1 TO OUT-LEN
           MOVE '"' TO OUT-LINE (OUT-LEN:1)
           .
       SEND-OUT.
           IF OUT-LEN > 8192
               PERFORM GZ-FRAME
           END-IF
           MOVE OUT-LINE (1:OUT-LEN) TO OUT-REC
           WRITE OUT-REC
           CALL "fflush" USING BY VALUE 0
               ON EXCEPTION CONTINUE
           END-CALL
           MOVE 0 TO OUT-LEN
           .
      *>
      *> ---------- GZ1 game-scale framing (wave-2 pattern) ----------
       GZ-UNFRAME.
      *>    if IN-LINE starts with "GZ1:", replace it with the plain
      *>    request line: base64-decode + gunzip via the standard
      *>    tools on temp files (Fortran precedent)
           IF IN-LINE (1:4) = "GZ1:"
               COMPUTE DEC-LEN = FUNCTION LENGTH (
                   FUNCTION TRIM (IN-LINE TRAILING))
               MOVE IN-LINE (1:DEC-LEN) TO DEC-BUF
               MOVE "/tmp/tel-cobol-gz.b64" TO BIN-NAME
               PERFORM WRITE-BIN-FILE
               MOVE SPACES TO CMD-STR
               STRING "sed 's/^GZ1://' /tmp/tel-cobol-gz.b64 "
                      "| base64 -d 2>/dev/null | gzip -dc "
                      "> /tmp/tel-cobol-req.bin"
                      DELIMITED BY SIZE INTO CMD-STR
               END-STRING
               CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
               MOVE "/tmp/tel-cobol-req.bin" TO BIN-NAME
               PERFORM READ-BIN-FILE
               MOVE SPACES TO IN-LINE
               MOVE DEC-BUF (1:DEC-LEN) TO IN-LINE
           END-IF
           .
       READ-BIN-FILE.
      *>    BIN-NAME -> DEC-BUF/DEC-LEN, byte-exact (stat-sized,
      *>    fixed-record chunks)
           MOVE SPACES TO CMD-STR
           STRING "stat -c %s " DELIMITED BY SIZE
                  FUNCTION TRIM (BIN-NAME) DELIMITED BY SIZE
                  " > /tmp/tel-cobol-size.txt" DELIMITED BY SIZE
                  INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           MOVE "/tmp/tel-cobol-size.txt" TO TXT-NAME
           OPEN INPUT TXT-FILE
           READ TXT-FILE
               AT END MOVE SPACES TO TXT-REC
           END-READ
           CLOSE TXT-FILE
           MOVE 0 TO DEC-LEN
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > 128
               IF TXT-REC (W-I:1) >= '0' AND TXT-REC (W-I:1) <= '9'
                   COMPUTE DEC-LEN = DEC-LEN * 10
                       + FUNCTION ORD (TXT-REC (W-I:1))
                       - FUNCTION ORD ('0')
               END-IF
           END-PERFORM
           MOVE DEC-LEN TO GZ-LEN
           MOVE 0 TO DEC-LEN
           OPEN INPUT BIN-FILE
           PERFORM UNTIL DEC-LEN >= GZ-LEN
               READ BIN-FILE
                   AT END
                       MOVE GZ-LEN TO DEC-LEN
                   NOT AT END
                       IF GZ-LEN - DEC-LEN >= 8192
                           MOVE BIN-REC TO DEC-BUF (DEC-LEN + 1:8192)
                           ADD 8192 TO DEC-LEN
                       ELSE
                           MOVE BIN-REC (1:GZ-LEN - DEC-LEN)
                               TO DEC-BUF (DEC-LEN + 1
                                   :GZ-LEN - DEC-LEN)
                           MOVE GZ-LEN TO DEC-LEN
                       END-IF
               END-READ
           END-PERFORM
           CLOSE BIN-FILE
           MOVE GZ-LEN TO DEC-LEN
           .
       GZ-FRAME.
      *>    replace OUT-LINE(1:OUT-LEN) with its GZ1:-framed form:
      *>    "GZ1:" + base64(gzip(line)) via the standard tools
           MOVE OUT-LINE (1:OUT-LEN) TO DEC-BUF
           MOVE OUT-LEN TO DEC-LEN
           MOVE "/tmp/tel-cobol-resp.bin" TO BIN-NAME
           PERFORM WRITE-BIN-FILE
           MOVE SPACES TO CMD-STR
           STRING "gzip -c /tmp/tel-cobol-resp.bin "
                  "| base64 -w0 > /tmp/tel-cobol-resp.b64"
                  DELIMITED BY SIZE INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           MOVE "/tmp/tel-cobol-resp.b64" TO BIN-NAME
           PERFORM READ-BIN-FILE
           MOVE SPACES TO OUT-LINE
           MOVE "GZ1:" TO OUT-LINE (1:4)
           MOVE DEC-BUF (1:DEC-LEN) TO OUT-LINE (5:DEC-LEN)
           COMPUTE OUT-LEN = DEC-LEN + 4
           .
      *>
      *> ---------- JSON extraction on IN-LINE ----------
       FIND-KEY.
      *>    scope J-S0..J-S1, key J-KEY(J-KEYLEN) -> J-FOUND, J-VPOS
      *>    (position just after the ':'), searching for "key"
           MOVE 0 TO J-FOUND
           PERFORM VARYING J-I FROM J-S0 BY 1 UNTIL J-I > J-S1
               IF J-FOUND = 0
                   AND J-BUF (J-I:1) = '"'
                   AND J-BUF (J-I + 1:J-KEYLEN) = J-KEY (1:J-KEYLEN)
                   AND J-BUF (J-I + 1 + J-KEYLEN:1) = '"'
                   COMPUTE J-VPOS = J-I + 1 + J-KEYLEN + 1
                   PERFORM UNTIL J-VPOS > J-S1
                       OR J-BUF (J-VPOS:1) = ':'
                       ADD 1 TO J-VPOS
                   END-PERFORM
                   IF J-BUF (J-VPOS:1) = ':'
                       ADD 1 TO J-VPOS
                       PERFORM UNTIL J-VPOS > J-S1
                           OR (J-BUF (J-VPOS:1) NOT = ' '
                               AND J-BUF (J-VPOS:1) NOT = X"09")
                           ADD 1 TO J-VPOS
                       END-PERFORM
                       MOVE 1 TO J-FOUND
                   END-IF
               END-IF
           END-PERFORM
           .
       PARSE-JSTRING.
      *>    at J-VPOS (a '"') -> DEC-BUF/DEC-LEN (UTF-8 bytes),
      *>    J-AFTER = position after closing quote
           MOVE 0 TO DEC-LEN
           COMPUTE J-I = J-VPOS + 1
           PERFORM UNTIL J-BUF (J-I:1) = '"'
               IF J-BUF (J-I:1) = '\'
                   ADD 1 TO J-I
                   EVALUATE J-BUF (J-I:1)
                       WHEN 'n'
                           ADD 1 TO DEC-LEN
                           MOVE X"0A" TO DEC-BUF (DEC-LEN:1)
                       WHEN 'r'
                           ADD 1 TO DEC-LEN
                           MOVE X"0D" TO DEC-BUF (DEC-LEN:1)
                       WHEN 't'
                           ADD 1 TO DEC-LEN
                           MOVE X"09" TO DEC-BUF (DEC-LEN:1)
                       WHEN 'b'
                           ADD 1 TO DEC-LEN
                           MOVE X"08" TO DEC-BUF (DEC-LEN:1)
                       WHEN 'f'
                           ADD 1 TO DEC-LEN
                           MOVE X"0C" TO DEC-BUF (DEC-LEN:1)
                       WHEN 'u'
                           PERFORM HEX4
      *>                    J-CP = codepoint; handle surrogates
                           IF J-CP >= 55296 AND J-CP < 56320
                               MOVE J-CP TO J-CP2
                               ADD 2 TO J-I
                               PERFORM HEX4
                               COMPUTE J-CP = 65536
                                   + (J-CP2 - 55296) * 1024
                                   + (J-CP - 56320)
                           END-IF
                           PERFORM UTF8-EMIT
                       WHEN OTHER
                           ADD 1 TO DEC-LEN
                           MOVE J-BUF (J-I:1) TO DEC-BUF (DEC-LEN:1)
                   END-EVALUATE
                   ADD 1 TO J-I
               ELSE
                   ADD 1 TO DEC-LEN
                   MOVE J-BUF (J-I:1) TO DEC-BUF (DEC-LEN:1)
                   ADD 1 TO J-I
               END-IF
           END-PERFORM
           COMPUTE J-AFTER = J-I + 1
           .
       HEX4.
      *>    J-I points at 'u'; reads 4 hex digits -> J-CP
           MOVE 0 TO J-CP
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 4
               ADD 1 TO J-I
               COMPUTE J-CP = J-CP * 16
               EVALUATE TRUE
                   WHEN J-BUF (J-I:1) >= '0'
                       AND J-BUF (J-I:1) <= '9'
                       COMPUTE J-CP = J-CP
                           + FUNCTION ORD (J-BUF (J-I:1))
                           - FUNCTION ORD ('0')
                   WHEN J-BUF (J-I:1) >= 'a'
                       AND J-BUF (J-I:1) <= 'f'
                       COMPUTE J-CP = J-CP
                           + FUNCTION ORD (J-BUF (J-I:1))
                           - FUNCTION ORD ('a') + 10
                   WHEN OTHER
                       COMPUTE J-CP = J-CP
                           + FUNCTION ORD (J-BUF (J-I:1))
                           - FUNCTION ORD ('A') + 10
               END-EVALUATE
           END-PERFORM
           .
       UTF8-EMIT.
      *>    append J-CP as UTF-8 to DEC-BUF
           IF J-CP < 128
               ADD 1 TO DEC-LEN
               MOVE FUNCTION CHAR (J-CP + 1) TO DEC-BUF (DEC-LEN:1)
           ELSE
               IF J-CP < 2048
                   ADD 1 TO DEC-LEN
                   MOVE FUNCTION CHAR (192 + J-CP / 64 + 1)
                       TO DEC-BUF (DEC-LEN:1)
                   ADD 1 TO DEC-LEN
                   MOVE FUNCTION CHAR (128 + FUNCTION MOD (J-CP, 64)
                       + 1) TO DEC-BUF (DEC-LEN:1)
               ELSE
                   IF J-CP < 65536
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (224 + J-CP / 4096 + 1)
                           TO DEC-BUF (DEC-LEN:1)
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (128 + FUNCTION MOD
                           (J-CP / 64, 64) + 1) TO DEC-BUF (DEC-LEN:1)
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (128 + FUNCTION MOD
                           (J-CP, 64) + 1) TO DEC-BUF (DEC-LEN:1)
                   ELSE
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (240 + J-CP / 262144 + 1)
                           TO DEC-BUF (DEC-LEN:1)
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (128 + FUNCTION MOD
                           (J-CP / 4096, 64) + 1)
                           TO DEC-BUF (DEC-LEN:1)
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (128 + FUNCTION MOD
                           (J-CP / 64, 64) + 1) TO DEC-BUF (DEC-LEN:1)
                       ADD 1 TO DEC-LEN
                       MOVE FUNCTION CHAR (128 + FUNCTION MOD
                           (J-CP, 64) + 1) TO DEC-BUF (DEC-LEN:1)
                   END-IF
               END-IF
           END-IF
           .
       PARSE-JINT.
      *>    at J-VPOS -> J-NUM
           MOVE 0 TO J-NUM
           MOVE 0 TO W-FOUND
           IF J-BUF (J-VPOS:1) = '-'
               MOVE 1 TO W-FOUND
               ADD 1 TO J-VPOS
           END-IF
           PERFORM UNTIL J-BUF (J-VPOS:1) < '0'
               OR J-BUF (J-VPOS:1) > '9'
               COMPUTE J-NUM = J-NUM * 10
                   + FUNCTION ORD (J-BUF (J-VPOS:1))
                   - FUNCTION ORD ('0')
               ADD 1 TO J-VPOS
           END-PERFORM
           IF W-FOUND = 1
               COMPUTE J-NUM = -J-NUM
           END-IF
           .
       OBJ-SPAN.
      *>    at J-VPOS (a '{') -> J-SPAN0/J-SPAN1 (matching '}')
           MOVE J-VPOS TO J-SPAN0
           MOVE 0 TO W-J
           MOVE 0 TO W-FOUND
           PERFORM VARYING J-I FROM J-VPOS BY 1 UNTIL J-I > J-BUF-LEN
               IF W-FOUND = 0
                   EVALUATE J-BUF (J-I:1)
                       WHEN '"'
      *>                    skip string
                           ADD 1 TO J-I
                           PERFORM UNTIL J-BUF (J-I:1) = '"'
                               IF J-BUF (J-I:1) = '\'
                                   ADD 1 TO J-I
                               END-IF
                               ADD 1 TO J-I
                           END-PERFORM
                       WHEN '{'
                           ADD 1 TO W-J
                       WHEN '}'
                           SUBTRACT 1 FROM W-J
                           IF W-J = 0
                               MOVE J-I TO J-SPAN1
                               MOVE 1 TO W-FOUND
                           END-IF
                   END-EVALUATE
               END-IF
           END-PERFORM
           .
       GET-KEY-STR.
      *>    FIND-KEY + PARSE-JSTRING in current scope
           PERFORM FIND-KEY
           IF J-FOUND = 1
               PERFORM PARSE-JSTRING
           ELSE
               MOVE 0 TO DEC-LEN
           END-IF
           .
       GET-KEY-INT.
           PERFORM FIND-KEY
           IF J-FOUND = 1
               PERFORM PARSE-JINT
           ELSE
               MOVE 0 TO J-NUM
           END-IF
           .
      *>
      *> ---------- Base64 (native) ----------
       B64-DEC-SRC.
      *>    decode base64 span J-SPAN0..J-SPAN1 of IN-LINE into
      *>    SRC-ARENA/SRC-LEN
           MOVE 0 TO SRC-LEN
           MOVE 0 TO W-J
           MOVE 0 TO W-I
           PERFORM VARYING J-I FROM J-SPAN0 BY 1 UNTIL J-I > J-SPAN1
               MOVE J-BUF (J-I:1) TO W-BYTE
               PERFORM B64-VAL
               IF W-D >= 0
                   COMPUTE W-I = W-I * 64 + W-D
                   ADD 1 TO W-J
                   IF W-J = 4
                       MOVE 0 TO W-J
                       ADD 1 TO SRC-LEN
                       MOVE FUNCTION CHAR (W-I / 65536 + 1)
                           TO SRC-ARENA (SRC-LEN:1)
                       ADD 1 TO SRC-LEN
                       MOVE FUNCTION CHAR
                           (FUNCTION MOD (W-I / 256, 256) + 1)
                           TO SRC-ARENA (SRC-LEN:1)
                       ADD 1 TO SRC-LEN
                       MOVE FUNCTION CHAR (FUNCTION MOD (W-I, 256)
                           + 1) TO SRC-ARENA (SRC-LEN:1)
                       MOVE 0 TO W-I
                   END-IF
               END-IF
               IF W-BYTE = '='
                   MOVE 99999999 TO J-I
               END-IF
           END-PERFORM
           IF W-J = 3
               COMPUTE W-I = W-I * 64
               ADD 1 TO SRC-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SRC-ARENA (SRC-LEN:1)
               ADD 1 TO SRC-LEN
               MOVE FUNCTION CHAR (FUNCTION MOD (W-I / 256, 256) + 1)
                   TO SRC-ARENA (SRC-LEN:1)
           END-IF
           IF W-J = 2
               COMPUTE W-I = W-I * 4096
               ADD 1 TO SRC-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SRC-ARENA (SRC-LEN:1)
           END-IF
           .
       B64-VAL.
      *>    W-BYTE -> W-D (0..63, -1 if not a base64 char)
           EVALUATE TRUE
               WHEN W-BYTE >= 'A' AND W-BYTE <= 'Z'
                   COMPUTE W-D = FUNCTION ORD (W-BYTE)
                       - FUNCTION ORD ('A')
               WHEN W-BYTE >= 'a' AND W-BYTE <= 'z'
                   COMPUTE W-D = FUNCTION ORD (W-BYTE)
                       - FUNCTION ORD ('a') + 26
               WHEN W-BYTE >= '0' AND W-BYTE <= '9'
                   COMPUTE W-D = FUNCTION ORD (W-BYTE)
                       - FUNCTION ORD ('0') + 52
               WHEN W-BYTE = '+'
                   MOVE 62 TO W-D
               WHEN W-BYTE = '/'
                   MOVE 63 TO W-D
               WHEN OTHER
                   MOVE -1 TO W-D
           END-EVALUATE
           .
       B64-ENC-DST.
      *>    append base64 of DST-ARENA(1:DST-LEN) to OUT-LINE
           PERFORM VARYING W-I FROM 1 BY 3 UNTIL W-I > DST-LEN
               COMPUTE W-J = FUNCTION ORD (DST-ARENA (W-I:1)) - 1
               IF W-I + 1 <= DST-LEN
                   COMPUTE W-J = W-J * 256
                       + FUNCTION ORD (DST-ARENA (W-I + 1:1)) - 1
               ELSE
                   COMPUTE W-J = W-J * 256
               END-IF
               IF W-I + 2 <= DST-LEN
                   COMPUTE W-J = W-J * 256
                       + FUNCTION ORD (DST-ARENA (W-I + 2:1)) - 1
               ELSE
                   COMPUTE W-J = W-J * 256
               END-IF
               PERFORM B64-EMIT
           END-PERFORM
           .
       B64-EMIT.
      *>    W-J = 24-bit group; W-I = group start in DST-ARENA
           ADD 1 TO OUT-LEN
           COMPUTE W-SUB = FUNCTION MOD (W-J / 262144, 64) + 1
           MOVE B64C-TAB (W-SUB) TO OUT-LINE (OUT-LEN:1)
           ADD 1 TO OUT-LEN
           COMPUTE W-SUB = FUNCTION MOD (W-J / 4096, 64) + 1
           MOVE B64C-TAB (W-SUB) TO OUT-LINE (OUT-LEN:1)
           IF W-I + 1 <= DST-LEN
               ADD 1 TO OUT-LEN
               COMPUTE W-SUB = FUNCTION MOD (W-J / 64, 64) + 1
               MOVE B64C-TAB (W-SUB) TO OUT-LINE (OUT-LEN:1)
           ELSE
               ADD 1 TO OUT-LEN
               MOVE '=' TO OUT-LINE (OUT-LEN:1)
           END-IF
           IF W-I + 2 <= DST-LEN
               ADD 1 TO OUT-LEN
               COMPUTE W-SUB = FUNCTION MOD (W-J, 64) + 1
               MOVE B64C-TAB (W-SUB) TO OUT-LINE (OUT-LEN:1)
           ELSE
               ADD 1 TO OUT-LEN
               MOVE '=' TO OUT-LINE (OUT-LEN:1)
           END-IF
           .
      *>
      *> ---------- latin-1 text <-> bytes ----------
       DEC-TO-TXT.
      *>    DEC-BUF (UTF-8) -> TXT-ARENA/TXT-LEN under the latin-1
      *>    convention: codepoint < 256 becomes that byte; higher
      *>    codepoints keep their UTF-8 bytes
           MOVE 0 TO TXT-LEN
           MOVE 1 TO W-I
           PERFORM UNTIL W-I > DEC-LEN
               MOVE DEC-BUF (W-I:1) TO W-BYTE
               COMPUTE W-D = FUNCTION ORD (W-BYTE)
               IF W-D < 128
                   ADD 1 TO TXT-LEN
                   MOVE W-BYTE TO TXT-ARENA (TXT-LEN:1)
                   ADD 1 TO W-I
               ELSE
                   IF W-D >= 240
                       MOVE 4 TO W-J
                       COMPUTE J-CP = (W-D - 240) * 262144
                   ELSE
                       IF W-D >= 224
                           MOVE 3 TO W-J
                           COMPUTE J-CP = (W-D - 224) * 4096
                       ELSE
                           MOVE 2 TO W-J
                           COMPUTE J-CP = (W-D - 192) * 64
                       END-IF
                   END-IF
                   PERFORM VARYING W-K FROM 1 BY 1
                       UNTIL W-K >= W-J
                       COMPUTE J-CP = J-CP
                           + (FUNCTION ORD (DEC-BUF (W-I + W-K:1))
                              - 128) * (64 ** (W-J - W-K))
                   END-PERFORM
                   IF J-CP < 256
                       ADD 1 TO TXT-LEN
                       MOVE FUNCTION CHAR (J-CP + 1)
                           TO TXT-ARENA (TXT-LEN:1)
                   ELSE
                       PERFORM VARYING W-K FROM 0 BY 1
                           UNTIL W-K >= W-J
                           ADD 1 TO TXT-LEN
                           MOVE DEC-BUF (W-I + W-K:1)
                               TO TXT-ARENA (TXT-LEN:1)
                       END-PERFORM
                   END-IF
                   ADD W-J TO W-I
               END-IF
           END-PERFORM
           .
       DST-TO-DEC.
      *>    DST-ARENA bytes -> DEC-BUF as UTF-8 (latin-1 convention)
           MOVE 0 TO DEC-LEN
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > DST-LEN
               COMPUTE J-CP = FUNCTION ORD (DST-ARENA (W-I:1))
               IF J-CP < 128
                   ADD 1 TO DEC-LEN
                   MOVE DST-ARENA (W-I:1) TO DEC-BUF (DEC-LEN:1)
               ELSE
                   ADD 1 TO DEC-LEN
                   MOVE FUNCTION CHAR (192 + J-CP / 64 + 1)
                       TO DEC-BUF (DEC-LEN:1)
                   ADD 1 TO DEC-LEN
                   MOVE FUNCTION CHAR (128 + FUNCTION MOD (J-CP, 64)
                       + 1) TO DEC-BUF (DEC-LEN:1)
               END-IF
           END-PERFORM
           .
      *>
      *> ---------- file + sha256 + gpg via SYSTEM ----------
       WRITE-BIN-FILE.
      *>    write DEC-BUF(1:DEC-LEN) to BIN-NAME byte-exactly:
      *>    fixed 8192 records + truncate to the exact length
           OPEN OUTPUT BIN-FILE
           PERFORM VARYING W-I FROM 1 BY 8192 UNTIL W-I > DEC-LEN
               IF DEC-LEN - W-I + 1 >= 8192
                   MOVE DEC-BUF (W-I:8192) TO BIN-REC
               ELSE
                   MOVE SPACES TO BIN-REC
                   MOVE DEC-BUF (W-I:DEC-LEN - W-I + 1) TO BIN-REC
               END-IF
               WRITE BIN-REC
           END-PERFORM
           CLOSE BIN-FILE
           MOVE DEC-LEN TO NUM-DISP
           PERFORM NUM-TO-STR
           MOVE SPACES TO CMD-STR
           STRING "truncate -s " DELIMITED BY SIZE
                  FUNCTION TRIM (NUM-STR) DELIMITED BY SIZE
                  " " DELIMITED BY SIZE
                  FUNCTION TRIM (BIN-NAME) DELIMITED BY SIZE
                  INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           .
       WRITE-DST-BIN.
      *>    same, from DST-ARENA/DST-LEN (via DEC-BUF copy)
           MOVE DST-ARENA (1:DST-LEN) TO DEC-BUF
           MOVE DST-LEN TO DEC-LEN
           PERFORM WRITE-BIN-FILE
           .
       SHA256-OF-FILE.
      *>    BIN-NAME -> HASH-BUF (sha256sum command-line tool)
           MOVE SPACES TO CMD-STR
           STRING "sha256sum " DELIMITED BY SIZE
                  FUNCTION TRIM (BIN-NAME) DELIMITED BY SIZE
                  " > /tmp/tel-cobol-sha.txt" DELIMITED BY SIZE
                  INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           MOVE "/tmp/tel-cobol-sha.txt" TO TXT-NAME
           OPEN INPUT TXT-FILE
           READ TXT-FILE
               AT END MOVE SPACES TO TXT-REC
           END-READ
           CLOSE TXT-FILE
           MOVE TXT-REC (1:64) TO HASH-BUF
           .
       SHA256-DEC.
      *>    sha256 of DEC-BUF(1:DEC-LEN) -> HASH-BUF
           MOVE "/tmp/tel-cobol-sha.bin" TO BIN-NAME
           PERFORM WRITE-BIN-FILE
           PERFORM SHA256-OF-FILE
           .
       WRITE-TXT-LINES.
      *>    write DEC-BUF(1:DEC-LEN) to TXT-NAME as lines (LF-split)
           OPEN OUTPUT TXT-FILE
           MOVE 1 TO W-I
           PERFORM UNTIL W-I > DEC-LEN
               MOVE W-I TO W-J
               PERFORM UNTIL W-J > DEC-LEN
                   OR DEC-BUF (W-J:1) = X"0A"
                   ADD 1 TO W-J
               END-PERFORM
               MOVE SPACES TO TXT-REC
               IF W-J > W-I
                   MOVE DEC-BUF (W-I:W-J - W-I) TO TXT-REC
               END-IF
               WRITE TXT-REC
               COMPUTE W-I = W-J + 1
           END-PERFORM
           CLOSE TXT-FILE
           .
       READ-TXT-FILE.
      *>    read TXT-NAME (line sequential) into DEC-BUF with LF
      *>    joins and a trailing LF; DEC-LEN set
           MOVE 0 TO DEC-LEN
           OPEN INPUT TXT-FILE
           PERFORM UNTIL 1 = 2
               READ TXT-FILE
                   AT END
                       CLOSE TXT-FILE
                       EXIT PERFORM
                   NOT AT END
                       COMPUTE W-J = FUNCTION LENGTH (
                           FUNCTION TRIM (TXT-REC))
                       IF W-J > 0
                           MOVE TXT-REC (1:W-J)
                               TO DEC-BUF (DEC-LEN + 1:W-J)
                           ADD W-J TO DEC-LEN
                       END-IF
                       ADD 1 TO DEC-LEN
                       MOVE X"0A" TO DEC-BUF (DEC-LEN:1)
               END-READ
           END-PERFORM
           .
       GPG-KEYGEN.
      *>    ensure keypair in KeyHome; armored pubkey -> DEC-BUF
           MOVE SPACES TO CMD-STR
           STRING "mkdir -p /home/wbic16/telephone-cobol/keys && "
                  "GNUPGHOME=/home/wbic16/telephone-cobol/keys "
                  "gpg --batch --list-keys --with-colons "
                  "> /tmp/tel-cobol-keys.txt 2>/dev/null; "
                  "grep -q '^pub:' /tmp/tel-cobol-keys.txt || "
                  "GNUPGHOME=/home/wbic16/telephone-cobol/keys "
                  "gpg --batch --pinentry-mode loopback "
                  "--passphrase '' --quick-generate-key "
                  "telephone-cobol ed25519 sign never; "
                  "GNUPGHOME=/home/wbic16/telephone-cobol/keys "
                  "gpg --batch --armor --export telephone-cobol "
                  "> /tmp/tel-cobol-pub.txt"
                  DELIMITED BY SIZE INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           MOVE "/tmp/tel-cobol-pub.txt" TO TXT-NAME
           PERFORM READ-TXT-FILE
      *>    trim trailing LF
           PERFORM UNTIL DEC-LEN = 0
               OR (DEC-BUF (DEC-LEN:1) NOT = X"0A"
                   AND DEC-BUF (DEC-LEN:1) NOT = ' ')
               SUBTRACT 1 FROM DEC-LEN
           END-PERFORM
           .
       GPG-SIGN.
      *>    sign DESC-BUF(1:DESC-LEN); armored sig -> DEC-BUF
           MOVE DESC-BUF (1:DESC-LEN) TO DEC-BUF
           MOVE DESC-LEN TO DEC-LEN
           MOVE "/tmp/tel-cobol-desc.bin" TO BIN-NAME
           PERFORM WRITE-BIN-FILE
           MOVE SPACES TO CMD-STR
           STRING "GNUPGHOME=/home/wbic16/telephone-cobol/keys "
                  "gpg --batch --yes --pinentry-mode loopback "
                  "--passphrase '' --detach-sign --armor "
                  "--output /tmp/tel-cobol-sig.txt "
                  "/tmp/tel-cobol-desc.bin"
                  DELIMITED BY SIZE INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           MOVE "/tmp/tel-cobol-sig.txt" TO TXT-NAME
           PERFORM READ-TXT-FILE
           PERFORM UNTIL DEC-LEN = 0
               OR (DEC-BUF (DEC-LEN:1) NOT = X"0A"
                   AND DEC-BUF (DEC-LEN:1) NOT = ' ')
               SUBTRACT 1 FROM DEC-LEN
           END-PERFORM
           .
       GPG-VERIFY.
      *>    inputs: DEC-BUF = pubkeys text; SMALL-BUF/SMALL-LEN =
      *>    armored signature; DESC-BUF/DESC-LEN = signed data.
      *>    -> W-FOUND = 1 when the signature verifies
           MOVE "/tmp/tel-cobol-vkeys.txt" TO TXT-NAME
           PERFORM WRITE-TXT-LINES
           MOVE SMALL-BUF (1:SMALL-LEN) TO DEC-BUF
           MOVE SMALL-LEN TO DEC-LEN
           MOVE "/tmp/tel-cobol-vsig.txt" TO TXT-NAME
           PERFORM WRITE-TXT-LINES
           MOVE DESC-BUF (1:DESC-LEN) TO DEC-BUF
           MOVE DESC-LEN TO DEC-LEN
           MOVE "/tmp/tel-cobol-vdata.bin" TO BIN-NAME
           PERFORM WRITE-BIN-FILE
           MOVE SPACES TO CMD-STR
           STRING "rm -rf /tmp/tel-cobol-vgpg && "
                  "mkdir -p /tmp/tel-cobol-vgpg && "
                  "chmod 700 /tmp/tel-cobol-vgpg && "
                  "GNUPGHOME=/tmp/tel-cobol-vgpg gpg --batch "
                  "--import /tmp/tel-cobol-vkeys.txt "
                  ">/dev/null 2>&1 && "
                  "GNUPGHOME=/tmp/tel-cobol-vgpg gpg --batch "
                  "--verify /tmp/tel-cobol-vsig.txt "
                  "/tmp/tel-cobol-vdata.bin >/dev/null 2>&1"
                  DELIMITED BY SIZE INTO CMD-STR
           END-STRING
           CALL "SYSTEM" USING CMD-STR RETURNING SYS-RC
           IF SYS-RC = 0
               MOVE 1 TO W-FOUND
           ELSE
               MOVE 0 TO W-FOUND
           END-IF
           .
      *>
      *> ---------- coordinate text ----------
       NUM-TO-STR.
      *>    NUM-DISP (PIC 9(9) DISPLAY) -> NUM-STR, leading zeros cut
           MOVE SPACES TO NUM-STR
           MOVE 1 TO W-J
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > 8
               IF NUM-DISP (W-I:1) NOT = "0"
                   MOVE 10 TO W-I
               ELSE
                   ADD 1 TO W-J
               END-IF
           END-PERFORM
           MOVE NUM-DISP (W-J:) TO NUM-STR
           .
       PARSE-COORD-TXT.
      *>    COORD-TXT -> W-TGT (9 components)
           MOVE 1 TO W-I
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 0 TO W-TGT (W-K)
               PERFORM UNTIL COORD-TXT (W-I:1) < '0'
                   OR COORD-TXT (W-I:1) > '9'
                   COMPUTE W-TGT (W-K) = W-TGT (W-K) * 10
                       + FUNCTION ORD (COORD-TXT (W-I:1))
                       - FUNCTION ORD ('0')
                   ADD 1 TO W-I
               END-PERFORM
               ADD 1 TO W-I
           END-PERFORM
           .
       FORMAT-COORD.
      *>    W-TGT -> COORD-TXT/COORD-LEN as a.b.c/d.e.f/g.h.i
           MOVE 0 TO COORD-LEN
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               IF W-K > 1
                   ADD 1 TO COORD-LEN
                   IF FUNCTION MOD (W-K - 1, 3) = 0
                       MOVE '/' TO COORD-TXT (COORD-LEN:1)
                   ELSE
                       MOVE '.' TO COORD-TXT (COORD-LEN:1)
                   END-IF
               END-IF
               MOVE W-TGT (W-K) TO NUM-DISP
               MOVE NUM-DISP TO NUM-STR
               MOVE 0 TO W-FOUND
               PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
                   IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                       MOVE 1 TO W-FOUND
                   END-IF
                   IF W-FOUND = 1
                       ADD 1 TO COORD-LEN
                       MOVE NUM-STR (W-J:1)
                           TO COORD-TXT (COORD-LEN:1)
                   END-IF
               END-PERFORM
           END-PERFORM
           .
      *>
      *> ---------- request handling ----------
       HANDLE-REQUEST.
           MOVE IN-LINE TO J-BUF
           COMPUTE J-BUF-LEN = FUNCTION LENGTH (
               FUNCTION TRIM (J-BUF TRAILING))
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "cmd" TO J-KEY
           MOVE 3 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO REQ-CMD
           MOVE 0 TO OUT-LEN
           EVALUATE REQ-CMD
               WHEN "id"
                   PERFORM CMD-ID
               WHEN "keygen"
                   PERFORM CMD-KEYGEN
               WHEN "echo"
                   PERFORM CMD-ECHO
               WHEN "elect"
                   PERFORM CMD-ELECT
               WHEN "choose"
                   PERFORM CMD-CHOOSE
               WHEN "apply"
                   PERFORM CMD-APPLY
               WHEN "attest"
                   PERFORM CMD-ATTEST
               WHEN "init"
                   PERFORM CMD-INIT
               WHEN "validate"
                   PERFORM CMD-VALIDATE
               WHEN "verify"
                   PERFORM CMD-VERIFY
               WHEN "fetch"
                   PERFORM CMD-FETCH
               WHEN "explode"
                   PERFORM CMD-EXPLODE
               WHEN "implode"
                   PERFORM CMD-IMPLODE
               WHEN "insert"
                   PERFORM CMD-INSERT
               WHEN OTHER
                   MOVE '{"error":"unknown cmd"}' TO LIT-BUF
                   MOVE 22 TO LIT-LEN
                   PERFORM OUT-LIT
           END-EVALUATE
           PERFORM SEND-OUT
           .
       GET-STATE.
      *>    "state" (or "state_b64") base64 -> SRC-ARENA/SRC-LEN
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "state" TO J-KEY
           MOVE 5 TO J-KEYLEN
           PERFORM FIND-KEY
           IF J-FOUND = 0
               MOVE "state_b64" TO J-KEY
               MOVE 9 TO J-KEYLEN
               PERFORM FIND-KEY
           END-IF
           IF J-FOUND = 1
      *>        J-VPOS at opening quote; span = string content
               COMPUTE J-SPAN0 = J-VPOS + 1
               MOVE J-VPOS TO J-I
               PERFORM UNTIL J-BUF (J-I + 1:1) = '"'
                   ADD 1 TO J-I
               END-PERFORM
               MOVE J-I TO J-SPAN1
               PERFORM B64-DEC-SRC
           ELSE
               MOVE 0 TO SRC-LEN
           END-IF
           .
       CMD-ID.
           MOVE '{"impl":"cobol"}' TO LIT-BUF
           MOVE 16 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-KEYGEN.
           PERFORM GPG-KEYGEN
           MOVE '{"impl":"cobol","pubkey":' TO LIT-BUF
           MOVE 25 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE DEC-BUF (1:DEC-LEN) TO ESC-BUF
           MOVE DEC-LEN TO ESC-LEN
           PERFORM OUT-ESC
           MOVE '}' TO LIT-BUF
           MOVE 1 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-ECHO.
      *>    ping object -> canon {"impl":"cobol","ping":{...}} with
      *>    the ping's keys sorted: game, nonce, round (the driver's
      *>    ping shape). Values are inserted decoded; game names and
      *>    hex nonces carry no characters needing escape.
           MOVE "ping" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM FIND-KEY
           PERFORM OBJ-SPAN
           MOVE J-SPAN0 TO J-S0
           MOVE J-SPAN1 TO J-S1
           MOVE "game" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO GAME-BUF
           MOVE DEC-LEN TO GAME-LEN
           MOVE J-SPAN0 TO J-S0
           MOVE J-SPAN1 TO J-S1
           MOVE "nonce" TO J-KEY
           MOVE 5 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO SMALL-BUF
           MOVE DEC-LEN TO SMALL-LEN
           PERFORM CMD-ECHO-2
           .
       CMD-ECHO-2.
      *>    SMALL-BUF = nonce; game saved in GAME-BUF; round in R-TURN
           MOVE J-SPAN0 TO J-S0
           MOVE J-SPAN1 TO J-S1
           MOVE "round" TO J-KEY
           MOVE 5 TO J-KEYLEN
           PERFORM GET-KEY-INT
           MOVE J-NUM TO R-TURN
           MOVE SPACES TO DEC-BUF
           MOVE '{"impl":"cobol","ping":{"game":"' TO DEC-BUF
           MOVE 32 TO DEC-LEN
           MOVE GAME-BUF (1:GAME-LEN)
               TO DEC-BUF (DEC-LEN + 1:GAME-LEN)
           ADD GAME-LEN TO DEC-LEN
           MOVE '","nonce":"' TO LIT-BUF
           MOVE 11 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DEC-BUF (DEC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DEC-LEN
           MOVE SMALL-BUF (1:SMALL-LEN)
               TO DEC-BUF (DEC-LEN + 1:SMALL-LEN)
           ADD SMALL-LEN TO DEC-LEN
           MOVE '","round":' TO LIT-BUF
           MOVE 10 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DEC-BUF (DEC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DEC-LEN
           MOVE R-TURN TO NUM-DISP
           MOVE NUM-DISP TO NUM-STR
           MOVE 0 TO W-FOUND
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
               IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                   MOVE 1 TO W-FOUND
               END-IF
               IF W-FOUND = 1
                   ADD 1 TO DEC-LEN
                   MOVE NUM-STR (W-J:1) TO DEC-BUF (DEC-LEN:1)
               END-IF
           END-PERFORM
           MOVE '}}' TO LIT-BUF
           MOVE 2 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DEC-BUF (DEC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DEC-LEN
           PERFORM SHA256-DEC
           MOVE '{"impl":"cobol","echo":"' TO LIT-BUF
           MOVE 25 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE HASH-BUF TO LIT-BUF
           MOVE 64 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE '"}' TO LIT-BUF
           MOVE 2 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-ELECT.
           PERFORM PARSE-CANDIDATES
           MOVE "position" TO J-KEY
           MOVE 8 TO J-KEYLEN
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO R-POS
           MOVE DEC-LEN TO R-POSLEN
           MOVE "turn" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-INT
           MOVE J-NUM TO R-TURN
      *>    seed = cobol-elect:<position>:<turn>:<csv>
           MOVE SPACES TO DEC-BUF
           MOVE 'cobol-elect:' TO DEC-BUF
           MOVE 12 TO DEC-LEN
           MOVE R-POS (1:R-POSLEN) TO DEC-BUF (DEC-LEN + 1:R-POSLEN)
           ADD R-POSLEN TO DEC-LEN
           ADD 1 TO DEC-LEN
           MOVE ':' TO DEC-BUF (DEC-LEN:1)
           MOVE R-TURN TO NUM-DISP
           MOVE NUM-DISP TO NUM-STR
           MOVE 0 TO W-FOUND
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
               IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                   MOVE 1 TO W-FOUND
               END-IF
               IF W-FOUND = 1
                   ADD 1 TO DEC-LEN
                   MOVE NUM-STR (W-J:1) TO DEC-BUF (DEC-LEN:1)
               END-IF
           END-PERFORM
           ADD 1 TO DEC-LEN
           MOVE ':' TO DEC-BUF (DEC-LEN:1)
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > CAND-N
               IF W-I > 1
                   ADD 1 TO DEC-LEN
                   MOVE ',' TO DEC-BUF (DEC-LEN:1)
               END-IF
               MOVE CAND-TXT (W-I) (1:CAND-LEN (W-I))
                   TO DEC-BUF (DEC-LEN + 1:CAND-LEN (W-I))
               ADD CAND-LEN (W-I) TO DEC-LEN
           END-PERFORM
           PERFORM SHA256-DEC
      *>    first 8 hex digits -> W-J value
           MOVE 0 TO W-J
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 8
               COMPUTE W-J = W-J * 16
               EVALUATE TRUE
                   WHEN HASH-BUF (W-K:1) >= '0'
                       AND HASH-BUF (W-K:1) <= '9'
                       COMPUTE W-J = W-J
                           + FUNCTION ORD (HASH-BUF (W-K:1))
                           - FUNCTION ORD ('0')
                   WHEN HASH-BUF (W-K:1) >= 'a'
                       AND HASH-BUF (W-K:1) <= 'f'
                       COMPUTE W-J = W-J
                           + FUNCTION ORD (HASH-BUF (W-K:1))
                           - FUNCTION ORD ('a') + 10
               END-EVALUATE
           END-PERFORM
      *>    pool: candidates other than cobol
           MOVE 0 TO POOL-N
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > CAND-N
               IF CAND-TXT (W-I) (1:CAND-LEN (W-I)) NOT = 'cobol'
                   ADD 1 TO POOL-N
                   MOVE W-I TO POOL-IDX (POOL-N)
               END-IF
           END-PERFORM
           IF POOL-N = 0
               PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > CAND-N
                   MOVE W-I TO POOL-IDX (W-I)
               END-PERFORM
               MOVE CAND-N TO POOL-N
           END-IF
           COMPUTE W-I = FUNCTION MOD (W-J, POOL-N) + 1
           MOVE POOL-IDX (W-I) TO W-I
           MOVE '{"elect":' TO LIT-BUF
           MOVE 10 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE CAND-TXT (W-I) (1:CAND-LEN (W-I)) TO ESC-BUF
           MOVE CAND-LEN (W-I) TO ESC-LEN
           PERFORM OUT-ESC
           MOVE '}' TO LIT-BUF
           MOVE 1 TO LIT-LEN
           PERFORM OUT-LIT
           .
       PARSE-CANDIDATES.
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "candidates" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM FIND-KEY
           MOVE 0 TO CAND-N
           IF J-FOUND = 1
      *>        J-VPOS at '['; parse strings until ']'
               MOVE J-VPOS TO J-I
               PERFORM UNTIL J-BUF (J-I:1) = ']'
                   IF J-BUF (J-I:1) = '"'
                       MOVE J-I TO J-VPOS
                       PERFORM PARSE-JSTRING
                       ADD 1 TO CAND-N
                       MOVE DEC-BUF (1:DEC-LEN) TO CAND-TXT (CAND-N)
                       MOVE DEC-LEN TO CAND-LEN (CAND-N)
                       MOVE J-AFTER TO J-I
                   ELSE
                       ADD 1 TO J-I
                   END-IF
               END-PERFORM
           END-IF
           .
       CMD-CHOOSE.
           PERFORM GET-STATE
           PERFORM EXPLODE
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "position" TO J-KEY
           MOVE 8 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           PERFORM PARSE-COORD-TXT
           PERFORM FIND-COORD
           PERFORM UNTIL W-FOUND = 0
               ADD 1 TO W-TGT (9)
               PERFORM FIND-COORD
           END-PERFORM
           PERFORM FORMAT-COORD
           MOVE "turn" TO J-KEY
           MOVE 4 TO J-KEYLEN
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           PERFORM GET-KEY-INT
           MOVE '{"op":"insert","coordinate":' TO LIT-BUF
           MOVE 28 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE COORD-TXT (1:COORD-LEN) TO ESC-BUF
           MOVE COORD-LEN TO ESC-LEN
           PERFORM OUT-ESC
           MOVE ',"text":' TO LIT-BUF
           MOVE 8 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE SPACES TO SMALL-BUF
           MOVE 'cobol was here, turn ' TO SMALL-BUF
           MOVE 21 TO SMALL-LEN
           MOVE J-NUM TO NUM-DISP
           MOVE NUM-DISP TO NUM-STR
           MOVE 0 TO W-FOUND
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
               IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                   MOVE 1 TO W-FOUND
               END-IF
               IF W-FOUND = 1
                   ADD 1 TO SMALL-LEN
                   MOVE NUM-STR (W-J:1) TO SMALL-BUF (SMALL-LEN:1)
               END-IF
           END-PERFORM
           MOVE SMALL-BUF (1:SMALL-LEN) TO ESC-BUF
           MOVE SMALL-LEN TO ESC-LEN
           PERFORM OUT-ESC
           MOVE '}' TO LIT-BUF
           MOVE 1 TO LIT-LEN
           PERFORM OUT-LIT
           .
       GET-STEP.
      *>    step object span -> STEP-SPAN0/1; op -> AP-OP;
      *>    coordinate -> COORD-TXT; text -> TXT-ARENA (bytes)
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "step" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM FIND-KEY
           PERFORM OBJ-SPAN
           MOVE J-SPAN0 TO STEP-SPAN0
           MOVE J-SPAN1 TO STEP-SPAN1
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "op" TO J-KEY
           MOVE 2 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO AP-OP
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "coordinate" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "text" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-STR
           PERFORM DEC-TO-TXT
           .
       CMD-APPLY.
           PERFORM GET-STATE
           PERFORM GET-STEP
           PERFORM EXPLODE
           PERFORM PARSE-COORD-TXT
           IF AP-OP = "fetch" OR AP-OP = "navigate"
               PERFORM FETCH-TEXT
               PERFORM WRITE-DST-BIN
               PERFORM SHA256-OF-FILE
               MOVE HASH-BUF TO SMALL-BUF
      *>            state unchanged: DST := SRC
               MOVE SRC-ARENA (1:SRC-LEN) TO DST-ARENA
               MOVE SRC-LEN TO DST-LEN
               PERFORM WRITE-DST-BIN
               PERFORM SHA256-OF-FILE
               MOVE '{"state_b64":"' TO LIT-BUF
               MOVE 15 TO LIT-LEN
               PERFORM OUT-LIT
               PERFORM B64-ENC-DST
               MOVE '","state_sha256":"' TO LIT-BUF
               MOVE 18 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE HASH-BUF TO LIT-BUF
               MOVE 64 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE '","fetch_sha256":"' TO LIT-BUF
               MOVE 18 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE SMALL-BUF (1:64) TO LIT-BUF
               MOVE 64 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE '"}' TO LIT-BUF
               MOVE 2 TO LIT-LEN
               PERFORM OUT-LIT
           ELSE
               MOVE 1 TO AP-TXT-OFF
               PERFORM APPLY-STEP-TXT
               PERFORM IMPLODE
               PERFORM WRITE-DST-BIN
               PERFORM SHA256-OF-FILE
               MOVE '{"state_b64":"' TO LIT-BUF
               MOVE 15 TO LIT-LEN
               PERFORM OUT-LIT
               PERFORM B64-ENC-DST
               MOVE '","state_sha256":"' TO LIT-BUF
               MOVE 18 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE HASH-BUF TO LIT-BUF
               MOVE 64 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE '"}' TO LIT-BUF
               MOVE 2 TO LIT-LEN
               PERFORM OUT-LIT
           END-IF
           .
       CMD-ATTEST.
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "descriptor" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM FIND-KEY
           PERFORM OBJ-SPAN
           MOVE J-SPAN0 TO STEP-SPAN0
           MOVE J-SPAN1 TO STEP-SPAN1
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "coordinate" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           MOVE DEC-LEN TO COORD-LEN
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "file_sha256" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:64) TO SMALL-BUF
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "scroll_sha256" TO J-KEY
           MOVE 13 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:64) TO GAME-BUF
           MOVE STEP-SPAN0 TO J-S0
           MOVE STEP-SPAN1 TO J-S1
           MOVE "turn" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-INT
           MOVE J-NUM TO R-TURN
      *>    canon descriptor:
      *>    {"coordinate":"C","file_sha256":"F","scroll_sha256":"S",
      *>     "turn":N}
           MOVE SPACES TO DESC-BUF
           MOVE '{"coordinate":"' TO DESC-BUF
           MOVE 15 TO DESC-LEN
           MOVE COORD-TXT (1:COORD-LEN)
               TO DESC-BUF (DESC-LEN + 1:COORD-LEN)
           ADD COORD-LEN TO DESC-LEN
           MOVE '","file_sha256":"' TO LIT-BUF
           MOVE 17 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE SMALL-BUF (1:64) TO DESC-BUF (DESC-LEN + 1:64)
           ADD 64 TO DESC-LEN
           MOVE '","scroll_sha256":"' TO LIT-BUF
           MOVE 19 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE GAME-BUF (1:64) TO DESC-BUF (DESC-LEN + 1:64)
           ADD 64 TO DESC-LEN
           MOVE '","turn":' TO LIT-BUF
           MOVE 9 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE R-TURN TO NUM-DISP
           MOVE NUM-DISP TO NUM-STR
           MOVE 0 TO W-FOUND
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
               IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                   MOVE 1 TO W-FOUND
               END-IF
               IF W-FOUND = 1
                   ADD 1 TO DESC-LEN
                   MOVE NUM-STR (W-J:1) TO DESC-BUF (DESC-LEN:1)
               END-IF
           END-PERFORM
           ADD 1 TO DESC-LEN
           MOVE '}' TO DESC-BUF (DESC-LEN:1)
           PERFORM GPG-KEYGEN
           PERFORM GPG-SIGN
      *>    signature = base64 of the armored signature (DEC-BUF)
           MOVE DEC-BUF (1:DEC-LEN) TO DST-ARENA
           MOVE DEC-LEN TO DST-LEN
           MOVE '{"signature":"' TO LIT-BUF
           MOVE 14 TO LIT-LEN
           PERFORM OUT-LIT
           PERFORM B64-ENC-DST
           MOVE '"}' TO LIT-BUF
           MOVE 2 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-INIT.
           PERFORM GET-STATE
           PERFORM EXPLODE
           PERFORM SAVE-CACHE
           MOVE '{"impl":"cobol","verdict":"pass"}' TO LIT-BUF
           MOVE 33 TO LIT-LEN
           PERFORM OUT-LIT
           .
       SAVE-CACHE.
      *>    cache = current SC-TABLE + SRC-ARENA copy
           MOVE SRC-ARENA (1:SRC-LEN) TO CAC-ARENA
           MOVE SRC-LEN TO CAC-LEN
           MOVE SC-N TO CAC-N
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > SC-N
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE SC-COORD (W-I, W-K) TO CAC-COORD (W-I, W-K)
               END-PERFORM
               MOVE SC-OFF (W-I) TO CAC-OFF (W-I)
               IF SC-SRC (W-I) = 1
                   MOVE SC-LEN (W-I) TO CAC-LEN-E (W-I)
               ELSE
                   MOVE 0 TO CAC-LEN-E (W-I)
               END-IF
           END-PERFORM
           .
       CMD-FETCH.
           PERFORM GET-STATE
           PERFORM EXPLODE
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "coordinate" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           PERFORM PARSE-COORD-TXT
           PERFORM FETCH-TEXT
           MOVE '{"text_b64":"' TO LIT-BUF
           MOVE 14 TO LIT-LEN
           PERFORM OUT-LIT
           PERFORM B64-ENC-DST
           MOVE '","text":' TO LIT-BUF
           MOVE 9 TO LIT-LEN
           PERFORM OUT-LIT
           PERFORM DST-TO-DEC
           MOVE DEC-BUF (1:DEC-LEN) TO ESC-BUF
           MOVE DEC-LEN TO ESC-LEN
           PERFORM OUT-ESC
           MOVE '}' TO LIT-BUF
           MOVE 1 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-EXPLODE.
           PERFORM GET-STATE
           PERFORM EXPLODE
           MOVE '{"map":{' TO LIT-BUF
           MOVE 8 TO LIT-LEN
           PERFORM OUT-LIT
           PERFORM VARYING E-IDX FROM 1 BY 1 UNTIL E-IDX > SC-N
               IF E-IDX > 1
                   MOVE ',' TO LIT-BUF
                   MOVE 1 TO LIT-LEN
                   PERFORM OUT-LIT
               END-IF
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE SC-COORD (E-IDX, W-K) TO W-TGT (W-K)
               END-PERFORM
               PERFORM FORMAT-COORD
               MOVE COORD-TXT (1:COORD-LEN) TO ESC-BUF
               MOVE COORD-LEN TO ESC-LEN
               PERFORM OUT-ESC
               MOVE ':' TO LIT-BUF
               MOVE 1 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE '"' TO LIT-BUF
               MOVE 1 TO LIT-LEN
               PERFORM OUT-LIT
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE SC-COORD (E-IDX, W-K) TO W-TGT (W-K)
               END-PERFORM
               PERFORM FETCH-TEXT
               PERFORM B64-ENC-DST
               MOVE '"' TO LIT-BUF
               MOVE 1 TO LIT-LEN
               PERFORM OUT-LIT
           END-PERFORM
           MOVE '}}' TO LIT-BUF
           MOVE 2 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-IMPLODE.
      *>    {"map": {"coord": "b64", ...}} -> implode
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "map" TO J-KEY
           MOVE 3 TO J-KEYLEN
           PERFORM FIND-KEY
           PERFORM OBJ-SPAN
           MOVE J-SPAN0 TO STEP-SPAN0
           MOVE J-SPAN1 TO STEP-SPAN1
           MOVE 0 TO SC-N
           MOVE STEP-SPAN0 TO J-I
           PERFORM UNTIL J-I > STEP-SPAN1
               IF J-BUF (J-I:1) = '"'
                   MOVE J-I TO J-VPOS
                   PERFORM PARSE-JSTRING
                   MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
                   PERFORM PARSE-COORD-TXT
      *>            value string follows
                   MOVE J-AFTER TO J-I
                   PERFORM UNTIL J-BUF (J-I:1) = '"'
                       ADD 1 TO J-I
                   END-PERFORM
                   COMPUTE J-SPAN0 = J-I + 1
                   MOVE J-I TO W-J
                   PERFORM UNTIL J-BUF (W-J + 1:1) = '"'
                       ADD 1 TO W-J
                   END-PERFORM
                   MOVE W-J TO J-SPAN1
      *>            decode into TXT-ARENA at bump offset: use a
      *>            dedicated region per entry is complex; decode
      *>            into SRC-ARENA (state arena is free here) via a
      *>            variant decode, then register slice of SRC
                   PERFORM B64-DEC-SRC2
                   ADD 1 TO SC-N
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE W-TGT (W-K) TO SC-COORD (SC-N, W-K)
                   END-PERFORM
                   MOVE 1 TO SC-SRC (SC-N)
                   MOVE DEC2-OFF TO SC-OFF (SC-N)
                   MOVE DEC2-LEN TO SC-LEN (SC-N)
                   MOVE 0 TO SC-LEN2 (SC-N)
                   COMPUTE J-I = W-J + 2
               ELSE
                   ADD 1 TO J-I
               END-IF
           END-PERFORM
           PERFORM IMPLODE
           PERFORM WRITE-DST-BIN
           PERFORM SHA256-OF-FILE
           MOVE '{"state_b64":"' TO LIT-BUF
           MOVE 15 TO LIT-LEN
           PERFORM OUT-LIT
           PERFORM B64-ENC-DST
           MOVE '","state_sha256":"' TO LIT-BUF
           MOVE 18 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE HASH-BUF TO LIT-BUF
           MOVE 64 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE '"}' TO LIT-BUF
           MOVE 2 TO LIT-LEN
           PERFORM OUT-LIT
           .
       B64-DEC-SRC2.
      *>    like B64-DEC-SRC but appends to SRC-ARENA at DEC2-OFF
      *>    (running bump), returning DEC2-OFF/DEC2-LEN for the slice
           COMPUTE DEC2-OFF = SRC-LEN + 1
           MOVE 0 TO DEC2-LEN
           MOVE 0 TO W-J
           MOVE 0 TO W-I
           PERFORM VARYING J-I FROM J-SPAN0 BY 1 UNTIL J-I > J-SPAN1
               MOVE J-BUF (J-I:1) TO W-BYTE
               PERFORM B64-VAL
               IF W-D >= 0
                   COMPUTE W-I = W-I * 64 + W-D
                   ADD 1 TO W-J
                   IF W-J = 4
                       MOVE 0 TO W-J
                       ADD 1 TO SRC-LEN
                       ADD 1 TO DEC2-LEN
                       MOVE FUNCTION CHAR (W-I / 65536 + 1)
                           TO SRC-ARENA (SRC-LEN:1)
                       ADD 1 TO SRC-LEN
                       ADD 1 TO DEC2-LEN
                       MOVE FUNCTION CHAR
                           (FUNCTION MOD (W-I / 256, 256) + 1)
                           TO SRC-ARENA (SRC-LEN:1)
                       ADD 1 TO SRC-LEN
                       ADD 1 TO DEC2-LEN
                       MOVE FUNCTION CHAR (FUNCTION MOD (W-I, 256)
                           + 1) TO SRC-ARENA (SRC-LEN:1)
                       MOVE 0 TO W-I
                   END-IF
               END-IF
               IF W-BYTE = '='
                   MOVE 99999999 TO J-I
               END-IF
           END-PERFORM
           IF W-J = 3
               COMPUTE W-I = W-I * 64
               ADD 1 TO SRC-LEN
               ADD 1 TO DEC2-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SRC-ARENA (SRC-LEN:1)
               ADD 1 TO SRC-LEN
               ADD 1 TO DEC2-LEN
               MOVE FUNCTION CHAR (FUNCTION MOD (W-I / 256, 256) + 1)
                   TO SRC-ARENA (SRC-LEN:1)
           END-IF
           IF W-J = 2
               COMPUTE W-I = W-I * 4096
               ADD 1 TO SRC-LEN
               ADD 1 TO DEC2-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SRC-ARENA (SRC-LEN:1)
           END-IF
           .
       CMD-INSERT.
      *>    game insert hook: unused coordinate only
           PERFORM GET-STATE
           PERFORM EXPLODE
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "coordinate" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           PERFORM PARSE-COORD-TXT
           PERFORM FIND-COORD
           IF W-FOUND = 1
               MOVE '{"error":"coordinate already occupied"}'
                   TO LIT-BUF
               MOVE 38 TO LIT-LEN
               PERFORM OUT-LIT
           ELSE
               MOVE "text_b64" TO J-KEY
               MOVE 8 TO J-KEYLEN
               MOVE 1 TO J-S0
               MOVE J-BUF-LEN TO J-S1
               PERFORM FIND-KEY
               COMPUTE J-SPAN0 = J-VPOS + 1
               MOVE J-VPOS TO J-I
               PERFORM UNTIL J-BUF (J-I + 1:1) = '"'
                   ADD 1 TO J-I
               END-PERFORM
               MOVE J-I TO J-SPAN1
      *>        decode text into TXT-ARENA via SRC2-style append:
      *>        temporarily decode into DST then copy
               PERFORM B64-DEC-SRC2-TXT
               MOVE "insert" TO AP-OP
               MOVE 1 TO AP-TXT-OFF
               PERFORM APPLY-STEP-TXT
               PERFORM IMPLODE
               PERFORM WRITE-DST-BIN
               PERFORM SHA256-OF-FILE
               MOVE '{"state_b64":"' TO LIT-BUF
               MOVE 15 TO LIT-LEN
               PERFORM OUT-LIT
               PERFORM B64-ENC-DST
               MOVE '","state_sha256":"' TO LIT-BUF
               MOVE 18 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE HASH-BUF TO LIT-BUF
               MOVE 64 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE '"}' TO LIT-BUF
               MOVE 2 TO LIT-LEN
               PERFORM OUT-LIT
           END-IF
           .
       B64-DEC-SRC2-TXT.
      *>    decode span into TXT-ARENA(1:...), TXT-LEN set
           MOVE 0 TO TXT-LEN
           MOVE 0 TO W-J
           MOVE 0 TO W-I
           PERFORM VARYING J-I FROM J-SPAN0 BY 1 UNTIL J-I > J-SPAN1
               MOVE J-BUF (J-I:1) TO W-BYTE
               PERFORM B64-VAL
               IF W-D >= 0
                   COMPUTE W-I = W-I * 64 + W-D
                   ADD 1 TO W-J
                   IF W-J = 4
                       MOVE 0 TO W-J
                       ADD 1 TO TXT-LEN
                       MOVE FUNCTION CHAR (W-I / 65536 + 1)
                           TO TXT-ARENA (TXT-LEN:1)
                       ADD 1 TO TXT-LEN
                       MOVE FUNCTION CHAR
                           (FUNCTION MOD (W-I / 256, 256) + 1)
                           TO TXT-ARENA (TXT-LEN:1)
                       ADD 1 TO TXT-LEN
                       MOVE FUNCTION CHAR (FUNCTION MOD (W-I, 256)
                           + 1) TO TXT-ARENA (TXT-LEN:1)
                       MOVE 0 TO W-I
                   END-IF
               END-IF
               IF W-BYTE = '='
                   MOVE 99999999 TO J-I
               END-IF
           END-PERFORM
           IF W-J = 3
               COMPUTE W-I = W-I * 64
               ADD 1 TO TXT-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO TXT-ARENA (TXT-LEN:1)
               ADD 1 TO TXT-LEN
               MOVE FUNCTION CHAR (FUNCTION MOD (W-I / 256, 256) + 1)
                   TO TXT-ARENA (TXT-LEN:1)
           END-IF
           IF W-J = 2
               COMPUTE W-I = W-I * 4096
               ADD 1 TO TXT-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO TXT-ARENA (TXT-LEN:1)
           END-IF
           .
      *>
      *> ---------- validate / verify ----------
       CMP-ENTRY-TXT.
      *>    SC entry W-IDX vs TXT-ARENA(1:TXT-LEN) -> W-FOUND
           MOVE 1 TO W-FOUND
           IF SC-LEN (W-IDX) + SC-LEN2 (W-IDX) NOT = TXT-LEN
               MOVE 0 TO W-FOUND
           ELSE
               IF SC-SRC (W-IDX) = 1
                   IF SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                       NOT = TXT-ARENA (1:TXT-LEN)
                       MOVE 0 TO W-FOUND
                   END-IF
               ELSE
                   IF SC-SRC (W-IDX) = 2
                       IF TXT-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                           NOT = TXT-ARENA (1:TXT-LEN)
                           MOVE 0 TO W-FOUND
                       END-IF
                   ELSE
      *>                SRC=3: first slice in SRC, second in TXT
                       IF SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                           NOT = TXT-ARENA (1:SC-LEN (W-IDX))
                           MOVE 0 TO W-FOUND
                       END-IF
                       IF TXT-ARENA (SC-OFF2 (W-IDX):SC-LEN2 (W-IDX))
                           NOT = TXT-ARENA
                               (SC-LEN (W-IDX) + 1:SC-LEN2 (W-IDX))
                           MOVE 0 TO W-FOUND
                       END-IF
                   END-IF
               END-IF
           END-IF
           .
       CMP-SC-CAC.
      *>    SC entry A-IDX (SRC arena) vs CAC entry B-IDX (CAC
      *>    arena) -> W-FOUND = 1 when byte-identical
           MOVE 1 TO W-FOUND
           IF SC-LEN (A-IDX) + SC-LEN2 (A-IDX)
               NOT = CAC-LEN-E (B-IDX)
               MOVE 0 TO W-FOUND
           ELSE
               IF SC-SRC (A-IDX) = 1
                   IF SRC-ARENA (SC-OFF (A-IDX):SC-LEN (A-IDX))
                       NOT = CAC-ARENA
                           (CAC-OFF (B-IDX):CAC-LEN-E (B-IDX))
                       MOVE 0 TO W-FOUND
                   END-IF
               ELSE
      *>                compare via DST staging (rare paths)
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE SC-COORD (A-IDX, W-K) TO W-TGT (W-K)
                   END-PERFORM
                   MOVE A-IDX TO W-IDX
                   PERFORM FETCH-TEXT
                   IF DST-ARENA (1:DST-LEN) NOT = CAC-ARENA
                       (CAC-OFF (B-IDX):CAC-LEN-E (B-IDX))
                       MOVE 0 TO W-FOUND
                   END-IF
               END-IF
           END-IF
           .
       FIND-IN-CAC.
      *>    W-TGT -> W-FOUND, B-IDX
           MOVE 0 TO W-FOUND
           MOVE 0 TO B-IDX
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > CAC-N
               IF W-FOUND = 0
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE CAC-COORD (W-J, W-K) TO CA-COORD (W-K)
                       MOVE W-TGT (W-K) TO CB-COORD (W-K)
                   END-PERFORM
                   PERFORM COORD-CMP
                   IF CMP-RES = 0
                       MOVE 1 TO W-FOUND
                       MOVE W-J TO B-IDX
                   END-IF
               END-IF
           END-PERFORM
           .
       VFAIL-OUT.
      *>    V-FAIL text (first V-FAILLEN chars) -> fail response
           MOVE '{"impl":"cobol","verdict":"fail","detail":'
               TO LIT-BUF
           MOVE 41 TO LIT-LEN
           PERFORM OUT-LIT
           MOVE V-FAIL (1:V-FAILLEN) TO ESC-BUF
           MOVE V-FAILLEN TO ESC-LEN
           PERFORM OUT-ESC
           MOVE '}' TO LIT-BUF
           MOVE 1 TO LIT-LEN
           PERFORM OUT-LIT
           .
       VPASS-OUT.
           MOVE '{"impl":"cobol","verdict":"pass"}' TO LIT-BUF
           MOVE 33 TO LIT-LEN
           PERFORM OUT-LIT
           .
       CMD-VALIDATE.
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "prior_state" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM FIND-KEY
           IF J-FOUND = 1
               PERFORM VALIDATE-WIRE
           ELSE
               PERFORM VALIDATE-DRIVER
           END-IF
           .
       VALIDATE-WIRE.
           PERFORM GET-STATE
           PERFORM EXPLODE
           PERFORM SAVE-CACHE
           PERFORM GET-STEP
           PERFORM PARSE-COORD-TXT
      *>    placed text in cache == step text?
           PERFORM FIND-IN-CAC
           MOVE SPACES TO V-FAIL
           MOVE 0 TO V-FAILLEN
           IF W-FOUND = 0
               MOVE 'placed scroll missing' TO V-FAIL
               MOVE 21 TO V-FAILLEN
           ELSE
               IF CAC-LEN-E (B-IDX) NOT = TXT-LEN
                   OR CAC-ARENA (CAC-OFF (B-IDX):CAC-LEN-E (B-IDX))
                      NOT = TXT-ARENA (1:TXT-LEN)
                   MOVE 'placed scroll text != step text' TO V-FAIL
                   MOVE 31 TO V-FAILLEN
               END-IF
           END-IF
      *>    decode prior into SRC + SC
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "prior_state" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM FIND-KEY
           COMPUTE J-SPAN0 = J-VPOS + 1
           MOVE J-VPOS TO J-I
           PERFORM UNTIL J-BUF (J-I + 1:1) = '"'
               ADD 1 TO J-I
           END-PERFORM
           MOVE J-I TO J-SPAN1
           PERFORM B64-DEC-SRC
           PERFORM EXPLODE
           IF V-FAILLEN = 0
               PERFORM VARYING A-IDX FROM 1 BY 1 UNTIL A-IDX > SC-N
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE SC-COORD (A-IDX, W-K) TO W-TGT (W-K)
                   END-PERFORM
                   PERFORM FIND-IN-CAC
                   IF W-FOUND = 0
                       MOVE 'prior scroll overwritten' TO V-FAIL
                       MOVE 24 TO V-FAILLEN
                   ELSE
                       PERFORM CMP-SC-CAC
                       IF W-FOUND = 0
                           MOVE 'prior scroll overwritten' TO V-FAIL
                           MOVE 24 TO V-FAILLEN
                       END-IF
                   END-IF
               END-PERFORM
           END-IF
           IF V-FAILLEN = 0
               MOVE 0 TO W-J
               PERFORM VARYING B-IDX FROM 1 BY 1 UNTIL B-IDX > CAC-N
                   PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                       MOVE CAC-COORD (B-IDX, W-K) TO W-TGT (W-K)
                   END-PERFORM
                   PERFORM FIND-COORD
                   IF W-FOUND = 0
                       ADD 1 TO W-J
                   END-IF
               END-PERFORM
               IF W-J NOT = 1
                   MOVE 'expected exactly one added scroll' TO V-FAIL
                   MOVE 33 TO V-FAILLEN
               END-IF
           END-IF
           IF V-FAILLEN = 0
               PERFORM VPASS-OUT
           ELSE
               PERFORM VFAIL-OUT
           END-IF
           .
       VALIDATE-DRIVER.
           PERFORM GET-STATE
           PERFORM EXPLODE
           PERFORM GET-STEP
           PERFORM PARSE-COORD-TXT
           MOVE W-TGT (1) TO STEP-C9 (1)
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE W-TGT (W-K) TO STEP-C9 (W-K)
           END-PERFORM
           MOVE SPACES TO V-FAIL
           MOVE 0 TO V-FAILLEN
           PERFORM FIND-COORD
           IF W-FOUND = 0
               MOVE 'placed scroll missing or altered' TO V-FAIL
               MOVE 32 TO V-FAILLEN
           ELSE
               PERFORM CMP-ENTRY-TXT
               IF W-FOUND = 0
                   MOVE 'placed scroll missing or altered' TO V-FAIL
                   MOVE 32 TO V-FAILLEN
               END-IF
           END-IF
      *>    event coord + index line
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "event_coord" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO COORD-TXT
           PERFORM PARSE-COORD-TXT
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE W-TGT (W-K) TO EV-C9 (W-K)
           END-PERFORM
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "index_line" TO J-KEY
           MOVE 10 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO SMALL-BUF
           MOVE DEC-LEN TO SMALL-LEN
           IF V-FAILLEN = 0
      *>        prior scrolls preserved (except the index scroll)
               PERFORM VARYING B-IDX FROM 1 BY 1 UNTIL B-IDX > CAC-N
                   IF V-FAILLEN = 0
                       PERFORM VARYING W-K FROM 1 BY 1
                           UNTIL W-K > 9
                           MOVE CAC-COORD (B-IDX, W-K)
                               TO W-TGT (W-K)
                       END-PERFORM
                       IF NOT (W-TGT (1) = 1 AND W-TGT (2) = 1
                           AND W-TGT (3) = 1 AND W-TGT (4) = 1
                           AND W-TGT (5) = 1 AND W-TGT (6) = 1
                           AND W-TGT (7) = 1 AND W-TGT (8) = 1
                           AND W-TGT (9) = 1)
                           PERFORM FIND-COORD
                           IF W-FOUND = 0
                               MOVE 'prior scroll overwritten'
                                   TO V-FAIL
                               MOVE 24 TO V-FAILLEN
                           ELSE
                               MOVE W-IDX TO A-IDX
                               PERFORM CMP-SC-CAC
                               IF W-FOUND = 0
                                   MOVE 'prior scroll overwritten'
                                       TO V-FAIL
                                   MOVE 24 TO V-FAILLEN
                               END-IF
                           END-IF
                       END-IF
                   END-IF
               END-PERFORM
           END-IF
           IF V-FAILLEN = 0
      *>        no unexpected new scrolls
               PERFORM VARYING A-IDX FROM 1 BY 1 UNTIL A-IDX > SC-N
                   IF V-FAILLEN = 0
                       PERFORM VARYING W-K FROM 1 BY 1
                           UNTIL W-K > 9
                           MOVE SC-COORD (A-IDX, W-K) TO W-TGT (W-K)
                       END-PERFORM
                       PERFORM FIND-IN-CAC
                       IF W-FOUND = 0
                           PERFORM VARYING W-K FROM 1 BY 1
                               UNTIL W-K > 9
                               MOVE SC-COORD (A-IDX, W-K)
                                   TO CA-COORD (W-K)
                               MOVE STEP-C9 (W-K) TO CB-COORD (W-K)
                           END-PERFORM
                           PERFORM COORD-CMP
                           IF CMP-RES NOT = 0
                               PERFORM VARYING W-K FROM 1 BY 1
                                   UNTIL W-K > 9
                                   MOVE EV-C9 (W-K)
                                       TO CB-COORD (W-K)
                               END-PERFORM
                               PERFORM COORD-CMP
                               IF CMP-RES NOT = 0
                                   MOVE 'unexpected new scroll'
                                       TO V-FAIL
                                   MOVE 21 TO V-FAILLEN
                               END-IF
                           END-IF
                       END-IF
                   END-IF
               END-PERFORM
           END-IF
           IF V-FAILLEN = 0
      *>        index scroll records the placement: index_line
      *>        (SMALL-BUF) must appear inside the index scroll text
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE 1 TO W-TGT (W-K)
               END-PERFORM
               PERFORM FIND-COORD
               IF W-FOUND = 0
                   MOVE 'index missing' TO V-FAIL
                   MOVE 13 TO V-FAILLEN
               ELSE
                   MOVE 0 TO W-FOUND
                   PERFORM VARYING W-I FROM 0 BY 1
                       UNTIL W-I + SMALL-LEN
                           > SC-LEN (W-IDX) + SC-LEN2 (W-IDX)
                       IF SRC-ARENA
                           (SC-OFF (W-IDX) + W-I:SMALL-LEN)
                           = SMALL-BUF (1:SMALL-LEN)
                           MOVE 1 TO W-FOUND
                       END-IF
                   END-PERFORM
                   IF W-FOUND = 0
                       MOVE 'index does not record the placement'
                           TO V-FAIL
                       MOVE 35 TO V-FAILLEN
                   END-IF
               END-IF
           END-IF
           IF V-FAILLEN = 0
               PERFORM SAVE-CACHE
               PERFORM VPASS-OUT
           ELSE
               PERFORM VFAIL-OUT
           END-IF
           .
       CMD-VERIFY.
           PERFORM GET-STATE
           PERFORM EXPLODE
      *>    save pubkeys arg into CAC-ARENA (free storage here)
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "pubkeys" TO J-KEY
           MOVE 7 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO CAC-ARENA
           MOVE DEC-LEN TO CAC-LEN
           MOVE 0 TO V-CHECKED
           MOVE 0 TO PL-N
           MOVE 0 TO V-PREVSET
           MOVE SPACES TO V-FAIL
           MOVE 0 TO V-FAILLEN
      *>    keys-hash check
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 1 TO W-TGT (W-K)
           END-PERFORM
           MOVE 2 TO W-TGT (9)
           PERFORM FIND-COORD
           IF W-FOUND = 1
               MOVE SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX))
                   TO DEC-BUF
               MOVE SC-LEN (W-IDX) TO DEC-LEN
               PERFORM SHA256-DEC
               MOVE HASH-BUF TO F-HASH
               MOVE 3 TO W-TGT (9)
               PERFORM FIND-COORD
               IF W-FOUND = 1
                   IF F-HASH NOT = SRC-ARENA
                       (SC-OFF (W-IDX):SC-LEN (W-IDX))
                       AND F-HASH NOT =
                           FUNCTION TRIM (SRC-ARENA
                           (SC-OFF (W-IDX):SC-LEN (W-IDX)))
                       MOVE 'keys-hash scroll does not match keys'
                           TO V-FAIL
                       MOVE 36 TO V-FAILLEN
                   END-IF
               END-IF
           END-IF
      *>    event walk
           MOVE 0 TO V-SEQ
           PERFORM UNTIL V-FAILLEN > 0
               ADD 1 TO V-SEQ
               PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
                   MOVE 1 TO W-TGT (W-K)
               END-PERFORM
               MOVE 2 TO W-TGT (7)
               MOVE V-SEQ TO W-TGT (9)
               PERFORM FIND-COORD
               IF W-FOUND = 0
                   EXIT PERFORM
               END-IF
               PERFORM VERIFY-EVENT
           END-PERFORM
           IF V-FAILLEN = 0
               PERFORM VERIFY-INDEX
           END-IF
           IF V-FAILLEN = 0
               MOVE '{"impl":"cobol","verdict":"pass","placements_checked":' TO LIT-BUF
               MOVE 55 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE V-CHECKED TO NUM-DISP
               MOVE NUM-DISP TO NUM-STR
               MOVE 0 TO W-FOUND
               PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
                   IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                       MOVE 1 TO W-FOUND
                   END-IF
                   IF W-FOUND = 1
                       MOVE NUM-STR (W-J:1) TO LIT-BUF
                       MOVE 1 TO LIT-LEN
                       PERFORM OUT-LIT
                   END-IF
               END-PERFORM
               MOVE ',"first_failure":null}' TO LIT-BUF
               MOVE 22 TO LIT-LEN
               PERFORM OUT-LIT
           ELSE
               MOVE '{"impl":"cobol","verdict":"fail","placements_checked":' TO LIT-BUF
               MOVE 55 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE V-CHECKED TO NUM-DISP
               MOVE NUM-DISP TO NUM-STR
               MOVE 0 TO W-FOUND
               PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
                   IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                       MOVE 1 TO W-FOUND
                   END-IF
                   IF W-FOUND = 1
                       MOVE NUM-STR (W-J:1) TO LIT-BUF
                       MOVE 1 TO LIT-LEN
                       PERFORM OUT-LIT
                   END-IF
               END-PERFORM
               MOVE ',"first_failure":{"detail":' TO LIT-BUF
               MOVE 27 TO LIT-LEN
               PERFORM OUT-LIT
               MOVE V-FAIL (1:V-FAILLEN) TO ESC-BUF
               MOVE V-FAILLEN TO ESC-LEN
               PERFORM OUT-ESC
               MOVE '}}' TO LIT-BUF
               MOVE 2 TO LIT-LEN
               PERFORM OUT-LIT
           END-IF
           .
       VERIFY-EVENT.
      *>    SC entry W-IDX is the event scroll (in SRC-ARENA)
           MOVE SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX)) TO J-BUF
           MOVE SC-LEN (W-IDX) TO J-BUF-LEN
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           MOVE "prev" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM FIND-KEY
           IF V-PREVSET = 0
               IF J-BUF (J-VPOS:1) NOT = 'n'
                   MOVE 'event chain broken' TO V-FAIL
                   MOVE 18 TO V-FAILLEN
                   EXIT PARAGRAPH
               END-IF
           ELSE
               PERFORM PARSE-JSTRING
               IF DEC-BUF (1:64) NOT = V-PREV
                   MOVE 'event chain broken' TO V-FAIL
                   MOVE 18 TO V-FAILLEN
                   EXIT PARAGRAPH
               END-IF
           END-IF
           MOVE "body" TO J-KEY
           MOVE 4 TO J-KEYLEN
           MOVE 1 TO J-S0
           MOVE J-BUF-LEN TO J-S1
           PERFORM FIND-KEY
           PERFORM OBJ-SPAN
           MOVE J-SPAN0 TO EV-BODY0
           MOVE J-SPAN1 TO EV-BODY1
           MOVE J-BUF (EV-BODY0:EV-BODY1 - EV-BODY0 + 1) TO DEC-BUF
           COMPUTE DEC-LEN = EV-BODY1 - EV-BODY0 + 1
           PERFORM SHA256-DEC
           MOVE HASH-BUF TO V-PREV
           MOVE 1 TO V-PREVSET
      *>    body fields
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "type" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-STR
           IF DEC-BUF (1:DEC-LEN) = 'placement'
               PERFORM VERIFY-PLACEMENT
           END-IF
           .
       VERIFY-PLACEMENT.
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "coord" TO J-KEY
           MOVE 5 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:DEC-LEN) TO GAME-BUF
           MOVE DEC-LEN TO GAME-LEN
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "text_sha256" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:64) TO S-HASH
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "file_sha256" TO J-KEY
           MOVE 11 TO J-KEYLEN
           PERFORM GET-KEY-STR
           MOVE DEC-BUF (1:64) TO F-HASH
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "turn" TO J-KEY
           MOVE 4 TO J-KEYLEN
           PERFORM GET-KEY-INT
           MOVE J-NUM TO R-TURN
           MOVE EV-BODY0 TO J-S0
           MOVE EV-BODY1 TO J-S1
           MOVE "att" TO J-KEY
           MOVE 3 TO J-KEYLEN
           PERFORM FIND-KEY
           COMPUTE J-SPAN0 = J-VPOS + 1
           MOVE J-VPOS TO J-I
           PERFORM UNTIL J-BUF (J-I + 1:1) = '"'
               ADD 1 TO J-I
           END-PERFORM
           MOVE J-I TO J-SPAN1
           PERFORM B64-DEC-SMALL
      *>    duplicate?
           PERFORM VARYING W-I FROM 1 BY 1 UNTIL W-I > PL-N
               IF PL-COORD (W-I) (1:GAME-LEN) = GAME-BUF (1:GAME-LEN)
                   AND PL-LEN (W-I) = GAME-LEN
                   MOVE 'coordinate reused' TO V-FAIL
                   MOVE 17 TO V-FAILLEN
                   EXIT PARAGRAPH
               END-IF
           END-PERFORM
      *>    placement scroll present + hash
           MOVE GAME-BUF (1:GAME-LEN) TO COORD-TXT
           PERFORM PARSE-COORD-TXT
           PERFORM FIND-COORD
           IF W-FOUND = 0
               MOVE 'placement scroll missing' TO V-FAIL
               MOVE 24 TO V-FAILLEN
               EXIT PARAGRAPH
           END-IF
           MOVE SRC-ARENA (SC-OFF (W-IDX):SC-LEN (W-IDX)) TO DEC-BUF
           MOVE SC-LEN (W-IDX) TO DEC-LEN
           IF SC-LEN2 (W-IDX) > 0
               MOVE TXT-ARENA (SC-OFF2 (W-IDX):SC-LEN2 (W-IDX))
                   TO DEC-BUF (DEC-LEN + 1:SC-LEN2 (W-IDX))
               ADD SC-LEN2 (W-IDX) TO DEC-LEN
           END-IF
           PERFORM SHA256-DEC
           IF HASH-BUF NOT = S-HASH
               MOVE 'placement scroll hash mismatch' TO V-FAIL
               MOVE 30 TO V-FAILLEN
               EXIT PARAGRAPH
           END-IF
      *>    descriptor canon -> DESC-BUF (same build as CMD-ATTEST)
           MOVE GAME-BUF (1:GAME-LEN) TO COORD-TXT
           MOVE GAME-LEN TO COORD-LEN
           PERFORM BUILD-DESC
      *>    signature check: pubkeys in CAC-ARENA, sig in SMALL-BUF
           MOVE CAC-ARENA (1:CAC-LEN) TO DEC-BUF
           MOVE CAC-LEN TO DEC-LEN
           PERFORM GPG-VERIFY
           IF W-FOUND = 0
               MOVE 'attestation fails' TO V-FAIL
               MOVE 17 TO V-FAILLEN
               EXIT PARAGRAPH
           END-IF
           ADD 1 TO PL-N
           MOVE GAME-BUF (1:GAME-LEN) TO PL-COORD (PL-N)
           MOVE GAME-LEN TO PL-LEN (PL-N)
           MOVE S-HASH TO PL-HASH (PL-N)
           ADD 1 TO V-CHECKED
           .
       BUILD-DESC.
      *>    COORD-TXT/COORD-LEN, F-HASH, S-HASH, R-TURN -> DESC-BUF
           MOVE SPACES TO DESC-BUF
           MOVE '{"coordinate":"' TO DESC-BUF
           MOVE 15 TO DESC-LEN
           MOVE COORD-TXT (1:COORD-LEN)
               TO DESC-BUF (DESC-LEN + 1:COORD-LEN)
           ADD COORD-LEN TO DESC-LEN
           MOVE '","file_sha256":"' TO LIT-BUF
           MOVE 17 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE F-HASH TO DESC-BUF (DESC-LEN + 1:64)
           ADD 64 TO DESC-LEN
           MOVE '","scroll_sha256":"' TO LIT-BUF
           MOVE 19 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE S-HASH TO DESC-BUF (DESC-LEN + 1:64)
           ADD 64 TO DESC-LEN
           MOVE '","turn":' TO LIT-BUF
           MOVE 9 TO LIT-LEN
           MOVE LIT-BUF (1:LIT-LEN) TO DESC-BUF (DESC-LEN + 1:LIT-LEN)
           ADD LIT-LEN TO DESC-LEN
           MOVE R-TURN TO NUM-DISP
           MOVE NUM-DISP TO NUM-STR
           MOVE 0 TO W-FOUND
           PERFORM VARYING W-J FROM 1 BY 1 UNTIL W-J > 9
               IF NUM-STR (W-J:1) NOT = '0' OR W-J = 9
                   MOVE 1 TO W-FOUND
               END-IF
               IF W-FOUND = 1
                   ADD 1 TO DESC-LEN
                   MOVE NUM-STR (W-J:1) TO DESC-BUF (DESC-LEN:1)
               END-IF
           END-PERFORM
           ADD 1 TO DESC-LEN
           MOVE '}' TO DESC-BUF (DESC-LEN:1)
           .
       B64-DEC-SMALL.
      *>    decode span J-SPAN0..J-SPAN1 of J-BUF into
      *>    SMALL-BUF/SMALL-LEN
           MOVE 0 TO SMALL-LEN
           MOVE 0 TO W-J
           MOVE 0 TO W-I
           PERFORM VARYING J-I FROM J-SPAN0 BY 1 UNTIL J-I > J-SPAN1
               MOVE J-BUF (J-I:1) TO W-BYTE
               PERFORM B64-VAL
               IF W-D >= 0
                   COMPUTE W-I = W-I * 64 + W-D
                   ADD 1 TO W-J
                   IF W-J = 4
                       MOVE 0 TO W-J
                       ADD 1 TO SMALL-LEN
                       MOVE FUNCTION CHAR (W-I / 65536 + 1)
                           TO SMALL-BUF (SMALL-LEN:1)
                       ADD 1 TO SMALL-LEN
                       MOVE FUNCTION CHAR
                           (FUNCTION MOD (W-I / 256, 256) + 1)
                           TO SMALL-BUF (SMALL-LEN:1)
                       ADD 1 TO SMALL-LEN
                       MOVE FUNCTION CHAR (FUNCTION MOD (W-I, 256)
                           + 1) TO SMALL-BUF (SMALL-LEN:1)
                       MOVE 0 TO W-I
                   END-IF
               END-IF
               IF W-BYTE = '='
                   MOVE 99999999 TO J-I
               END-IF
           END-PERFORM
           IF W-J = 3
               COMPUTE W-I = W-I * 64
               ADD 1 TO SMALL-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SMALL-BUF (SMALL-LEN:1)
               ADD 1 TO SMALL-LEN
               MOVE FUNCTION CHAR (FUNCTION MOD (W-I / 256, 256) + 1)
                   TO SMALL-BUF (SMALL-LEN:1)
           END-IF
           IF W-J = 2
               COMPUTE W-I = W-I * 4096
               ADD 1 TO SMALL-LEN
               MOVE FUNCTION CHAR (W-I / 65536 + 1)
                   TO SMALL-BUF (SMALL-LEN:1)
           END-IF
           .
       VERIFY-INDEX.
           PERFORM VARYING W-K FROM 1 BY 1 UNTIL W-K > 9
               MOVE 1 TO W-TGT (W-K)
           END-PERFORM
           PERFORM FIND-COORD
           IF W-FOUND = 0
               IF V-CHECKED > 0
                   MOVE 'index lines != placements' TO V-FAIL
                   MOVE 25 TO V-FAILLEN
               END-IF
               EXIT PARAGRAPH
           END-IF
           MOVE 0 TO W-J
           MOVE SC-OFF (W-IDX) TO W-I
           COMPUTE V-IDXEND = SC-OFF (W-IDX) + SC-LEN (W-IDX)
           PERFORM UNTIL W-I >= V-IDXEND
               MOVE W-I TO LINE0
               PERFORM UNTIL W-I >= V-IDXEND
                   OR SRC-ARENA (W-I:1) = X"0A"
                   ADD 1 TO W-I
               END-PERFORM
               IF W-I > LINE0
                   AND SRC-ARENA (LINE0:1) NOT = '#'
                   ADD 1 TO W-J
                   PERFORM CHECK-IDX-LINE
                   IF V-FAILLEN > 0
                       EXIT PERFORM
                   END-IF
               END-IF
               ADD 1 TO W-I
           END-PERFORM
           IF V-FAILLEN = 0 AND W-J NOT = V-CHECKED
               MOVE 'index lines != placements' TO V-FAIL
               MOVE 25 TO V-FAILLEN
           END-IF
           .
       CHECK-IDX-LINE.
      *>    line at SRC-ARENA(LINE0 .. W-I-1): fields by spaces;
      *>    field2 = coord, field3 = hash; must match a PL entry
           MOVE LINE0 TO W-K
      *>    skip field 1
           PERFORM UNTIL SRC-ARENA (W-K:1) = ' '
               ADD 1 TO W-K
           END-PERFORM
           ADD 1 TO W-K
           MOVE W-K TO F2-0
           PERFORM UNTIL SRC-ARENA (W-K:1) = ' '
               ADD 1 TO W-K
           END-PERFORM
           COMPUTE F2-LEN = W-K - F2-0
           ADD 1 TO W-K
           MOVE SRC-ARENA (W-K:64) TO F-HASH
           MOVE 0 TO W-FOUND
           PERFORM VARYING J-I FROM 1 BY 1 UNTIL J-I > PL-N
               IF PL-LEN (J-I) = F2-LEN
                   AND PL-COORD (J-I) (1:F2-LEN)
                       = SRC-ARENA (F2-0:F2-LEN)
                   AND PL-HASH (J-I) = F-HASH
                   MOVE 1 TO W-FOUND
               END-IF
           END-PERFORM
           IF W-FOUND = 0
               MOVE 'index hash mismatch' TO V-FAIL
               MOVE 19 TO V-FAILLEN
           END-IF
           .
