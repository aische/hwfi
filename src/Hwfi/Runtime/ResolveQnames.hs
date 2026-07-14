-- | @builtin/resolve-qnames-in-text@ and @builtin/list-concat@ (§13.1.8 Tier 3).
module Hwfi.Runtime.ResolveQnames
  ( runResolveQnamesInText,
    runListConcat,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Text.QnameResolve (QnameMention (..), renderMentionKind, resolveQnamesInText)

runResolveQnamesInText :: Map Ident RValue -> IO (Either RuntimeError RValue)
runResolveQnamesInText args =
  case
    ( argText args "text",
      argTextList args "catalog",
      argBool args "include_builtins",
      argBool args "unresolved_only",
      argBool args "exclude_step_fences"
    )
    of
      (Left e, _, _, _, _) -> pure (Left e)
      (_, Left e, _, _, _) -> pure (Left e)
      (_, _, Left e, _, _) -> pure (Left e)
      (_, _, _, Left e, _) -> pure (Left e)
      (_, _, _, _, Left e) -> pure (Left e)
      (Right text, Right catalog, Right includeBuiltins, Right unresolvedOnly, Right excludeStepFences) ->
        pure
          ( Right
              ( record
                  [ ( "mentions",
                      VList (map mentionRecord (resolveQnamesInText text catalog includeBuiltins unresolvedOnly excludeStepFences))
                    )
                  ]
              )
          )

runListConcat :: Map Ident RValue -> IO (Either RuntimeError RValue)
runListConcat args =
  case Map.lookup "lists" args of
    Nothing -> pure (Left (evalError "builtin/list-concat requires lists: List<List<_>>"))
    Just (VList outer) ->
      case traverse asList outer of
        Left e -> pure (Left e)
        Right inners ->
          pure (Right (record [("items", VList (concat inners))]))
    Just _ -> pure (Left (evalError "builtin/list-concat requires lists: List<List<_>>"))

mentionRecord :: QnameMention -> RValue
mentionRecord QnameMention {..} =
  record
    [ ("text", VString qmText),
      ("kind", VString (renderMentionKind qmKind)),
      ("qname", VString qmQname)
    ]

asList :: RValue -> Either RuntimeError [RValue]
asList (VList xs) = Right xs
asList v = Left (evalError ("list-concat element is not a list: " <> T.pack (show v)))

argText :: Map Ident RValue -> Ident -> Either RuntimeError Text
argText args name = case Map.lookup name args of
  Nothing -> Left (evalError ("builtin requires " <> name <> ": String"))
  Just (VString t) -> Right t
  Just v -> Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

argTextList :: Map Ident RValue -> Ident -> Either RuntimeError [Text]
argTextList args name = case Map.lookup name args of
  Nothing -> Left (evalError ("builtin requires " <> name <> ": List<String>"))
  Just (VList xs) -> traverse asText xs
  Just v -> Left (evalError ("argument '" <> name <> "' is not a list: " <> T.pack (show v)))
  where
    asText (VString t) = Right t
    asText v = Left (evalError ("catalog entry is not text: " <> T.pack (show v)))

argBool :: Map Ident RValue -> Ident -> Either RuntimeError Bool
argBool args name = case Map.lookup name args of
  Nothing -> Left (evalError ("builtin requires " <> name <> ": Bool"))
  Just (VBool b) -> Right b
  Just v -> Left (evalError ("argument '" <> name <> "' is not a boolean: " <> T.pack (show v)))

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList
