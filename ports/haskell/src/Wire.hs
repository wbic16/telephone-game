{-# LANGUAGE OverloadedStrings #-}
-- Wire.hs - SHA-256 (pure Haskell, Data.Word32 arithmetic; the GHC boot
-- libraries ship no SHA-256), base64, and a minimal JSON parser/printer
-- with canonical output (sorted keys, compact separators, ASCII-escaped
-- strings - byte-identical to Python json.dumps(sort_keys=True,
-- separators=(",", ":"), ensure_ascii=True) for the value shapes the
-- telephone game uses).
module Wire
  ( sha256Hex
  , b64Encode, b64Decode
  , Json(..), jsonGet, jsonString, jsonInt
  , parseJson, canonJson
  ) where

import Data.Bits
import Data.Char (chr, ord)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Word (Word8, Word32, Word64)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C

-- ---------------------------------------------------------------- SHA-256
kTable :: [Word32]
kTable =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 ]

sha256 :: B.ByteString -> B.ByteString
sha256 msg = B.pack (concatMap wordBytes finalH)
  where
    len = B.length msg
    bitlen = fromIntegral len * 8 :: Word64
    padZeros = (56 - (len + 1) `mod` 64) `mod` 64
    padded = B.concat [ msg, B.singleton 0x80, B.replicate padZeros 0
                      , B.pack [ fromIntegral (bitlen `shiftR` s) | s <- [56,48..0] ] ]
    h0 = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
         , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ]
    blocks = chunk64 padded
    finalH = foldl compress h0 blocks
    chunk64 bs
      | B.null bs = []
      | otherwise = let (a, rest) = B.splitAt 64 bs in a : chunk64 rest
    wordBytes w = [ fromIntegral (w `shiftR` 24), fromIntegral (w `shiftR` 16)
                  , fromIntegral (w `shiftR` 8), fromIntegral w ]
    compress h block = zipWith (+) h (foldl step h (zip w kTable))
      where
        wHead = [ let o = i * 4
                  in (fromIntegral (B.index block o) `shiftL` 24)
                   .|. (fromIntegral (B.index block (o + 1)) `shiftL` 16)
                   .|. (fromIntegral (B.index block (o + 2)) `shiftL` 8)
                   .|. fromIntegral (B.index block (o + 3))
                | i <- [0 .. 15] ]
        w = wHead ++ [ let s0 = rotr (w !! (i - 15)) 7 `xor` rotr (w !! (i - 15)) 18 `xor` (w !! (i - 15) `shiftR` 3)
                           s1 = rotr (w !! (i - 2)) 17 `xor` rotr (w !! (i - 2)) 19 `xor` (w !! (i - 2) `shiftR` 10)
                       in w !! (i - 16) + s0 + w !! (i - 7) + s1
                     | i <- [16 .. 63] ]
        step [a, b, c, d, e, f, g, hh] (wi, ki) =
          let s1 = rotr e 6 `xor` rotr e 11 `xor` rotr e 25
              ch = (e .&. f) `xor` (complement e .&. g)
              t1 = hh + s1 + ch + ki + wi
              s0 = rotr a 2 `xor` rotr a 13 `xor` rotr a 22
              maj = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
              t2 = s0 + maj
          in [t1 + t2, a, b, c, d + t1, e, f, g]
        step _ _ = error "unreachable"
    rotr :: Word32 -> Int -> Word32
    rotr x n = (x `shiftR` n) .|. (x `shiftL` (32 - n))

sha256Hex :: B.ByteString -> String
sha256Hex = concatMap hex2 . B.unpack . sha256
  where
    hex2 w = [ dig (w `shiftR` 4), dig (w .&. 15) ]
    dig n = "0123456789abcdef" !! fromIntegral n

-- ---------------------------------------------------------------- base64
b64Chars :: String
b64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

b64Encode :: B.ByteString -> String
b64Encode bs = go (B.unpack bs)
  where
    go [] = ""
    go [a] = enc a 0 0 2
    go [a, b] = enc a b 0 1
    go (a : b : c : rest) = enc a b c 0 ++ go rest
    enc a b c npad =
      let n = (fromIntegral a `shiftL` 16) .|. (fromIntegral b `shiftL` 8) .|. fromIntegral c :: Int
          chars = [ b64Chars !! ((n `shiftR` 18) .&. 63)
                  , b64Chars !! ((n `shiftR` 12) .&. 63)
                  , b64Chars !! ((n `shiftR` 6) .&. 63)
                  , b64Chars !! (n .&. 63) ]
      in take (4 - npad) chars ++ replicate npad '='

b64Value :: Char -> Int
b64Value ch
  | ch >= 'A' && ch <= 'Z' = ord ch - ord 'A'
  | ch >= 'a' && ch <= 'z' = ord ch - ord 'a' + 26
  | ch >= '0' && ch <= '9' = ord ch - ord '0' + 52
  | ch == '+' = 62
  | ch == '/' = 63
  | otherwise = -1

b64Decode :: String -> B.ByteString
b64Decode s = B.pack (go clean)
  where
    clean = filter (\ch -> b64Value ch >= 0 || ch == '=') s
    go (a : b : c : d : rest) =
      let n = (b64Value a `shiftL` 18) .|. (b64Value b `shiftL` 12)
            .|. (if c == '=' then 0 else b64Value c `shiftL` 6)
            .|. (if d == '=' then 0 else b64Value d)
      in fromIntegral (n `shiftR` 16)
         : (if c == '=' then [] else fromIntegral ((n `shiftR` 8) .&. 0xff) : [])
         ++ (if d == '=' then [] else [fromIntegral (n .&. 0xff)])
         ++ go rest
    go _ = []

-- ---------------------------------------------------------------- JSON
data Json
  = JNull
  | JBool Bool
  | JInt Integer
  | JFloat Double
  | JStr B.ByteString  -- raw bytes (UTF-8); phext text rides as bytes
  | JArr [Json]
  | JObj [(String, Json)]
  deriving (Eq, Show)

jsonGet :: String -> Json -> Json
jsonGet key (JObj fields) = maybe JNull id (lookup key fields)
jsonGet _ _ = JNull

jsonString :: Json -> B.ByteString
jsonString (JStr s) = s
jsonString _ = ""

jsonInt :: Json -> Integer
jsonInt (JInt n) = n
jsonInt (JFloat f) = truncate f
jsonInt _ = 0

-- parser over bytes; strings are decoded from JSON escapes to raw bytes
-- (\uXXXX -> UTF-8, surrogate pairs combined).
newtype Parser a = Parser { runParser :: B.ByteString -> Either String (a, B.ByteString) }

instance Functor Parser where
  fmap f (Parser p) = Parser $ \bs -> case p bs of
    Left e -> Left e
    Right (a, rest) -> Right (f a, rest)

instance Applicative Parser where
  pure a = Parser $ \bs -> Right (a, bs)
  Parser pf <*> Parser pa = Parser $ \bs -> case pf bs of
    Left e -> Left e
    Right (f, rest) -> case pa rest of
      Left e -> Left e
      Right (a, rest') -> Right (f a, rest')

instance Monad Parser where
  Parser p >>= f = Parser $ \bs -> case p bs of
    Left e -> Left e
    Right (a, rest) -> runParser (f a) rest

pfail :: String -> Parser a
pfail e = Parser $ \_ -> Left e

peekByte :: Parser (Maybe Word8)
peekByte = Parser $ \bs -> Right (if B.null bs then Nothing else Just (B.head bs), bs)

nextByte :: Parser Word8
nextByte = Parser $ \bs ->
  if B.null bs then Left "eof" else Right (B.head bs, B.tail bs)

skipWs :: Parser ()
skipWs = Parser $ \bs -> Right ((), B.dropWhile (\w -> w == 32 || w == 9 || w == 10 || w == 13) bs)

expectByte :: Word8 -> Parser ()
expectByte w = do
  b <- nextByte
  if b == w then pure () else pfail ("expected byte " ++ show w)

utf8Encode :: String -> B.ByteString
utf8Encode = B.pack . concatMap enc
  where
    enc ch
      | cp < 0x80 = [fromIntegral cp]
      | cp < 0x800 = [0xC0 + fromIntegral (cp `shiftR` 6), cont cp]
      | cp < 0x10000 = [0xE0 + fromIntegral (cp `shiftR` 12), cont (cp `shiftR` 6), cont cp]
      | otherwise = [ 0xF0 + fromIntegral (cp `shiftR` 18), cont (cp `shiftR` 12)
                    , cont (cp `shiftR` 6), cont cp ]
      where
        cp = ord ch
        cont v = 0x80 + fromIntegral (v .&. 0x3F)

parseString :: Parser B.ByteString
parseString = do
  expectByte 34
  go []
  where
    go acc = do
      b <- nextByte
      case b of
        34 -> pure (B.concat (reverse acc))
        92 -> do
          e <- nextByte
          case e of
            110 -> go (B.singleton 10 : acc)
            116 -> go (B.singleton 9 : acc)
            114 -> go (B.singleton 13 : acc)
            98 -> go (B.singleton 8 : acc)
            102 -> go (B.singleton 12 : acc)
            47 -> go (B.singleton 47 : acc)
            92 -> go (B.singleton 92 : acc)
            34 -> go (B.singleton 34 : acc)
            117 -> do
              cp <- hex4
              if cp >= 0xD800 && cp <= 0xDBFF
                then do
                  m <- peekByte
                  case m of
                    Just 92 -> do
                      _ <- nextByte
                      e2 <- nextByte
                      if e2 == 117
                        then do
                          lo <- hex4
                          if lo >= 0xDC00 && lo <= 0xDFFF
                            then go (utf8Encode [chr (0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00))] : acc)
                            else go (utf8Encode [chr cp] : acc)
                        else pfail "bad surrogate"
                    _ -> go (utf8Encode [chr cp] : acc)
                else go (utf8Encode [chr cp] : acc)
            _ -> pfail "bad escape"
        _ -> go (B.singleton b : acc)
    hex4 = do
      a <- nextByte; b <- nextByte; c <- nextByte; d <- nextByte
      let hv w
            | w >= 48 && w <= 57 = fromIntegral w - 48
            | w >= 97 && w <= 102 = fromIntegral w - 87
            | w >= 65 && w <= 70 = fromIntegral w - 55
            | otherwise = -1
      if any (< 0) [hv a, hv b, hv c, hv d]
        then pfail "bad \\u"
        else pure (((hv a * 16 + hv b) * 16 + hv c) * 16 + hv d)

parseValue :: Parser Json
parseValue = do
  skipWs
  m <- peekByte
  case m of
    Nothing -> pfail "eof"
    Just 123 -> parseObj
    Just 91 -> parseArr
    Just 34 -> JStr <$> parseString
    Just 116 -> literal "true" (JBool True)
    Just 102 -> literal "false" (JBool False)
    Just 110 -> literal "null" JNull
    Just _ -> parseNumber
  where
    literal word val = do
      bs <- Parser $ \inp -> Right (B.unpack (B.take (length word) inp), B.drop (length word) inp)
      if map (fromIntegral . ord) word == bs then pure val else pfail "bad literal"
    parseObj = do
      expectByte 123
      skipWs
      m <- peekByte
      case m of
        Just 125 -> do _ <- nextByte; pure (JObj [])
        _ -> fields []
      where
        fields acc = do
          skipWs
          k <- parseString
          skipWs
          expectByte 58
          v <- parseValue
          skipWs
          b <- nextByte
          case b of
            44 -> fields ((C.unpack k, v) : acc)
            125 -> pure (JObj (reverse ((C.unpack k, v) : acc)))
            _ -> pfail "expected , or } in object"
    parseArr = do
      expectByte 91
      skipWs
      m <- peekByte
      case m of
        Just 93 -> do _ <- nextByte; pure (JArr [])
        _ -> elems []
      where
        elems acc = do
          v <- parseValue
          skipWs
          b <- nextByte
          case b of
            44 -> elems (v : acc)
            93 -> pure (JArr (reverse (v : acc)))
            _ -> pfail "expected , or ] in array"
    parseNumber = do
      tok <- Parser $ \inp ->
        let (t, rest) = B.span (\w -> (w >= 48 && w <= 57) || w == 45 || w == 43 || w == 46 || w == 101 || w == 69) inp
        in Right (C.unpack t, rest)
      if null tok
        then pfail "bad value"
        else if any (\ch -> ch == '.' || ch == 'e' || ch == 'E') tok
          then pure (JFloat (read tok))
          else pure (JInt (read tok))

parseJson :: B.ByteString -> Either String Json
parseJson bs = case runParser (parseValue <* skipWs) bs of
  Left e -> Left e
  Right (v, _) -> Right v

-- canonical printer: decode the byte string as UTF-8 codepoints, escape
-- exactly like Python ensure_ascii.
canonJson :: Json -> B.ByteString
canonJson = B.concat . go
  where
    go JNull = ["null"]
    go (JBool b) = [if b then "true" else "false"]
    go (JInt n) = [C.pack (show n)]
    go (JFloat f)
      | f == fromIntegral (truncate f :: Integer) = [C.pack (show (truncate f :: Integer))]
      | otherwise = [C.pack (show f)]
    go (JStr s) = ["\"", escape s, "\""]
    go (JArr elems) = ["["] ++ interleave (map go elems) ++ ["]"]
      where interleave [] = []
            interleave [x] = x
            interleave (x : xs) = x ++ [","] ++ interleave xs
    go (JObj fields) =
      let sorted = sortBy (comparing fst) fields
      in ["{"] ++ interleave [ ["\"", escape (C.pack k), "\":"] ++ go v | (k, v) <- sorted ] ++ ["}"]
      where interleave [] = []
            interleave [x] = x
            interleave (x : xs) = x ++ [","] ++ interleave xs
    escape s = B.concat (map escCp (decodeUtf8 (B.unpack s)))
    decodeUtf8 [] = []
    decodeUtf8 (b : rest)
      | b < 0x80 = fromIntegral b : decodeUtf8 rest
      | b < 0xE0 = ((fromIntegral b .&. 0x1F) * 64 + cont (head rest)) : decodeUtf8 (drop 1 rest)
      | b < 0xF0 = ((fromIntegral b .&. 0x0F) * 4096 + cont (head rest) * 64 + cont (rest !! 1)) : decodeUtf8 (drop 2 rest)
      | otherwise = ((fromIntegral b .&. 0x07) * 262144 + cont (head rest) * 4096 + cont (rest !! 1) * 64 + cont (rest !! 2)) : decodeUtf8 (drop 3 rest)
      where cont w = fromIntegral w .&. 0x3F :: Int
    escCp cp
      | cp == 0x22 = "\\\""
      | cp == 0x5C = "\\\\"
      | cp == 0x08 = "\\b"
      | cp == 0x0C = "\\f"
      | cp == 0x0A = "\\n"
      | cp == 0x0D = "\\r"
      | cp == 0x09 = "\\t"
      | cp < 0x20 || cp > 0x7E =
          if cp > 0xFFFF
            then let v = cp - 0x10000
                 in C.pack ("\\u" ++ hex4 (0xD800 + v `div` 1024) ++ "\\u" ++ hex4 (0xDC00 + v `mod` 1024))
            else C.pack ("\\u" ++ hex4 cp)
      | otherwise = B.singleton (fromIntegral cp)
    hex4 n = [ "0123456789abcdef" !! ((n `shiftR` s) .&. 15) | s <- [12, 8, 4, 0] ]
