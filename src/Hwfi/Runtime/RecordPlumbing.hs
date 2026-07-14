-- | Record and list plumbing builtins (§13.1.2, §13.1.8 Tier 3).
module Hwfi.Runtime.RecordPlumbing
  ( runRecordFilter,
    runListUniqueBy,
    lookupRecordPath,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..), canonicalJson, valueToJson)

runRecordFilter :: Map Ident RValue -> IO (Either RuntimeError RValue)
runRecordFilter args =
  pure $
    case Map.lookup "items" args of
      Nothing -> Left (evalError "builtin/record-filter requires items: List<Record>")
      Just (VList items) ->
        case Map.lookup "where" args of
          Just whereClause ->
            case parseWhereClause whereClause of
              Left err -> Left (evalError err)
              Right conditions ->
                Right (record [("items", VList (filter (matchesWhere conditions) items))])
          _ ->
            case (argText args "field", Map.lookup "equals" args) of
              (Right field, Just wanted) ->
                Right
                  ( record
                      [ ( "items",
                          VList
                            [ item
                              | item <- items,
                                Just wanted == lookupRecordPath item field
                            ]
                        )
                      ]
                  )
              (Left _, _) -> Left (evalError "builtin/record-filter requires field: String or where: Record")
              (_, Nothing) -> Left (evalError "builtin/record-filter requires equals or where")
      Just _ -> Left (evalError "builtin/record-filter requires items: List<Record>")

runListUniqueBy :: Map Ident RValue -> IO (Either RuntimeError RValue)
runListUniqueBy args =
  pure $
    case (Map.lookup "items" args, argTextList args "fields", argInt args "limit") of
      (Nothing, _, _) -> Left (evalError "builtin/list-unique-by requires items: List<Record>")
      (Just (VList _), Left err, _) -> Left err
      (Just (VList _), _, Left err) -> Left err
      (Just (VList items), Right fieldPaths, Right limit) ->
        Right (record [("items", VList (uniqueByFields items fieldPaths limit))])
      (Just _, _, _) -> Left (evalError "builtin/list-unique-by requires items: List<Record>")

uniqueByFields :: [RValue] -> [Text] -> Int -> [RValue]
uniqueByFields items fieldPaths limit =
  go items Set.empty []
  where
    go _ _ acc | limit > 0 && length acc >= limit = reverse acc
    go [] _ acc = reverse acc
    go (item : rest) seen acc =
      case itemKeyText item fieldPaths of
        Nothing -> go rest seen acc
        Just key
          | key `Set.member` seen -> go rest seen acc
          | otherwise -> go rest (Set.insert key seen) (item : acc)

itemKeyText :: RValue -> [Text] -> Maybe Text
itemKeyText item fieldPaths =
  T.intercalate "\0" <$> traverse
      ( fmap (canonicalJson . valueToJson) . lookupRecordPath item
      )
      fieldPaths

matchesWhere :: [(Text, RValue)] -> RValue -> Bool
matchesWhere conditions item =
  all
    ( \(path, wanted) ->
        lookupRecordPath item path == Just wanted
    )
    conditions

parseWhereClause :: RValue -> Either Text [(Text, RValue)]
parseWhereClause (VRecord m) = Right (flattenWhereClause m)
parseWhereClause _ = Left "builtin/record-filter where must be a record"

flattenWhereClause :: Map Ident RValue -> [(Text, RValue)]
flattenWhereClause m = concatMap (uncurry flattenAt) (Map.toList m)
  where
    flattenAt prefix v@(VRecord inner)
      | Map.null inner = [(prefix, v)]
      | otherwise =
          concatMap (\(k, nested) -> flattenAt (prefix <> "." <> k) nested) (Map.toList inner)
    flattenAt prefix v = [(prefix, v)]

lookupRecordPath :: RValue -> Text -> Maybe RValue
lookupRecordPath value path =
  case T.splitOn "." (T.strip path) of
    [] -> Nothing
    [segment] -> lookupSegment value segment
    segment : rest ->
      case lookupSegment value segment of
        Nothing -> Nothing
        Just nested -> lookupRecordPath nested (T.intercalate "." rest)

lookupSegment :: RValue -> Text -> Maybe RValue
lookupSegment (VRecord m) segment = Map.lookup segment m
lookupSegment _ _ = Nothing

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList

argText :: Map Ident RValue -> Ident -> Either RuntimeError Text
argText args name = case Map.lookup name args of
  Just (VString t) -> Right t
  Nothing -> Left (evalError ("builtin requires " <> name <> ": String"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

argTextList :: Map Ident RValue -> Ident -> Either RuntimeError [Text]
argTextList args name = case Map.lookup name args of
  Nothing -> Left (evalError ("builtin requires " <> name <> ": List<String>"))
  Just (VList xs) -> traverse asText xs
  Just v -> Left (evalError ("argument '" <> name <> "' is not a list: " <> T.pack (show v)))
  where
    asText (VString t) = Right t
    asText v = Left (evalError ("fields entry is not text: " <> T.pack (show v)))

argInt :: Map Ident RValue -> Ident -> Either RuntimeError Int
argInt args name = case Map.lookup name args of
  Just (VInt n) -> Right (fromIntegral n)
  Nothing -> Left (evalError ("builtin requires " <> name <> ": Int"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not an integer: " <> T.pack (show v)))
