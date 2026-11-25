{-# LANGUAGE OverloadedStrings #-}
-- Test suite for the Haskell libphext port. Build/run via
-- tests/run_tests.sh; fixtures via PHEXT_FIXTURES env.
module Main (main) where

import Control.Monad (forM_, when)
import Data.IORef
import Data.List (sort)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

import Phext

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check cond name =
        if cond
          then putStrLn ("ok - " ++ name)
          else do
            modifyIORef' failures (+ 1)
            putStrLn ("FAIL - " ++ name)
      coord s = case parseCoordinate s of
        Just c -> c
        Nothing -> error ("bad coord " ++ s)
  check (formatCoordinate (coord "1.2.3/4.5.6/7.8.9") == "1.2.3/4.5.6/7.8.9") "coordinate round trip"
  check (parseCoordinate "0.1.1/1.1.1/1.1.1" == Nothing) "coordinate rejects 0"
  check (parseCoordinate "1.1.1/1.1.1" == Nothing) "coordinate rejects short"
  check (coord "1.1.1/1.1.1/1.1.9" < coord "1.1.1/1.1.2/1.1.1") "order: section beats scroll"
  check (coord "2.1.1/1.1.1/1.1.1" < coord "10.1.1/1.1.1/1.1.1") "order: numeric not string"
  let buf = "a\x17\&b\x18\&c\x01\&d" :: B.ByteString
      scrolls = phokenize buf
      got = [ formatCoordinate (psCoord ps) ++ ":" ++ show (psText ps) | ps <- scrolls ]
  check (got == [ "1.1.1/1.1.1/1.1.1:\"a\"", "1.1.1/1.1.1/1.1.2:\"b\""
                , "1.1.1/1.1.1/1.2.1:\"c\"", "2.1.1/1.1.1/1.1.1:\"d\"" ]) "phokenize breaks"
  check (dephokenize scrolls == buf) "dephokenize round trip"
  let s = phokenize "line1\nline2"
  check (length s == 1 && psText (head s) == "line1\nline2") "newline is text"
  check (fetch "hello" (coord "1.1.1/1.1.1/1.1.2") == "") "gap fetch is empty"
  check (fetch "hello" (coord "9.9.9/9.9.9/9.9.9") == "") "far gap fetch is empty"
  check (fetch "hello" (coord "1.1.1/1.1.1/1.1.1") == "hello") "fetch hit"
  let buf1 = insert "base" (coord "1.1.1/1.1.1/1.1.1") "+more"
  check (fetch buf1 (coord "1.1.1/1.1.1/1.1.1") == "base+more") "insert merges existing+inserted"
  let buf2 = insert buf1 (coord "1.1.1/1.1.1/1.1.3") "third"
  check (buf2 == "base+more\x17\x17third") "insert creates in canonical position"
  let buf3 = replace "a\x17\&b\x17\&c" (coord "1.1.1/1.1.1/1.1.2") "B"
  check (buf3 == "a\x17\&B\x17\&c") "replace overwrites"
  let buf4 = remove buf3 (coord "1.1.1/1.1.1/1.1.2")
  check (buf4 == "a\x17\x17\&c") "remove coordinate-preserving: c stays at scroll 3"
  check (fetch buf4 (coord "1.1.1/1.1.1/1.1.2") == "") "fetch after remove is empty"
  check (fetch buf4 (coord "1.1.1/1.1.1/1.1.3") == "c") "later scroll did NOT shift after remove"
  check (remove buf4 (coord "5.5.5/5.5.5/5.5.5") == buf4) "remove gap is no-op"
  let m = explode "x\x17y\x01z"
  check (Map.size m == 3 && implode m == "x\x17y\x01z") "explode/implode round trip"
  -- store equivalence over a seeded op sequence
  let ops = [ ("insert", "1.1.1/1.1.1/1.1.1", "+X"), ("insert", "1.1.1/1.1.1/1.1.3", "third")
            , ("replace", "1.1.1/1.1.1/1.1.2", "B"), ("remove", "1.1.1/1.1.1/1.1.1", "")
            , ("insert", "2.1.1/1.1.1/1.1.1", "lib2"), ("remove", "1.1.1/1.1.1/1.1.3", "")
            , ("replace", "9.9.9/9.9.9/9.9.9", "far"), ("insert", "1.1.1/1.1.1/1.1.2", "-tail") ]
      step (d, t, r) (kind, at, text) =
        let c = coord at
        in case kind of
             "insert" -> (dynamicInsert d c text, transitiveInsert t c text, insert r c text)
             "replace" -> (dynamicReplace d c text, transitiveReplace t c text, replace r c text)
             _ -> (dynamicRemove d c, transitiveRemove t c, remove r c)
      go _ [] = pure ()
      go state ((kind, at, text) : rest) = do
        let (d, t, r) = step state (kind, at, text)
            want = normalize r
            c = coord at
        check (dynamicSerialize d == want) ("DynamicPhext serialize matches after " ++ kind ++ " " ++ at)
        check (transitiveSerialize t == want) ("TransitivePhext serialize matches after " ++ kind ++ " " ++ at)
        check (dynamicFetch d c == fetch want c) ("DynamicPhext fetch matches after " ++ kind ++ " " ++ at)
        check (transitiveFetch t c == fetch want c) ("TransitivePhext fetch matches after " ++ kind ++ " " ++ at)
        go (d, t, r) rest
  go (dynamicCreate "a\x17\&b", transitiveCreate "a\x17\&b", "a\x17\&b") ops
  let d2 = foldl (\acc i -> dynamicAppend acc (coord ("1.1.1/1.1.1/1.1." ++ show i)) (B.pack (map (fromIntegral . fromEnum) ("s" ++ show i)))) (dynamicCreate "") [1 .. 20 :: Int]
  check (dynamicLen d2 == 20 && dynCapacity d2 >= 20 && dynCapacity d2 < 40)
    ("DynamicPhext capacity doubling (cap=" ++ show (dynCapacity d2) ++ ")")
  let d3 = foldl (\acc i -> dynamicRemove acc (coord ("1.1.1/1.1.1/1.1." ++ show i))) d2 [20, 19 .. 6 :: Int]
  check (dynamicLen d3 == 5) "DynamicPhext removals"
  check (transitiveDepth (transitiveCreate "") == 9) "TransitivePhext depth 9"
  -- fixtures
  mdir <- lookupEnv "PHEXT_FIXTURES"
  case mdir of
    Nothing -> putStrLn "skip - fixtures (PHEXT_FIXTURES not set)"
    Just dir -> do
      paths <- sort <$> collect dir
      identical <- newIORef (0 :: Int)
      forM_ paths $ \path -> do
        dat <- B.readFile path
        when (dephokenize (phokenize dat) == dat) $ modifyIORef' identical (+ 1)
        let n1 = normalize dat
        check (normalize n1 == n1) ("fixture normalize idempotent: " ++ path)
      nIdent <- readIORef identical
      check (not (null paths)) ("fixtures found (" ++ show (length paths) ++ ")")
      check (nIdent == length paths)
        ("fixtures byte-identical round-trips (" ++ show nIdent ++ "/" ++ show (length paths) ++ ")")
  n <- readIORef failures
  putStrLn (if n == 0 then "PASS" else "FAILURES: " ++ show n)
  if n == 0 then exitSuccess else exitFailure
  where
    collect dir = do
      entries <- listDirectory dir
      concat <$> mapM step entries
      where
        step name = do
          let p = dir </> name
          isDir <- doesDirectoryExist p
          if isDir then collect p
            else pure (if name == "input.phext" then [p] else [])
