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
    execQName,
    llmAgentQName,
    llmAgentObjectQName,
    evalWorkflowQName,
    listRunsQName,
    readRunTraceQName,
    traceSliceQName,
    logQName,
    jsonGetQName,
    concatQName,
    discoverSkillsQName,
    loadSkillQName,
    isAgentBuiltin,
    isOneShotLlmBuiltin,
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

-- | The @builtin/exec@ qname (§6.3). Calls are rejected at @hwfi check@ unless
-- an @exec@ policy allowlists the requested program (§7.5, A24).
execQName :: QName
execQName = qnameFromText "builtin/exec"

-- | The @builtin/llm-agent@ qname (§6.1): the free-text agentic loop.
llmAgentQName :: QName
llmAgentQName = qnameFromText "builtin/llm-agent"

-- | The @builtin/llm-agent-object@ qname (§6.1.3): the typed-output variant.
llmAgentObjectQName :: QName
llmAgentObjectQName = qnameFromText "builtin/llm-agent-object"

-- | The @builtin/eval-workflow@ qname (§6.4): parse, type-check, and run
-- dynamically synthesized workflow source.
evalWorkflowQName :: QName
evalWorkflowQName = qnameFromText "builtin/eval-workflow"

-- | The @builtin/list-runs@ qname (§6.5): list prior runs under the workspace.
listRunsQName :: QName
listRunsQName = qnameFromText "builtin/list-runs"

-- | The @builtin/read-run-trace@ qname (§6.5): read a prior run's trace.
readRunTraceQName :: QName
readRunTraceQName = qnameFromText "builtin/read-run-trace"

-- | The @builtin/trace-slice@ qname (§6.6): extract events for one logical step.
traceSliceQName :: QName
traceSliceQName = qnameFromText "builtin/trace-slice"

-- | The @builtin/log@ qname (§13.1.5): structured workflow logging.
logQName :: QName
logQName = qnameFromText "builtin/log"

-- | The @builtin/json-get@ qname (§13.1.2): JSON path lookup.
jsonGetQName :: QName
jsonGetQName = qnameFromText "builtin/json-get"

-- | The @builtin/concat@ qname (§13.1.2): string concatenation.
concatQName :: QName
concatQName = qnameFromText "builtin/concat"

-- | Skill catalog discovery (§6.7.1).
discoverSkillsQName :: QName
discoverSkillsQName = qnameFromText "builtin/discover-skills"

-- | Skill loading (§6.7.2).
loadSkillQName :: QName
loadSkillQName = qnameFromText "builtin/load-skill"

-- | Whether a qname is one of the agentic tool-use builtins (§6.1). These need
-- bespoke argument checking (the @tools@ argument is a heterogeneous list of
-- refs, §5.6.9) and are non-cacheable black boxes (§8.1), so they are handled
-- specially rather than through the generic callee path.
isAgentBuiltin :: QName -> Bool
isAgentBuiltin q = q == llmAgentQName || q == llmAgentObjectQName

-- | Whether a qname is a cacheable one-shot LLM builtin (§8.1). These need the
-- resolved model-catalog entry folded into the step-key, not just the model
-- name in @resolved-args@.
isOneShotLlmBuiltin :: QName -> Bool
isOneShotLlmBuiltin q =
  q == llmGenerateQName || q == llmChatQName || q == llmGenObjectQName

llmGenerateQName :: QName
llmGenerateQName = qnameFromText "builtin/llm-generate"

llmChatQName :: QName
llmChatQName = qnameFromText "builtin/llm-chat"

llmGenObjectQName :: QName
llmGenObjectQName = qnameFromText "builtin/llm-gen-object"

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
      -- Read/navigation builtins (§6.2).
      builtin
        "builtin/read-file-slice"
        [("path", TyFileRef), ("offset", TyInt), ("limit", TyInt)]
        [("text", TyString), ("next_offset", TyInt), ("eof", TyBool)],
      builtin
        "builtin/find-files"
        [("path", TyFileRef), ("glob", TyString)]
        [("paths", TyList TyString)],
      builtin
        "builtin/grep"
        [("pattern", TyString), ("path", TyFileRef)]
        [("matches", TyList (TyRecord [("file", TyString), ("line", TyInt), ("text", TyString)]))],
      -- Mutation builtins (§6.2).
      builtin
        "builtin/edit-file"
        [("path", TyFileRef), ("find", TyString), ("replace", TyString), ("expect", TyInt)]
        [("replacements", TyInt)],
      builtin "builtin/move-file" [("from", TyFileRef), ("to", TyFileRef)] [],
      builtin "builtin/copy-file" [("from", TyFileRef), ("to", TyFileRef)] [],
      builtin "builtin/remove-file" [("path", TyFileRef)] [],
      builtin "builtin/make-dir" [("path", TyFileRef)] [],
      builtin "builtin/remove-dir" [("path", TyFileRef)] [],
      -- Command execution (§6.3, §7.5).
      builtin
        "builtin/exec"
        [("program", TyString), ("args", TyList TyString), ("stdin", TyString), ("timeout_ms", TyInt)]
        [ ("exit_code", TyInt),
          ("stdout", TyString),
          ("stderr", TyString),
          ("timed_out", TyBool)
        ],
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
      builtin "builtin/introspect" [] [("data", TyJson)],
      -- The @tools@ input is a heterogeneous list of ToolRef/WorkflowRef values
      -- with no v1 union type; it is represented here as @List<Json>@ purely so
      -- the builtin has a fixed identity\/fingerprint (§8.1). Argument checking
      -- is bespoke (§5.6.9), never the generic 'checkArgs' path.
      builtin
        "builtin/llm-agent"
        [ ("system", TyString),
          ("prompt", TyString),
          ("model", TyString),
          ("tools", TyList TyJson),
          ("max_rounds", TyInt)
        ]
        [("text", TyString), ("rounds", TyInt)],
      builtin
        "builtin/llm-agent-object"
        [ ("system", TyString),
          ("prompt", TyString),
          ("model", TyString),
          ("tools", TyList TyJson),
          ("schema", TyJson),
          ("max_rounds", TyInt)
        ]
        [("value", TyJson), ("rounds", TyInt)],
      builtin
        "builtin/eval-workflow"
        [("source", TyString), ("inputs", TyJson)]
        [("ok", TyBool), ("outputs", TyJson), ("errors", TyList TyString)],
      builtin
        "builtin/list-runs"
        [("limit", TyInt)]
        [ ( "runs",
            TyList
              ( TyRecord
                  [ ("id", TyString),
                    ("started_at", TyString),
                    ("entrypoint", TyString),
                    ("status", TyString)
                  ]
              )
          )
        ],
      builtin
        "builtin/read-run-trace"
        [("run_id", TyString)]
        [("ok", TyBool), ("events", TyList TyTraceEvent), ("error", TyString)],
      builtin
        "builtin/trace-slice"
        [ ("run_id", TyString),
          ("qname", TyString),
          ("step_id", TyString),
          ("include_nested", TyBool)
        ]
        [("ok", TyBool), ("events", TyList TyTraceEvent), ("error", TyString)],
      builtin
        "builtin/json-get"
        [("json", TyJson), ("path", TyString)]
        [("ok", TyBool), ("value", TyJson), ("error", TyString)],
      builtin "builtin/concat" [("parts", TyList TyString)] [("text", TyString)],
      builtin
        "builtin/log"
        [("message", TyString), ("fields", TyJson)]
        [("logged", TyBool)],
      builtin
        "builtin/discover-skills"
        [("query", TyString), ("kinds", TyList TyString), ("limit", TyInt)]
        [ ("ok", TyBool),
          ( "skills",
            TyList
              ( TyRecord
                  [ ("id", TyString),
                    ("kind", TyString),
                    ("summary", TyString),
                    ("tags", TyList TyString),
                    ("checked", TyBool),
                    ("agent_eligible", TyBool)
                  ]
              )
          ),
          ("error", TyString)
        ],
      builtin
        "builtin/load-skill"
        [("id", TyString)]
        [ ("ok", TyBool),
          ("kind", TyString),
          ("loaded", TyBool),
          ("content", TyString),
          ("error", TyString)
        ]
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
