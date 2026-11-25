{-# LANGUAGE OverloadedStrings #-}
-- Phext.hs - libphext port for Haskell (0.6.1 parity semantics;
-- normative reference: libphext-py). 9-dimensional plain-text format:
-- scrolls addressed by a coordinate, separated by dimension-break
-- bytes. Breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F, 2 series
-- 0x1E, 3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19,
-- 7 section 0x18, 8 scroll 0x17. Newline is ordinary text.
-- Coordinates are 9-tuples, each component >= 1. Buffers are strict
-- ByteStrings (bytes, never decoded text).
module Phext
  ( Coord, coordToList, coordFromList, parseCoordinate, formatCoordinate
  , PositionedScroll(..)
  , phokenize, dephokenize, normalize, fetch, insert, replace, remove
  , explode, implode
  , DynamicPhext(..), dynamicCreate, dynamicLoad, dynamicScrolls
  , dynamicSerialize, dynamicFetch, dynamicContains, dynamicLen
  , dynamicAppend, dynamicInsert, dynamicReplace, dynamicRemove
  , TransitivePhext(..), transitiveCreate, transitiveLoad
  , transitiveScrolls, transitiveSerialize, transitiveFetch
  , transitiveContains, transitiveLen, transitiveDepth
  , transitiveInsert, transitiveReplace, transitiveRemove, transitiveAppend
  ) where

import Data.Char (isDigit)
import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map

type Coord = (Int, Int, Int, Int, Int, Int, Int, Int, Int)

data PositionedScroll = PositionedScroll
  { psCoord :: Coord
  , psText :: B.ByteString
  } deriving (Eq, Show)

breaks :: [Int]
breaks = [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17]

breakDim :: Int -> Maybe Int
breakDim b = lookup b (zip breaks [0 ..])

coordToList :: Coord -> [Int]
coordToList (a, b, c, d, e, f, g, h, i) = [a, b, c, d, e, f, g, h, i]

coordFromList :: [Int] -> Coord
coordFromList [a, b, c, d, e, f, g, h, i] = (a, b, c, d, e, f, g, h, i)
coordFromList _ = error "coordFromList: need exactly 9 components"

parseCoordinate :: String -> Maybe Coord
parseCoordinate s =
  let groups = splitOn '/' (trim s)
  in if length groups /= 3
       then Nothing
       else
         let parts = concatMap (splitOn '.') groups
         in if length parts /= 9 || any (not . valid) parts
              then Nothing
              else Just (coordFromList (map read parts))
  where
    valid p = not (null p) && all isDigit p && (read p :: Int) >= 1
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
    splitOn ch str = case break (== ch) str of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitOn ch rest

formatCoordinate :: Coord -> String
formatCoordinate c =
  let [a, b, cc, d, e, f, g, h, i] = map show (coordToList c)
  in a ++ "." ++ b ++ "." ++ cc ++ "/" ++ d ++ "." ++ e ++ "." ++ f
     ++ "/" ++ g ++ "." ++ h ++ "." ++ i

applyBreak :: [Int] -> Int -> [Int]
applyBreak coord d =
  take d coord ++ [coord !! d + 1] ++ replicate (8 - d) 1

phokenize :: B.ByteString -> [PositionedScroll]
phokenize buffer = go 0 [1, 1, 1, 1, 1, 1, 1, 1, 1]
  where
    len = B.length buffer
    go i walker
      | i >= len = []
      | otherwise = case breakDim (fromIntegral (B.index buffer i)) of
          Just d -> go (i + 1) (applyBreak walker d)
          Nothing ->
            let j = scan i
                text = B.take (j - i) (B.drop i buffer)
            in PositionedScroll (coordFromList walker) text : go j walker
      where
        scan k
          | k >= len = k
          | otherwise = case breakDim (fromIntegral (B.index buffer k)) of
              Just _ -> k
              Nothing -> scan (k + 1)

advance :: [Int] -> Coord -> (B.ByteString, [Int])
advance loc targetCoord
  | loc >= coordToList targetCoord = (B.empty, loc)
  | otherwise =
      let target = coordToList targetCoord
          d = head [ i | i <- [0 .. 8], loc !! i /= target !! i ]
          first = B.replicate (target !! d - loc !! d) (fromIntegral (breaks !! d))
          reached0 = take d loc ++ [target !! d] ++ replicate (8 - d) 1
          (rest, reached) = buildLower (d + 1) reached0
          buildLower k reached
            | k > 8 = (B.empty, reached)
            | otherwise =
                let bytes = B.replicate (target !! k - 1) (fromIntegral (breaks !! k))
                    reached' = take k reached ++ [target !! k] ++ drop (k + 1) reached
                    (more, final) = buildLower (k + 1) reached'
                in (B.append bytes more, final)
      in (B.append first rest, reached)

dephokenize :: [PositionedScroll] -> B.ByteString
dephokenize = go [1, 1, 1, 1, 1, 1, 1, 1, 1]
  where
    go _ [] = B.empty
    go loc (ps : rest) =
      let (bytes, loc') = advance loc (psCoord ps)
      in B.concat [bytes, psText ps, go loc' rest]

normalize :: B.ByteString -> B.ByteString
normalize = dephokenize . phokenize

fetch :: B.ByteString -> Coord -> B.ByteString
fetch buffer coord = case filter ((== coord) . psCoord) (phokenize buffer) of
  (ps : _) -> psText ps
  [] -> B.empty

update :: B.ByteString -> Coord -> B.ByteString -> Bool -> B.ByteString
update buffer coord text overwrite = dephokenize (go (phokenize buffer) False)
  where
    nxt = PositionedScroll coord text
    go [] appended = if appended then [] else [nxt]
    go (ps : rest) appended
      | not appended && psCoord ps > coord = nxt : ps : go rest True
      | not appended && psCoord ps == coord =
          let merged = if overwrite then nxt else PositionedScroll coord (B.append (psText ps) text)
          in merged : go rest True
      | otherwise = ps : go rest appended

insert :: B.ByteString -> Coord -> B.ByteString -> B.ByteString
insert buffer coord text = update buffer coord text False

replace :: B.ByteString -> Coord -> B.ByteString -> B.ByteString
replace buffer coord text = update buffer coord text True

-- remove is COORDINATE-PRESERVING: the scroll becomes empty, the
-- delimiters stay, later scrolls do NOT shift.
remove :: B.ByteString -> Coord -> B.ByteString
remove buffer coord = normalize (update buffer coord B.empty True)

explode :: B.ByteString -> Map.Map Coord B.ByteString
explode buffer = Map.fromList [ (psCoord ps, psText ps) | ps <- phokenize buffer ]

implode :: Map.Map Coord B.ByteString -> B.ByteString
implode m = dephokenize [ PositionedScroll c t | (c, t) <- Map.toAscList m ]

-- ---------------- DynamicPhext: capacity-managed dynamic array --------
-- Modelled purely: the record carries the scroll array (as a list),
-- its capacity, and the resize bookkeeping the Python store exposes.
data DynamicPhext = DynamicPhext
  { dynItems :: [PositionedScroll]
  , dynCapacity :: Int
  , dynShrinkDivisor :: Int
  , dynResizeCount :: Int
  , dynElementsCopied :: Int
  } deriving (Show)

dynamicCreate :: B.ByteString -> DynamicPhext
dynamicCreate = dynamicCreateWith 4

dynamicCreateWith :: Int -> B.ByteString -> DynamicPhext
dynamicCreateWith divisor buffer
  | divisor < 2 = error "shrink_divisor must be >= 2"
  | otherwise = foldl push empty (phokenize buffer)
  where
    empty = DynamicPhext [] 1 divisor 0 0
    push d ps
      | length (dynItems d) == dynCapacity d =
          let d' = d { dynCapacity = 2 * dynCapacity d
                     , dynResizeCount = dynResizeCount d + 1
                     , dynElementsCopied = dynElementsCopied d + length (dynItems d) }
          in d' { dynItems = dynItems d' ++ [ps] }
      | otherwise = d { dynItems = dynItems d ++ [ps] }

dynamicLoad :: DynamicPhext -> B.ByteString -> DynamicPhext
dynamicLoad d buffer = foldl push empty (phokenize buffer)
  where
    empty = DynamicPhext [] 1 (dynShrinkDivisor d) 0 0
    push = \acc ps -> dynamicPush acc ps

dynamicPush :: DynamicPhext -> PositionedScroll -> DynamicPhext
dynamicPush d ps
  | length (dynItems d) == dynCapacity d =
      let d' = d { dynCapacity = 2 * dynCapacity d
                 , dynResizeCount = dynResizeCount d + 1
                 , dynElementsCopied = dynElementsCopied d + length (dynItems d) }
      in d' { dynItems = dynItems d' ++ [ps] }
  | otherwise = d { dynItems = dynItems d ++ [ps] }

dynamicShrink :: DynamicPhext -> DynamicPhext
dynamicShrink d
  | dynCapacity d > 1 && length (dynItems d) <= dynCapacity d `div` dynShrinkDivisor d =
      d { dynCapacity = max 1 (dynCapacity d `div` 2)
        , dynResizeCount = dynResizeCount d + 1
        , dynElementsCopied = dynElementsCopied d + length (dynItems d) }
  | otherwise = d

dynamicScrolls :: DynamicPhext -> [PositionedScroll]
dynamicScrolls = dynItems

dynamicSerialize :: DynamicPhext -> B.ByteString
dynamicSerialize = dephokenize . dynItems

dynamicFind :: DynamicPhext -> Coord -> (Int, Bool)
dynamicFind d coord = go 0 (length (dynItems d))
  where
    items = dynItems d
    go lo hi
      | lo >= hi = (lo, False)
      | otherwise =
          let mid = (lo + hi) `div` 2
          in case compare (psCoord (items !! mid)) coord of
               LT -> go (mid + 1) hi
               GT -> go lo mid
               EQ -> (mid, True)

dynamicFetch :: DynamicPhext -> Coord -> B.ByteString
dynamicFetch d coord = case dynamicFind d coord of
  (idx, True) -> psText (dynItems d !! idx)
  _ -> B.empty

dynamicContains :: DynamicPhext -> Coord -> Bool
dynamicContains d coord = snd (dynamicFind d coord)

dynamicLen :: DynamicPhext -> Int
dynamicLen = length . dynItems

dynamicAppend :: DynamicPhext -> Coord -> B.ByteString -> DynamicPhext
dynamicAppend d coord text
  | not (null (dynItems d)) && coord <= psCoord (last (dynItems d)) =
      error "append requires a coordinate past the current tail"
  | B.null text = d
  | otherwise = dynamicPush d (PositionedScroll coord text)

dynamicUpdate :: DynamicPhext -> Coord -> B.ByteString -> Bool -> DynamicPhext
dynamicUpdate d coord text overwrite =
  case dynamicFind d coord of
    (idx, True)
      | B.null text -> if overwrite then removeAt idx else d
      | otherwise ->
          let old = dynItems d !! idx
              t = if overwrite then text else B.append (psText old) text
          in d { dynItems = take idx (dynItems d) ++ [PositionedScroll coord t] ++ drop (idx + 1) (dynItems d) }
    (idx, False)
      | B.null text -> d
      | otherwise ->
          let grown = if length (dynItems d) == dynCapacity d
                        then d { dynCapacity = 2 * dynCapacity d
                               , dynResizeCount = dynResizeCount d + 1
                               , dynElementsCopied = dynElementsCopied d + length (dynItems d) }
                        else d
          in grown { dynItems = take idx (dynItems grown) ++ [PositionedScroll coord text] ++ drop idx (dynItems grown) }
  where
    removeAt idx = dynamicShrink d { dynItems = take idx (dynItems d) ++ drop (idx + 1) (dynItems d) }

dynamicInsert :: DynamicPhext -> Coord -> B.ByteString -> DynamicPhext
dynamicInsert d coord text = dynamicUpdate d coord text False

dynamicReplace :: DynamicPhext -> Coord -> B.ByteString -> DynamicPhext
dynamicReplace d coord text = dynamicUpdate d coord text True

dynamicRemove :: DynamicPhext -> Coord -> DynamicPhext
dynamicRemove d coord = case dynamicFind d coord of
  (idx, True) -> dynamicShrink d { dynItems = take idx (dynItems d) ++ drop (idx + 1) (dynItems d) }
  _ -> d

-- ---------------- TransitivePhext: branching hash map, depth 9 -------
data BNode = BNode
  { bnChildren :: Map.Map Int BNode
  , bnLeaf :: Maybe B.ByteString
  }

emptyNode :: BNode
emptyNode = BNode Map.empty Nothing

data TransitivePhext = TransitivePhext
  { transRoot :: BNode
  , transCount :: Int
  }

transitiveDepth :: TransitivePhext -> Int
transitiveDepth _ = 9

branchFetch :: BNode -> [Int] -> Maybe B.ByteString
branchFetch node [] = bnLeaf node
branchFetch node (k : rest) = case Map.lookup k (bnChildren node) of
  Nothing -> Nothing
  Just child -> branchFetch child rest

branchPut :: BNode -> [Int] -> B.ByteString -> (BNode, Bool)
branchPut node [] value = (node { bnLeaf = Just value }, bnLeaf node == Nothing)
branchPut node (k : rest) value =
  let child = Map.findWithDefault emptyNode k (bnChildren node)
      (child', created) = branchPut child rest value
  in (node { bnChildren = Map.insert k child' (bnChildren node) }, created)

branchRemove :: BNode -> [Int] -> (BNode, Bool)
branchRemove node [] = (node { bnLeaf = Nothing }, bnLeaf node /= Nothing)
branchRemove node (k : rest) = case Map.lookup k (bnChildren node) of
  Nothing -> (node, False)
  Just child ->
    let (child', removed) = branchRemove child rest
        children' = if removed && Map.null (bnChildren child') && bnLeaf child' == Nothing
                      then Map.delete k (bnChildren node)
                      else Map.insert k child' (bnChildren node)
    in (node { bnChildren = children' }, removed)

branchItems :: BNode -> [Int] -> [PositionedScroll]
branchItems node prefix
  | length prefix == 9 = case bnLeaf node of
      Just v -> [PositionedScroll (coordFromList prefix) v]
      Nothing -> []
  | otherwise =
      concat [ branchItems child (prefix ++ [k])
             | (k, child) <- Map.toAscList (bnChildren node) ]

transitiveCreate :: B.ByteString -> TransitivePhext
transitiveCreate buffer =
  foldl step (TransitivePhext emptyNode 0) (phokenize buffer)
  where
    step t ps =
      let (root', created) = branchPut (transRoot t) (coordToList (psCoord ps)) (psText ps)
      in TransitivePhext root' (transCount t + if created then 1 else 0)

transitiveLoad :: TransitivePhext -> B.ByteString -> TransitivePhext
transitiveLoad _ buffer = transitiveCreate buffer

transitiveScrolls :: TransitivePhext -> [PositionedScroll]
transitiveScrolls t = sortBy (comparing psCoord) (branchItems (transRoot t) [])

transitiveSerialize :: TransitivePhext -> B.ByteString
transitiveSerialize = dephokenize . transitiveScrolls

transitiveFetch :: TransitivePhext -> Coord -> B.ByteString
transitiveFetch t coord = case branchFetch (transRoot t) (coordToList coord) of
  Just v -> v
  Nothing -> B.empty

transitiveContains :: TransitivePhext -> Coord -> Bool
transitiveContains t coord = branchFetch (transRoot t) (coordToList coord) /= Nothing

transitiveLen :: TransitivePhext -> Int
transitiveLen = transCount

transitiveUpdate :: TransitivePhext -> Coord -> B.ByteString -> Bool -> TransitivePhext
transitiveUpdate t coord text overwrite
  | B.null text = if overwrite then transitiveRemove t coord else t
  | otherwise =
      let txt = if overwrite
                  then text
                  else B.append (transitiveFetch t coord) text
          (root', created) = branchPut (transRoot t) (coordToList coord) txt
      in TransitivePhext root' (transCount t + if created then 1 else 0)

transitiveInsert :: TransitivePhext -> Coord -> B.ByteString -> TransitivePhext
transitiveInsert t coord text = transitiveUpdate t coord text False

transitiveReplace :: TransitivePhext -> Coord -> B.ByteString -> TransitivePhext
transitiveReplace t coord text = transitiveUpdate t coord text True

transitiveRemove :: TransitivePhext -> Coord -> TransitivePhext
transitiveRemove t coord =
  let (root', removed) = branchRemove (transRoot t) (coordToList coord)
  in TransitivePhext root' (transCount t - if removed then 1 else 0)

transitiveAppend :: TransitivePhext -> Coord -> B.ByteString -> TransitivePhext
transitiveAppend = transitiveInsert
