-- | Pure text corpus utilities for semantic review builtins (§13.1.8 Tier 2).
module Hwfi.Text.Corpus
  ( TokenizeMode (..),
    SimilarityMethod (..),
    SplitOn (..),
    TextMetrics (..),
    SimilarityResult (..),
    CorpusCluster (..),
    CorpusDocument (..),
    textMetrics,
    textSimilarity,
    searchCorpus,
    splitText,
    grepTextLines,
  )
where

import Codec.Compression.Zlib (compress)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (foldl', sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Text.Regex.TDFA (CompOption (..), defaultCompOpt, defaultExecOpt, matchTest)
import Text.Regex.TDFA.String (compile)

data TokenizeMode = TokenizeChar | TokenizeWord | TokenizeLine
  deriving stock (Eq, Show)

data SimilarityMethod = SimilarityJaccard | SimilarityLcs
  deriving stock (Eq, Show)

data SplitOn = SplitOnParagraph | SplitOnSentence | SplitOnChar
  deriving stock (Eq, Show)

data TextMetrics = TextMetrics
  { tmChars :: !Int,
    tmTokens :: !Int,
    tmLines :: !Int,
    tmParagraphs :: !Int,
    tmShannonEntropy :: !Double,
    tmCompressionRatio :: !Double
  }
  deriving stock (Eq, Show)

data SimilarityResult = SimilarityResult
  { srScore :: !Double,
    srMethod :: !Text,
    srLeftTokens :: !Int,
    srRightTokens :: !Int
  }
  deriving stock (Eq, Show)

data CorpusDocument = CorpusDocument
  { cdId :: !Text,
    cdText :: !Text
  }
  deriving stock (Eq, Show)

data CorpusCluster = CorpusCluster
  { ccMembers :: ![Text],
    ccScore :: !Double,
    ccSpan :: !Text
  }
  deriving stock (Eq, Show)

textMetrics :: Text -> TokenizeMode -> TextMetrics
textMetrics text mode =
  TextMetrics
    { tmChars = T.length text,
      tmTokens = length tokens,
      tmLines = length (T.lines text),
      tmParagraphs = paragraphCount text,
      tmShannonEntropy = shannonEntropy tokens,
      tmCompressionRatio = compressionRatio text
    }
  where
    tokens = tokenize mode text

textSimilarity :: Text -> Text -> SimilarityMethod -> Int -> SimilarityResult
textSimilarity left right method ngram =
  SimilarityResult
    { srScore = score,
      srMethod = methodText method,
      srLeftTokens = tokenCount left method ngram,
      srRightTokens = tokenCount right method ngram
    }
  where
    score = case method of
      SimilarityJaccard -> jaccardScore left right ngram
      SimilarityLcs -> lcsRatio left right

splitText :: Text -> Int -> Int -> SplitOn -> [Text]
splitText text maxChars overlap mode =
  case mode of
    SplitOnParagraph -> filter (not . T.null) (map T.strip (T.splitOn "\n\n" (T.strip text)))
    SplitOnSentence -> splitSentences text
    SplitOnChar -> splitChars text maxChars overlap

grepTextLines :: Text -> Text -> Either Text [Text]
grepTextLines rawPattern text =
  let (pattern, opts) = patternOpts rawPattern
   in case compile opts defaultExecOpt (T.unpack pattern) of
        Left err -> Left (T.pack err)
        Right regex ->
          let lineMatches =
                filter (\line -> matchTest regex (T.unpack line)) (T.lines text)
           in Right lineMatches

patternOpts :: Text -> (Text, CompOption)
patternOpts pat =
  case T.stripPrefix "(?i)" pat of
    Just rest -> (rest, defaultCompOpt)
    Nothing -> (pat, defaultCompOpt)

splitSentences :: Text -> [Text]
splitSentences text =
  filter (not . T.null . T.strip) (map T.strip (consume (T.unpack text) [] []))
  where
    punct :: [Char]
    punct = ['.', '!', '?']

    space :: [Char]
    space = [' ', '\n', '\t']

    consume [] acc cur =
      let sent = T.pack (reverse cur)
       in if not (null acc)
            then reverse acc
            else
              if T.null (T.strip sent)
                then []
                else [T.strip sent]
    consume (c : cs) acc cur
      | c `elem` punct && (null cs || head cs `elem` space) =
          let sent = T.pack (reverse (c : cur))
              rest = dropWhile (`elem` space) cs
           in if T.null (T.strip sent)
                then consume rest acc []
                else consume rest (sent : acc) []
      | otherwise = consume cs acc (c : cur)

splitChars :: Text -> Int -> Int -> [Text]
splitChars text maxChars overlap
  | maxChars <= 0 = [text]
  | T.null text = []
  | otherwise = go 0
  where
    len = T.length text
    step = max 1 (maxChars - max 0 overlap)
    go start
      | start >= len = []
      | otherwise =
          let end = min len (start + maxChars)
              chunk = T.take (end - start) (T.drop start text)
           in chunk : go (start + step)

searchCorpus :: [CorpusDocument] -> SimilarityMethod -> Double -> Int -> [CorpusCluster]
searchCorpus docs method threshold ngram =
  map buildCluster $
    filter ((>= 2) . length) $
      connectedComponents (length docs) edges
  where
    edges =
      [ (i, j)
        | i <- [0 .. length docs - 1],
          j <- [i + 1 .. length docs - 1],
          pairScore (docs !! i) (docs !! j) >= threshold
      ]
    buildCluster memberIdxs =
      let members = map (cdId . (docs !!)) memberIdxs
          pairs =
            [ (docs !! i, docs !! j)
              | i <- memberIdxs,
                j <- memberIdxs,
                i < j
            ]
          scores = [pairScore a b | (a, b) <- pairs]
          spans = [pairSpan a b | (a, b) <- pairs]
       in CorpusCluster
            { ccMembers = members,
              ccScore =
                if null scores
                  then 0
                  else sum scores / fromIntegral (length scores),
              ccSpan =
                if null spans
                  then ""
                  else maximumByLength spans
            }
    pairScore a b =
      srScore (textSimilarity (cdText a) (cdText b) method ngram)
    pairSpan a b =
      longestCommonSubstring (cdText a) (cdText b)

paragraphCount :: Text -> Int
paragraphCount text =
  length (filter (not . T.null) (T.splitOn "\n\n" (T.strip text)))

tokenize :: TokenizeMode -> Text -> [Text]
tokenize = \case
  TokenizeChar -> map T.singleton . T.unpack
  TokenizeWord -> T.words
  TokenizeLine -> T.lines

shannonEntropy :: [Text] -> Double
shannonEntropy [] = 0
shannonEntropy tokens =
  let total = fromIntegral (length tokens)
      counts = Map.fromListWith ((+) :: Int -> Int -> Int) [(t, 1) | t <- tokens]
   in negate (sum [p * logBase 2 p | c <- Map.elems counts, let p = fromIntegral c / total])

compressionRatio :: Text -> Double
compressionRatio text
  | T.null text = 1
  | otherwise =
      let raw = TE.encodeUtf8 text
          compressed = BSL.toStrict (compress (BSL.fromStrict raw))
       in fromIntegral (T.length text) / fromIntegral (max 1 (BS.length compressed))

jaccardScore :: Text -> Text -> Int -> Double
jaccardScore left right ngram
  | ngram <= 1 =
      jaccardSet (wordUnigrams left) (wordUnigrams right)
  | otherwise =
      jaccardSet (charNgrams ngram left) (charNgrams ngram right)

jaccardSet :: Set.Set Text -> Set.Set Text -> Double
jaccardSet a b
  | Set.null a && Set.null b = 1
  | otherwise =
      let inter = Set.size (Set.intersection a b)
          union = Set.size (Set.union a b)
       in if union == 0 then 0 else fromIntegral inter / fromIntegral union

wordUnigrams :: Text -> Set.Set Text
wordUnigrams = Set.fromList . T.words

charNgrams :: Int -> Text -> Set.Set Text
charNgrams n text
  | T.length text < n =
      if T.null text then Set.empty else Set.singleton text
  | otherwise =
      Set.fromList
        [ T.take n (T.drop i text)
          | i <- [0 .. T.length text - n]
        ]

lcsRatio :: Text -> Text -> Double
lcsRatio left right =
  let len = lcsLength left right
      denom = max (T.length left) (T.length right)
   in if denom == 0 then 1 else fromIntegral len / fromIntegral denom

lcsLength :: Text -> Text -> Int
lcsLength left right =
  let ls = T.unpack left
      rs = T.unpack right
      m = length ls
      n = length rs
      go i j prevRow
        | i > m = prevRow !! n
        | otherwise =
            let row =
                  0 : [ let above = prevRow !! (k - 1)
                            leftVal = row !! (k - 1)
                         in if ls !! (i - 1) == rs !! (k - 1)
                              then above + 1
                              else max leftVal above
                         | k <- [1 .. n]
                       ]
             in go (i + 1) j row
   in go (1 :: Int) (0 :: Integer) (replicate (n + 1) 0)

longestCommonSubstring :: Text -> Text -> Text
longestCommonSubstring left right =
  let a = T.unpack left
      b = T.unpack right
      n = length b
      buildRow i prevRow =
        foldl'
          ( \(_, row, rowBestLen, rowBestEnd) j ->
              let cur =
                    if a !! (i - 1) == b !! (j - 1)
                      then
                        if i == 1 || j == 1
                          then 1
                          else prevRow !! (j - 1) + 1
                      else 0
                  (nBestLen, nBestEnd)
                    | cur > rowBestLen = (cur, i)
                    | otherwise = (rowBestLen, rowBestEnd)
               in (cur, row ++ [cur], nBestLen, nBestEnd)
          )
          (0, [0], 0, 0)
          [1 .. n]
      (_, bestLen, bestEnd) =
        foldl'
          ( \(prevRow, accBestLen, accBestEnd) i ->
              let (_, row, rowBestLen, rowBestEnd) = buildRow i prevRow
                  (nBestLen, nBestEnd)
                    | rowBestLen > accBestLen = (rowBestLen, rowBestEnd)
                    | otherwise = (accBestLen, accBestEnd)
               in (row, nBestLen, nBestEnd)
          )
          (replicate (n + 1) 0, 0, 0)
          [1 .. length a]
   in if bestLen == 0
        then ""
        else T.pack (take bestLen (drop (bestEnd - bestLen) a))

tokenCount :: Text -> SimilarityMethod -> Int -> Int
tokenCount text method ngram = case method of
  SimilarityLcs -> T.length text
  SimilarityJaccard
    | ngram <= 1 -> length (T.words text)
    | otherwise -> Set.size (charNgrams ngram text)

methodText :: SimilarityMethod -> Text
methodText = \case
  SimilarityJaccard -> "jaccard"
  SimilarityLcs -> "lcs"

maximumByLength :: [Text] -> Text
maximumByLength = foldl' (\a b -> if T.length b > T.length a then b else a) ""

connectedComponents :: Int -> [(Int, Int)] -> [[Int]]
connectedComponents size pairs =
  let roots = foldl' union [0 .. size - 1] pairs
      groups = Map.fromListWith (++) [(find roots i, [i]) | i <- [0 .. size - 1]]
   in map (sortOn id) (filter ((>= 2) . length) (Map.elems groups))
  where
    find rs i
      | rs !! i == i = i
      | otherwise = find rs (rs !! i)
    union rs (a, b) =
      let ra = find rs a
          rb = find rs b
       in if ra == rb then rs else setAt rs ra rb
    setAt xs i v = take i xs ++ [v] ++ drop (i + 1) xs
