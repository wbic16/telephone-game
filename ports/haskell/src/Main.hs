{-# LANGUAGE OverloadedStrings #-}
-- Main.hs - Exocortical Telephone Game CLI (contract v2) for the
-- Haskell libphext port. Wire: one JSON request in, one response out;
-- arg "serve" loops over JSON lines. PGP via subprocess gpg on temp
-- files, key home $TELEPHONE_GNUPG_HOME or ~/telephone-haskell/gnupg.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Char (chr)
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, getHomeDirectory, removeDirectoryRecursive)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode(..))
import System.IO (hFlush, hIsEOF, stdout, stdin)
import System.Process (readProcessWithExitCode, callCommand)

import Phext
import Wire

impl :: String
impl = "haskell"

keyUid :: String
keyUid = "libphext telephone " ++ impl

indexCoordS, keysCoordS, keysHashCoordS :: String
indexCoordS = "1.1.1/1.1.1/1.1.1"
keysCoordS = "1.1.1/1.1.1/1.1.2"
keysHashCoordS = "1.1.1/1.1.1/1.1.3"

reserved :: [String]
reserved = [indexCoordS, keysCoordS, keysHashCoordS]

stateBytes :: Json -> B.ByteString
stateBytes req = case jsonGet "state" req of
  JStr s -> b64Decode (C.unpack s)
  _ -> case jsonGet "state_b64" req of
    JStr s -> b64Decode (C.unpack s)
    _ -> B.empty

stripBS :: B.ByteString -> B.ByteString
stripBS s = B.dropWhile isWs (fst (B.spanEnd isWs s))
  where isWs w = w == 32 || w == 9 || w == 10 || w == 13

shq :: String -> String
shq s = "'" ++ concatMap (\ch -> if ch == '\'' then "'\\''" else [ch]) s ++ "'"

gnupgHome :: IO String
gnupgHome = do
  m <- lookupEnv "TELEPHONE_GNUPG_HOME"
  case m of
    Just h -> pure h
    Nothing -> do
      home <- getHomeDirectory
      pure (home ++ "/telephone-" ++ impl ++ "/gnupg")

gpg :: [String] -> Maybe B.ByteString -> IO B.ByteString
gpg args input = do
  home <- gnupgHome
  callCommand ("mkdir -p " ++ shq home ++ " && chmod 700 " ++ shq home)
  let cmd = "gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir "
            ++ shq home ++ " " ++ unwords args
  case input of
    Nothing -> do
      (rc, out, err) <- readProcessWithExitCode "sh" ["-c", cmd] ""
      case rc of
        ExitSuccess -> pure (C.pack out)
        _ -> ioError (userError ("gpg failed: " ++ err))
    Just dat -> do
      tmp <- tempPath "in"
      B.writeFile tmp dat
      (rc, out, err) <- readProcessWithExitCode "sh" ["-c", cmd ++ " < " ++ shq tmp] ""
      callCommand ("rm -f " ++ shq tmp)
      case rc of
        ExitSuccess -> pure (C.pack out)
        _ -> ioError (userError ("gpg failed: " ++ err))

tempPath :: String -> IO String
tempPath tag = do
  m <- lookupEnv "TMPDIR"
  let dir = maybe "/tmp" id m
  pure (dir ++ "/tel-haskell-" ++ tag ++ "-" ++ show (abs (hashStr dir)) ++ ".bin")
  where hashStr = foldl (\a ch -> a * 31 + fromEnum ch) 7

-- unique-enough temp dir via gpg's own mktemp through sh
tempDir :: IO String
tempDir = do
  (rc, out, _) <- readProcessWithExitCode "mktemp" ["-d", "/tmp/tel-haskell-XXXXXX"] ""
  case rc of
    ExitSuccess -> pure (takeWhile (/= '\n') out)
    _ -> ioError (userError "mktemp failed")

keygen :: IO B.ByteString
keygen = do
  listing <- gpg ["--list-keys", "--with-colons"] Nothing
  when ("pub:" `notElem` [ take 4 (C.unpack l) | l <- C.lines listing ]) $ do
    _ <- gpg ["--quick-gen-key", shq keyUid, "ed25519", "sign", "never"] Nothing
    pure ()
  gpg ["--armor", "--export", shq keyUid] Nothing

detachSign :: B.ByteString -> IO B.ByteString
detachSign dat = do
  dir <- tempDir
  B.writeFile (dir ++ "/descriptor.json") dat
  _ <- gpg [ "--detach-sign", "--armor", "--local-user", shq keyUid
           , "--output", shq (dir ++ "/descriptor.asc")
           , shq (dir ++ "/descriptor.json") ] Nothing
  sig <- B.readFile (dir ++ "/descriptor.asc")
  removeDirectoryRecursive dir
  pure sig

verifySignature :: B.ByteString -> B.ByteString -> B.ByteString -> IO Bool
verifySignature pubkeys dat signature = do
  dir <- tempDir
  let home = dir ++ "/gnupg"
  createDirectoryIfMissing True home
  callCommand ("chmod 700 " ++ shq home)
  B.writeFile (dir ++ "/keys.asc") pubkeys
  B.writeFile (dir ++ "/descriptor.json") dat
  B.writeFile (dir ++ "/descriptor.asc") signature
  (rc1, _, _) <- readProcessWithExitCode "sh"
    ["-c", "gpg --batch --yes --homedir " ++ shq home ++ " --import " ++ shq (dir ++ "/keys.asc")] ""
  rc2 <- if rc1 == ExitSuccess
    then do
      (rc, _, _) <- readProcessWithExitCode "sh"
        ["-c", "gpg --batch --yes --homedir " ++ shq home ++ " --verify "
               ++ shq (dir ++ "/descriptor.asc") ++ " " ++ shq (dir ++ "/descriptor.json")] ""
      pure rc
    else pure (ExitFailure 1)
  removeDirectoryRecursive dir
  pure (rc2 == ExitSuccess)

-- ------------------------------------------------------------ game logic
echoValue :: Json -> String
echoValue ping =
  let game = jsonString (jsonGet "game" ping)
      roundS = case jsonGet "round" ping of
        JInt n -> C.pack (show n)
        JStr s -> s
        _ -> case jsonGet "turn" ping of
          JInt n -> C.pack (show n)
          JStr s -> s
          _ -> ""
      nonce = jsonString (jsonGet "nonce" ping)
  in sha256Hex (B.concat [C.pack impl, "|", game, "|", roundS, "|", nonce])

seedByte :: String -> Int -> Int
seedByte hex i = read ("0x" ++ take 2 (drop (i * 2) hex)) :: Int

electWinner :: String -> [String] -> Integer -> String
electWinner position candidates turn =
  let hex = sha256Hex (C.pack (position ++ [chr (fromIntegral (turn `mod` 256))]
                               ++ joinComma candidates))
  in candidates !! (seedByte hex 0 `mod` length candidates)
  where joinComma = foldr (\a b -> if null b then a else a ++ "," ++ b) ""

nextCoord :: Coord -> Coord
nextCoord c = coordFromList (go 8 (coordToList c))
  where
    go d xs
      | d < 0 = xs
      | xs !! d < 999 = take d xs ++ [xs !! d + 1] ++ drop (d + 1) xs
      | otherwise = go (d - 1) (take d xs ++ [1] ++ drop (d + 1) xs)

chooseAdventure :: B.ByteString -> String -> Integer -> Json
chooseAdventure state position turn =
  case parseCoordinate position of
    Nothing -> error ("invalid position " ++ position)
    Just pos ->
      let used0 = explode state
          used = foldl (\m r -> Map.insert (mustParse r) "\x00" m) used0 reserved
          seedHex = sha256Hex (B.concat [C.pack position, B.singleton (fromIntegral (turn `mod` 256)), state])
          dim = seedByte seedHex 1 `mod` 9
          candList = coordToList pos
          cand = coordFromList (take dim candList
                                ++ [((candList !! dim - 1 + 1 + (seedByte seedHex 2 `mod` 3)) `mod` 999) + 1]
                                ++ drop (dim + 1) candList)
          cur = seekFree used cand
          cs = formatCoordinate cur
      in JObj [ ("op", JStr "insert"), ("coordinate", JStr (C.pack cs))
              , ("text", JStr (C.pack (impl ++ " turn " ++ show turn ++ " at " ++ cs))) ]
  where
    mustParse s = case parseCoordinate s of Just c -> c; Nothing -> error "reserved coord"
    seekFree used c = if Map.member c used then seekFree used (nextCoord c) else c

applyStep :: B.ByteString -> Json -> (B.ByteString, Json)
applyStep state step =
  case parseCoordinate (C.unpack (jsonString (jsonGet "coordinate" step))) of
    Nothing -> (state, JNull)
    Just coord ->
      let text = jsonString (jsonGet "text" step)
      in case jsonString (jsonGet "op" step) of
           "insert" -> (insert state coord text, JNull)
           "replace" -> (replace state coord text, JNull)
           "remove" -> (remove state coord, JNull)
           "fetch" -> (state, JStr (C.pack (sha256Hex (fetch state coord))))
           _ -> (state, JNull)

validateStep :: B.ByteString -> Json -> Maybe B.ByteString -> Json
validateStep newState step priorOpt
  | jsonString (jsonGet "op" step) /= "insert" = failWith "step op is not insert"
  | otherwise = case parseCoordinate (C.unpack (jsonString (jsonGet "coordinate" step))) of
      Nothing -> failWith "unparseable coordinate"
      Just coord
        | fetch newState coord /= jsonString (jsonGet "text" step) ->
            failWith ("placed scroll absent or content differs at "
                      ++ C.unpack (jsonString (jsonGet "coordinate" step)))
        | otherwise -> case priorOpt of
            Nothing -> JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "pass")
                            , ("detail", JStr "placed scroll present with attested content (no prior state supplied)") ]
            Just prior
              | fetch prior coord /= B.empty -> failWith "coordinate was not unused in the prior state"
              | otherwise ->
                  let before = explode prior
                      after = explode newState
                  in if Map.size after /= Map.size before + 1
                       then failWith "scroll count did not grow by exactly one"
                       else case [ formatCoordinate c | (c, t) <- Map.toList before, Map.lookup c after /= Just t ] of
                              (c : _) -> failWith ("a prior scroll was overwritten: " ++ c)
                              [] -> JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "pass")
                                         , ("detail", JStr "placed at unused coordinate; all prior scrolls intact") ]
  where failWith d = JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "fail"), ("detail", JStr (C.pack d)) ]

-- serve-mode validator cache (init / driver-form validate)
type Cache = IORef (Maybe (Map.Map Coord B.ByteString))

initCache :: Cache -> B.ByteString -> IO Json
initCache cache state = do
  writeIORef cache (Just (explode state))
  pure (JObj [("impl", JStr (C.pack impl)), ("verdict", JStr "pass")])

rstripNl :: B.ByteString -> B.ByteString
rstripNl s = if B.null s || B.last s /= 10 then s else rstripNl (B.init s)

validateDriver :: Cache -> B.ByteString -> Json -> String -> String -> IO Json
validateDriver cache newState step eventCoordS indexLine = do
  mOld <- readIORef cache
  case mOld of
    Nothing -> pure (failWith "no prior state (init not called)")
    Just old ->
      let newMap = explode newState
      in case parseCoordinate (C.unpack (jsonString (jsonGet "coordinate" step))) of
           Nothing -> pure (failWith "unparseable coordinate")
           Just coord
             | Map.lookup coord newMap /= Just (jsonString (jsonGet "text" step)) ->
                 pure (failWith "placed scroll missing or altered")
             | otherwise ->
                 case [ formatCoordinate c | (c, t) <- Map.toList old, c /= mustCoord indexCoordS, Map.lookup c newMap /= Just t ] of
                   (c : _) -> pure (failWith ("prior scroll overwritten at " ++ c))
                   [] -> case [ formatCoordinate c | c <- Map.keys newMap
                                                   , not (Map.member c old)
                                                   , formatCoordinate c /= formatCoordinate coord
                                                   , formatCoordinate c /= eventCoordS ] of
                           (c : _) -> pure (failWith ("unexpected new scroll at " ++ c))
                           [] ->
                             let idx = Map.findWithDefault B.empty (mustCoord indexCoordS) newMap
                             in if rstripNl idx `endsWith` rstripNl (C.pack indexLine)
                                  then do
                                    writeIORef cache (Just newMap)
                                    pure (JObj [("impl", JStr (C.pack impl)), ("verdict", JStr "pass")])
                                  else pure (failWith "index does not record the placement")
  where
    failWith d = JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "fail"), ("detail", JStr (C.pack d)) ]
    mustCoord s = case parseCoordinate s of Just c -> c; Nothing -> error "coord"
    endsWith s suffix = suffix `B.isSuffixOf` s

verifyGame :: B.ByteString -> B.ByteString -> IO Json
verifyGame state pubkeys = do
  let scrolls = explode state
      keysText = Map.findWithDefault B.empty (mustCoord keysCoordS) scrolls
      failWith msg n = JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "fail")
                            , ("placements_checked", JInt n)
                            , ("first_failure", JObj [("detail", JStr (C.pack msg))]) ]
      mustCoord s = case parseCoordinate s of Just c -> c; Nothing -> error "coord"
  if B.null keysText
    then pure (failWith ("no public-keys scroll at " ++ keysCoordS) 0)
    else if stripBS pubkeys /= stripBS keysText
      then pure (failWith "supplied pubkeys do not match the inscribed keys scroll" 0)
      else if not (Map.member (mustCoord keysHashCoordS) scrolls)
        then pure (failWith ("no keys-hash scroll at " ++ keysHashCoordS) 0)
        else if stripBS (scrolls Map.! mustCoord keysHashCoordS) /= C.pack (sha256Hex keysText)
          then pure (failWith "keys-hash scroll does not match the keys scroll" 0)
          else do
            let indexText = Map.findWithDefault B.empty (mustCoord indexCoordS) scrolls
                parsedLines = [ words (C.unpack (stripBS l)) | l <- C.lines indexText
                              , not (B.null (stripBS l)), C.head (stripBS l) /= '#' ]
            if any (\f -> length f /= 4) parsedLines
              then pure (failWith "malformed index line" 0)
              else do
                let index = Map.fromList [ (c, (t, h, a)) | [t, c, h, a] <- parsedLines ]
                walk scrolls index keysText failWith 1 Nothing Map.empty 0
  where
    walk scrolls index keysText failWith seq prevHash seen checked = do
      let ecoord = coordFromList [1, 1, 1, 1, 1, 1, 2, 1, seq]
      case Map.lookup ecoord scrolls of
        Nothing -> finish index seen checked failWith
        Just evText -> case parseJson evText of
          Left _ -> pure (failWith ("event " ++ show seq ++ " is not a JSON object") (fromIntegral checked))
          Right ev -> do
            let body = jsonGet "body" ev
            case body of
              JObj _ -> pure ()
              _ -> pure ()
            case body of
              JObj _ -> do
                let prevOk = case (jsonGet "prev" ev, prevHash) of
                      (JNull, Nothing) -> True
                      (JStr p, Just ph) -> C.unpack p == ph
                      _ -> False
                if not prevOk
                  then pure (failWith (if seq == 1 then "event 1 prev is not null"
                                       else "event chain broken at seq " ++ show seq) (fromIntegral checked))
                  else do
                    let newPrev = sha256Hex (canonJson body)
                    if jsonString (jsonGet "type" body) /= "placement"
                      then walk scrolls index keysText failWith (seq + 1) (Just newPrev) seen checked
                      else do
                        let coordS = C.unpack (jsonString (jsonGet "coord" body))
                            textHash = C.unpack (jsonString (jsonGet "text_sha256" body))
                            fileHash = C.unpack (jsonString (jsonGet "file_sha256" body))
                            attB64 = jsonString (jsonGet "att" body)
                            turn = jsonInt (jsonGet "turn" body)
                            actor = C.unpack (jsonString (jsonGet "actor" body))
                        if null coordS || null textHash || null fileHash || B.null attB64
                          then pure (failWith ("event " ++ show seq ++ " lacks coord/text_sha256/file_sha256/att") (fromIntegral checked))
                          else if coordS `elem` Map.keys seen
                            then pure (failWith ("coordinate reused at " ++ coordS) (fromIntegral checked))
                            else case parseCoordinate coordS of
                              Nothing -> pure (failWith ("bad coordinate " ++ coordS) (fromIntegral checked))
                              Just coord
                                | not (Map.member coord scrolls) ->
                                    pure (failWith ("placement missing at " ++ coordS) (fromIntegral checked))
                                | sha256Hex (scrolls Map.! coord) /= textHash ->
                                    pure (failWith ("placement hash mismatch at " ++ coordS) (fromIntegral checked))
                                | otherwise -> case Map.lookup coordS index of
                                    Just (iturn, ihash, iactor)
                                      | ihash == textHash && iturn == show turn && iactor == actor -> do
                                          let desc = JObj [ ("turn", JInt turn), ("coordinate", JStr (C.pack coordS))
                                                          , ("scroll_sha256", JStr (C.pack textHash))
                                                          , ("file_sha256", JStr (C.pack fileHash)) ]
                                          ok <- verifySignature keysText (canonJson desc) (b64Decode (C.unpack attB64))
                                          if ok
                                            then walk scrolls index keysText failWith (seq + 1) (Just newPrev)
                                                   (Map.insert coordS True seen) (checked + 1)
                                            else pure (failWith ("event " ++ show seq ++ " signature invalid") (fromIntegral checked))
                                    _ -> pure (failWith ("index mismatch at " ++ coordS) (fromIntegral checked))
              _ -> pure (failWith ("event " ++ show seq ++ " is not a JSON object") (fromIntegral checked))
    finish index seen checked failWith
      | checked == 0 = pure (failWith "no placement events found" 0)
      | otherwise = case [ cs | cs <- Map.keys index, not (Map.member cs seen) ] of
          (cs : _) -> pure (failWith ("index lists a placement with no event: " ++ cs) (fromIntegral checked))
          [] -> pure (JObj [ ("impl", JStr (C.pack impl)), ("verdict", JStr "pass")
                           , ("placements_checked", JInt (fromIntegral checked))
                           , ("first_failure", JNull) ])

handle :: Cache -> Json -> IO Json
handle cache req = case C.unpack (jsonString (jsonGet "cmd" req)) of
  "id" -> pure (JObj [("impl", JStr (C.pack impl))])
  "echo" -> pure (JObj [ ("impl", JStr (C.pack impl))
                       , ("echo", JStr (C.pack (echoValue (jsonGet "ping" req)))) ])
  "elect" -> do
    let cands = case jsonGet "candidates" req of
          JArr elems -> map (C.unpack . jsonString) elems
          _ -> []
    if null cands
      then ioError (userError "elect: no candidates")
      else pure (JObj [("elect", JStr (C.pack (electWinner
                        (C.unpack (jsonString (jsonGet "position" req))) cands
                        (jsonInt (jsonGet "turn" req)))))])
  "choose" -> pure (chooseAdventure (stateBytes req)
                      (C.unpack (jsonString (jsonGet "position" req)))
                      (jsonInt (jsonGet "turn" req)))
  "apply" -> do
    let (ns, fh) = applyStep (stateBytes req) (jsonGet "step" req)
    pure (JObj [ ("state_b64", JStr (C.pack (b64Encode ns)))
               , ("state_sha256", JStr (C.pack (sha256Hex ns)))
               , ("fetch_sha256", fh) ])
  "keygen" -> do
    pub <- keygen
    pure (JObj [("impl", JStr (C.pack impl)), ("pubkey", JStr pub)])
  "attest" -> do
    sig <- detachSign (canonJson (jsonGet "descriptor" req))
    pure (JObj [("signature", JStr sig)])
  "init" -> initCache cache (stateBytes req)
  "validate" -> case jsonGet "event_coord" req of
    JStr _ -> validateDriver cache (stateBytes req) (jsonGet "step" req)
                (C.unpack (jsonString (jsonGet "event_coord" req)))
                (C.unpack (jsonString (jsonGet "index_line" req)))
    _ -> do
      let priorOpt = case jsonGet "prior_state" req of
            JStr s -> Just (b64Decode (C.unpack s))
            _ -> Nothing
      pure (validateStep (stateBytes req) (jsonGet "step" req) priorOpt)
  "verify" -> verifyGame (stateBytes req) (jsonString (jsonGet "pubkeys" req))
  other -> ioError (userError ("unknown cmd " ++ other))

-- Game-scale framing: lines over 8 KB may arrive gzip-framed as
-- "GZ1:" + base64(gzip(line)); GHC boot libraries have no zlib, so
-- (de)compression shells to the system gzip(1) on temp files (the
-- same idiom as the gpg calls above). Lossless; plain lines unchanged.
gzVia :: B.ByteString -> String -> IO B.ByteString
gzVia dat flag = do
  dir <- tempDir
  let fin = dir ++ "/in"
      fout = dir ++ "/out"
  B.writeFile fin dat
  callCommand ("gzip " ++ flag ++ " " ++ shq fin ++ " > " ++ shq fout)
  out <- B.readFile fout
  removeDirectoryRecursive dir
  pure out

gzUnframe :: String -> IO B.ByteString
gzUnframe s = gzVia (b64Decode (drop 4 s)) "-dc"

gzFrame :: B.ByteString -> IO String
gzFrame s = do
  out <- gzVia s "-c"
  pure ("GZ1:" ++ b64Encode out)

main :: IO ()
main = do
  args <- getArgs
  cache <- newIORef Nothing
  case args of
    ["serve"] -> serveLoop cache
    _ -> do
      raw <- B.hGetContents stdin
      case parseJson raw of
        Left e -> ioError (userError ("bad request json: " ++ e))
        Right req -> do
          out <- handle cache req
          B.putStr (B.append (canonJson out) "\n")
  where
    serveLoop cache = do
      eof <- hIsEOF stdin
      when (not eof) $ do
        line <- B.hGetLine stdin
        when (not (B.null (stripBS line))) $ do
          lineBytes <- if "GZ1:" `isPrefixOf` C.unpack line
                         then gzUnframe (C.unpack line)
                         else pure line
          out <- case parseJson lineBytes of
            Left e -> pure (JObj [("error", JStr (C.pack e))])
            Right req -> do
              r <- try (handle cache req) :: IO (Either SomeException Json)
              case r of
                Left e -> pure (JObj [("error", JStr (C.pack (show e)))])
                Right v -> pure v
          let outj = canonJson out
          outLine <- if B.length outj > 8192
                       then C.pack <$> gzFrame outj
                       else pure outj
          B.putStr (B.append outLine "\n")
          hFlush stdout
        serveLoop cache
