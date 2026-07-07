-- | The engine-provided @builtin/*@ tools (spec §6) and the 'Callee'
-- abstraction the checker uses to check step calls uniformly against both
-- builtins and user-defined workflows/tools.
--
-- Built-in tools are not files and have no source AST; their fingerprints
-- (spec §8.1) are fixed and derived from the engine version via
-- 'builtinIdentity'.
module Hwfi.Check.Builtins
  ( Callee (..),
    builtinCallees,
    lookupBuiltin,
    isBuiltin,
    introspectQName,
    engineVersion,
    builtinIdentity,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Type (Type (..), renderType)

-- | Everything the checker needs to know about a call target: its declared
-- input and output records. This is derived from a builtin's fixed signature
-- or from a user declaration's resolved 'Hwfi.Ast.Workflow.Signature'.
data Callee = Callee
  { calleeInputs :: [(Ident, Type)],
    calleeOutputs :: [(Ident, Type)]
  }
  deriving stock (Eq, Show)

-- | The @builtin/introspect@ qname. Calling it forces the enclosing step to
-- be non-cacheable (§8.1).
introspectQName :: QName
introspectQName = qnameFromText "builtin/introspect"

-- | The engine version string that seeds builtin fingerprints (§8.1). Bumping
-- this invalidates every cached step that (transitively) calls a builtin.
engineVersion :: Text
engineVersion = "hwfi-builtins/1"

-- | The signatures of all built-in tools (§6).
builtinCallees :: Map QName Callee
builtinCallees =
  Map.fromList
    [ builtin "builtin/read-file" [("path", TyFileRef)] [("text", TyString)],
      builtin "builtin/write-file" [("path", TyFileRef), ("text", TyString)] [],
      builtin "builtin/list-dir" [("path", TyFileRef)] [("entries", TyList TyString)],
      builtin
        "builtin/llm-generate"
        [("system", TyString), ("prompt", TyString), ("model", TyString)]
        [("text", TyString)],
      builtin
        "builtin/llm-chat"
        [ ("system", TyString),
          ("messages", TyList (TyRecord [("role", TyString), ("content", TyString)])),
          ("model", TyString)
        ]
        [("text", TyString)],
      builtin
        "builtin/llm-gen-object"
        [("system", TyString), ("prompt", TyString), ("schema", TyJson), ("model", TyString)]
        [("value", TyJson)],
      builtin "builtin/introspect" [] [("data", TyJson)]
    ]
  where
    builtin name ins outs = (qnameFromText name, Callee ins outs)

-- | Look up a builtin by qname.
lookupBuiltin :: QName -> Maybe Callee
lookupBuiltin q = Map.lookup q builtinCallees

-- | Whether a qname names a builtin tool.
isBuiltin :: QName -> Bool
isBuiltin q = Map.member q builtinCallees

-- | The canonical identity string of a builtin, hashed to obtain its fixed
-- fingerprint (§8.1). Includes the engine version and the full signature so
-- that a change to a builtin's shape in a new engine version invalidates
-- dependent cached steps.
builtinIdentity :: QName -> Maybe Text
builtinIdentity q = renderCallee <$> lookupBuiltin q
  where
    renderCallee (Callee ins outs) =
      engineVersion
        <> "\n"
        <> renderQName q
        <> "\nin:"
        <> renderFields ins
        <> "\nout:"
        <> renderFields outs
    renderFields fs = mconcat ["(" <> n <> ":" <> renderType t <> ")" | (n, t) <- fs]
