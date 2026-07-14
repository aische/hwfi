-- | Runtime wrappers for Tier 2 text corpus builtins (§13.1.8).
module Hwfi.Runtime.TextCorpus
  ( runTextMetrics,
    runTextSimilarity,
    runTextSearchCorpus,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Text.Corpus
  ( CorpusCluster (..),
    CorpusDocument (..),
    SimilarityMethod (..),
    SimilarityResult (..),
    TextMetrics (..),
    TokenizeMode (..),
    searchCorpus,
    textMetrics,
    textSimilarity,
  )

runTextMetrics :: Map Ident RValue -> IO (Either RuntimeError RValue)
runTextMetrics args =
  case (argText args "text", argTokenize args "tokenize") of
    (Left e, _) -> pure (Left e)
    (_, Left e) -> pure (Left e)
    (Right text, Right mode) ->
      let TextMetrics {..} = textMetrics text mode
       in pure
            ( Right
                ( record
                    [ ("chars", VInt (fromIntegral tmChars)),
                      ("tokens", VInt (fromIntegral tmTokens)),
                      ("lines", VInt (fromIntegral tmLines)),
                      ("paragraphs", VInt (fromIntegral tmParagraphs)),
                      ("shannon_entropy", VDouble tmShannonEntropy),
                      ("compression_ratio", VDouble tmCompressionRatio)
                    ]
                )
            )

runTextSimilarity :: Map Ident RValue -> IO (Either RuntimeError RValue)
runTextSimilarity args =
  case
    ( argText args "left",
      argText args "right",
      argMethod args "method",
      argInt args "ngram"
    )
    of
      (Left e, _, _, _) -> pure (Left e)
      (_, Left e, _, _) -> pure (Left e)
      (_, _, Left e, _) -> pure (Left e)
      (_, _, _, Left e) -> pure (Left e)
      (Right left, Right right, Right method, Right ngram) ->
        let SimilarityResult {..} = textSimilarity left right method ngram
         in pure
              ( Right
                  ( record
                      [ ("score", VDouble srScore),
                        ("method", VString srMethod),
                        ("left_tokens", VInt (fromIntegral srLeftTokens)),
                        ("right_tokens", VInt (fromIntegral srRightTokens))
                      ]
                  )
              )

runTextSearchCorpus :: Map Ident RValue -> IO (Either RuntimeError RValue)
runTextSearchCorpus args =
  case
    ( argDocuments args "documents",
      argMethod args "method",
      argDouble args "threshold",
      argInt args "ngram"
    )
    of
      (Left e, _, _, _) -> pure (Left e)
      (_, Left e, _, _) -> pure (Left e)
      (_, _, Left e, _) -> pure (Left e)
      (_, _, _, Left e) -> pure (Left e)
      (Right docs, Right method, Right threshold, Right ngram) ->
        let clusters = searchCorpus docs method threshold ngram
         in pure (Right (record [("clusters", VList (map clusterValue clusters))]))

clusterValue :: CorpusCluster -> RValue
clusterValue CorpusCluster {..} =
  record
    [ ("members", VList (map VString ccMembers)),
      ("score", VDouble ccScore),
      ("span", VString ccSpan)
    ]

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList

argText :: Map Ident RValue -> Ident -> Either RuntimeError Text
argText args name = case Map.lookup name args of
  Just (VString t) -> Right t
  Nothing -> Left (evalError ("builtin requires " <> name <> ": String"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

argInt :: Map Ident RValue -> Ident -> Either RuntimeError Int
argInt args name = case Map.lookup name args of
  Just (VInt n) -> Right (fromIntegral n)
  Nothing -> Left (evalError ("builtin requires " <> name <> ": Int"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not an integer: " <> T.pack (show v)))

argDouble :: Map Ident RValue -> Ident -> Either RuntimeError Double
argDouble args name = case Map.lookup name args of
  Just (VDouble d) -> Right d
  Just (VInt n) -> Right (fromIntegral n)
  Nothing -> Left (evalError ("builtin requires " <> name <> ": Double"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not a number: " <> T.pack (show v)))

argTokenize :: Map Ident RValue -> Ident -> Either RuntimeError TokenizeMode
argTokenize args name = case Map.lookup name args of
  Just (VString "char") -> Right TokenizeChar
  Just (VString "word") -> Right TokenizeWord
  Just (VString "line") -> Right TokenizeLine
  Nothing -> Left (evalError ("builtin requires " <> name <> ": String"))
  Just (VString t) ->
    Left (evalError ("argument '" <> name <> "' must be char, word, or line; got: " <> t))
  Just v -> Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

argMethod :: Map Ident RValue -> Ident -> Either RuntimeError SimilarityMethod
argMethod args name = case Map.lookup name args of
  Just (VString "jaccard") -> Right SimilarityJaccard
  Just (VString "lcs") -> Right SimilarityLcs
  Nothing -> Left (evalError ("builtin requires " <> name <> ": String"))
  Just (VString t) ->
    Left (evalError ("argument '" <> name <> "' must be jaccard or lcs; got: " <> t))
  Just v -> Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

argDocuments :: Map Ident RValue -> Ident -> Either RuntimeError [CorpusDocument]
argDocuments args name = case Map.lookup name args of
  Nothing -> Left (evalError ("builtin requires " <> name <> ": List"))
  Just (VList xs) -> traverse documentValue xs
  Just v -> Left (evalError ("argument '" <> name <> "' is not a list: " <> T.pack (show v)))

documentValue :: RValue -> Either RuntimeError CorpusDocument
documentValue (VRecord m) = do
  idText <- fieldText m "id"
  body <- fieldText m "text"
  pure (CorpusDocument idText body)
documentValue v = Left (evalError ("document entry is not a record: " <> T.pack (show v)))

fieldText :: Map Ident RValue -> Ident -> Either RuntimeError Text
fieldText m name = case Map.lookup name m of
  Just (VString t) -> Right t
  Nothing -> Left (evalError ("document missing field '" <> name <> "'"))
  Just v -> Left (evalError ("document field '" <> name <> "' is not text: " <> T.pack (show v)))
