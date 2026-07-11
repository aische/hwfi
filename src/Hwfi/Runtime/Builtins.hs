{-# OPTIONS_GHC -Wno-type-defaults #-}

-- | The engine-provided @builtin/*@ tools (spec §6, tasks 4.4, 4.5, 4.7).
--
-- Each builtin takes the already-resolved argument map and runs in IO,
-- emitting the appropriate trace events (@file-io@, @llm-call@) as it goes.
-- File I/O goes through the sandboxed 'Workspace'; the LLM tools resolve their
-- @model@ argument against the 'ModelStore' (unknown names fail per A11) and
-- call into @llm-simple@'s generation entry points. @builtin/introspect@
-- returns the runtime dump assembled by the executor.
module Hwfi.Runtime.Builtins
  ( BuiltinEnv (..),
    runBuiltin,
  )
where

import Control.Monad (void)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Functor ((<&>))
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read (decimal)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Compat
  ( ChatResponse (..),
    GenRequest (..),
    GenerateErrorResult (..),
    ModelWithFallbacks (..),
    Turn (..),
    Usage (..),
    genObjectUntyped,
    generateTextWithFallbacks,
    llmHooks,
    noHooks,
  )
import Hwfi.Project.Manifest (ExecPolicy)
import Hwfi.Runtime.Error (RuntimeError, StepRef (..), evalError, llmError, sandboxError)
import Hwfi.Runtime.EvalWorkflow (EvalWorkflowSeam (..), runEvalWorkflow)
import Hwfi.Runtime.Exec (ExecArgs (..), ExecOutcome (..), runExec)
import Hwfi.Runtime.Gateways (ModelStore, lookupModel, primaryModel)
import Hwfi.Runtime.RunStore (RunSummary (..), listRuns, readRunTrace)
import Hwfi.Runtime.Skills (discoverSkillsResult, loadSkillScripted)
import Hwfi.Runtime.Trace (EventBody (..), FileOp (..), Tracer, emit, eventToJson, sliceTrace, snapshotEvents)
import Hwfi.Runtime.Usage (UsageSeam, checkBudgetSeam, recordBilledCall)
import Hwfi.Runtime.Value (RValue (..), canonicalJson, valueToJson)
import Hwfi.Runtime.Workspace
  ( Workspace,
    copyFile,
    editFile,
    findFiles,
    grepFiles,
    listDir,
    makeDir,
    moveFile,
    readFileSlice,
    readTextFile,
    removeDir,
    removeFile,
    workspaceRoot,
    writeTextFile,
  )
import Hwfi.SkillCatalog (SkillCatalog)
import Hwfi.SkillCatalog qualified as Cat
import LLM (defaultDebugHooks)

-- | Everything a builtin needs from the surrounding run.
data BuiltinEnv = BuiltinEnv
  { beWorkspace :: Workspace,
    beModels :: ModelStore,
    beTracer :: Tracer,
    beStep :: StepRef,
    -- | The opt-in @exec@ policy (§7.5). 'Nothing' disables @builtin/exec@.
    beExecPolicy :: Maybe ExecPolicy,
    -- | Run-scoped usage accounting and optional budget (§8.4).
    beUsage :: UsageSeam,
    -- | Produce the @builtin/introspect@ dump for the current step (§6). Built
    -- by the executor because it needs the live bindings and trace.
    beIntrospect :: IO Value,
    -- | Dynamic workflow evaluation seam (§6.4). 'Nothing' outside the executor.
    beEvalWorkflow :: Maybe EvalWorkflowSeam,
    -- | The current logical run id (§6.5).
    beRunId :: Text,
    -- | Checked-project skill catalog (§6.7).
    beSkillCatalog :: SkillCatalog
  }

-- | Dispatch a builtin call. The caller guarantees @q@ is a builtin qname.
runBuiltin :: BuiltinEnv -> QName -> Map Ident RValue -> IO (Either RuntimeError RValue)
runBuiltin env q args = case renderQName q of
  "builtin/read-file" -> readFileTool env args
  "builtin/write-file" -> writeFileTool env args
  "builtin/list-dir" -> listDirTool env args
  "builtin/read-file-slice" -> readFileSliceTool env args
  "builtin/find-files" -> findFilesTool env args
  "builtin/grep" -> grepTool env args
  "builtin/edit-file" -> editFileTool env args
  "builtin/move-file" -> moveFileTool env args
  "builtin/copy-file" -> copyFileTool env args
  "builtin/remove-file" -> removeFileTool env args
  "builtin/make-dir" -> makeDirTool env args
  "builtin/remove-dir" -> removeDirTool env args
  "builtin/exec" -> execTool env args
  "builtin/llm-generate" -> llmGenerateTool env args
  "builtin/llm-chat" -> llmChatTool env args
  "builtin/llm-gen-object" -> llmGenObjectTool env args
  "builtin/introspect" -> introspectTool env
  "builtin/eval-workflow" -> evalWorkflowTool env args
  "builtin/list-runs" -> listRunsTool env args
  "builtin/read-run-trace" -> readRunTraceTool env args
  "builtin/trace-slice" -> traceSliceTool env args
  "builtin/json-get" -> jsonGetTool args
  "builtin/json-values" -> jsonValuesTool args
  "builtin/concat" -> concatTool args
  "builtin/log" -> logTool env args
  "builtin/discover-skills" -> discoverSkillsTool env args
  "builtin/load-skill" -> loadSkillTool env args
  other -> pure (Left (evalError ("unknown builtin '" <> other <> "'")))

-- File I/O -------------------------------------------------------------------

readFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
readFileTool env args = orFail (argText args "path") $ \path -> do
  result <- readTextFile (beWorkspace env) path
  case result of
    Left e -> pure (Left e)
    Right (text, bytes) -> do
      emitFileIo env OpRead path bytes
      pure (Right (record [("text", VString text)]))

writeFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
writeFileTool env args =
  orFail ((,) <$> argText args "path" <*> argText args "text") $ \(path, text) -> do
    result <- writeTextFile (beWorkspace env) path text
    case result of
      Left e -> pure (Left e)
      Right bytes -> do
        emitFileIo env OpWrite path bytes
        pure (Right (record []))

listDirTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
listDirTool env args = orFail (argText args "path") $ \path -> do
  result <- listDir (beWorkspace env) path
  case result of
    Left e -> pure (Left e)
    Right entries -> do
      emitFileIo env OpList path 0
      pure (Right (record [("entries", VList (map VString entries))]))

-- Navigation (§6.2) ----------------------------------------------------------

readFileSliceTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
readFileSliceTool env args =
  orFail ((,,) <$> argText args "path" <*> argInt args "offset" <*> argInt args "limit") $
    \(path, offset, limit) -> do
      result <- readFileSlice (beWorkspace env) path offset limit
      case result of
        Left e -> pure (Left e)
        Right (text, next, eof, bytes) -> do
          emitFileIo env OpReadSlice path bytes
          pure
            ( Right
                ( record
                    [ ("text", VString text),
                      ("next_offset", VInt (fromIntegral next)),
                      ("eof", VBool eof)
                    ]
                )
            )

findFilesTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
findFilesTool env args =
  orFail ((,) <$> argText args "path" <*> argText args "glob") $ \(path, glob) -> do
    result <- findFiles (beWorkspace env) path glob
    case result of
      Left e -> pure (Left e)
      Right paths -> do
        emitFileIo env OpFind path 0
        pure (Right (record [("paths", VList (map VString paths))]))

grepTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
grepTool env args =
  orFail ((,) <$> argText args "pattern" <*> argText args "path") $ \(pattern, path) -> do
    result <- grepFiles (beWorkspace env) pattern path
    case result of
      Left e -> pure (Left e)
      Right matches -> do
        emitFileIo env OpGrep path 0
        pure (Right (record [("matches", VList (map matchRecord matches))]))
  where
    matchRecord (file, line, text) =
      record [("file", VString file), ("line", VInt (fromIntegral line)), ("text", VString text)]

-- Mutation (§6.2) ------------------------------------------------------------

editFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
editFileTool env args =
  orFail
    ( (,,,)
        <$> argText args "path"
        <*> argText args "find"
        <*> argText args "replace"
        <*> argInt args "expect"
    )
    $ \(path, find_, replace_, expect) -> do
      result <- editFile (beWorkspace env) path find_ replace_ expect
      case result of
        Left e -> pure (Left e)
        Right (n, bytes) -> do
          emitFileIo env OpEdit path bytes
          pure (Right (record [("replacements", VInt (fromIntegral n))]))

moveFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
moveFileTool env args =
  orFail ((,) <$> argText args "from" <*> argText args "to") $ \(from, to) ->
    unitMutation env OpMove from (moveFile (beWorkspace env) from to)

copyFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
copyFileTool env args =
  orFail ((,) <$> argText args "from" <*> argText args "to") $ \(from, to) ->
    unitMutation env OpCopy from (copyFile (beWorkspace env) from to)

removeFileTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
removeFileTool env args =
  orFail (argText args "path") $ \path ->
    unitMutation env OpRemove path (removeFile (beWorkspace env) path)

makeDirTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
makeDirTool env args =
  orFail (argText args "path") $ \path ->
    unitMutation env OpMakeDir path (makeDir (beWorkspace env) path)

removeDirTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
removeDirTool env args =
  orFail (argText args "path") $ \path ->
    unitMutation env OpRemoveDir path (removeDir (beWorkspace env) path)

-- | Run a mutation returning an empty record, emitting its @file-io@ event
-- (with @path@ the primary/source path, §8.3.2) only on success.
unitMutation :: BuiltinEnv -> FileOp -> Text -> IO (Either RuntimeError ()) -> IO (Either RuntimeError RValue)
unitMutation env op path act = do
  result <- act
  case result of
    Left e -> pure (Left e)
    Right () -> do
      emitFileIo env op path 0
      pure (Right (record []))

-- Command execution (§6.3, §7.5) ---------------------------------------------

execTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
execTool env args =
  orFail prep $ \execArgs -> case beExecPolicy env of
    Nothing ->
      pure
        ( Left
            ( sandboxError
                "builtin/exec is disabled: project.json declares no 'exec' policy (§7.5)"
            )
        )
    Just policy -> do
      result <- runExec (beWorkspace env) policy execArgs
      case result of
        Left e -> pure (Left e)
        Right outcome -> do
          emitExec env (eaProgram execArgs) (eaArgs execArgs) outcome
          pure
            ( Right
                ( record
                    [ ("exit_code", VInt (fromIntegral (eoExitCode outcome))),
                      ("stdout", VString (eoStdout outcome)),
                      ("stderr", VString (eoStderr outcome)),
                      ("timed_out", VBool (eoTimedOut outcome))
                    ]
                )
            )
  where
    prep = do
      program <- argText args "program"
      argv <- argStrList args "args"
      stdin <- argText args "stdin"
      timeoutMs <- argInt args "timeout_ms"
      pure (ExecArgs program argv stdin timeoutMs)

-- LLM tools ------------------------------------------------------------------

llmGenerateTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
llmGenerateTool env args =
  orFail prep $ \(system, prompt, modelName, model) -> do
    runBilledText env model modelName system prompt [UserTurn prompt] $ \resp ->
      pure (Right (record [("text", VString resp.respText)]))
  where
    prep = do
      system <- argText args "system"
      prompt <- argText args "prompt"
      modelName <- argText args "model"
      model <- lookupModel modelName (beModels env)
      pure (system, prompt, modelName, model)

llmChatTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
llmChatTool env args =
  orFail prep $ \(system, modelName, turns, model) -> do
    runBilledText env model modelName system (renderTurns turns) turns $ \resp ->
      pure (Right (record [("text", VString resp.respText)]))
  where
    prep = do
      system <- argText args "system"
      modelName <- argText args "model"
      msgs <- argList args "messages"
      turns <- traverse toTurn msgs
      model <- lookupModel modelName (beModels env)
      pure (system, modelName, turns, model)

llmGenObjectTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
llmGenObjectTool env args =
  orFail prep $ \(system, prompt, modelName, schema, model) -> do
    budget <- checkBudgetSeam (beUsage env)
    case budget of
      Left e -> pure (Left e)
      Right _ -> do
        result <- genObjectUntyped (genReq system [UserTurn prompt]) model schema
        case result of
          Left ger -> pure (Left (llmError (T.pack (show ger.gerError))))
          Right (value, usage) -> do
            cost <- recordBilledCall (beUsage env) (primaryModel model) usage
            emitLlmUsage env modelName system prompt (canonicalJson value) usage cost
            pure (Right (record [("value", VJson value)]))
  where
    prep = do
      system <- argText args "system"
      prompt <- argText args "prompt"
      modelName <- argText args "model"
      schema <- argJson args "schema"
      model <- lookupModel modelName (beModels env)
      pure (system, prompt, modelName, schema, model)

introspectTool :: BuiltinEnv -> IO (Either RuntimeError RValue)
introspectTool env = do
  dump <- beIntrospect env
  pure (Right (record [("data", VJson dump)]))

-- Request construction -------------------------------------------------------

genReq :: Text -> [Turn] -> GenRequest
genReq system messages =
  GenRequest
    { grSystemPrompt = if T.null system then Nothing else Just system,
      grMessages = messages,
      grTools = [],
      grAbortSignal = Nothing,
      grLLMHooks = llmHooks defaultDebugHooks,
      grHooks = noHooks
    }

-- | Convert a @{ role, content }@ chat message record to an @llm-simple@
-- 'Turn'. Roles are validated at runtime (spec §6).
toTurn :: RValue -> Either RuntimeError Turn
toTurn v = do
  role <- fieldText v "role"
  content <- fieldText v "content"
  case role of
    "user" -> Right (UserTurn content)
    "assistant" -> Right (AssistantTurn content Nothing [])
    "tool" -> Right (UserTurn content)
    other -> Left (evalError ("invalid chat message role '" <> other <> "' (expected user|assistant|tool)"))

renderTurns :: [Turn] -> Text
renderTurns = T.intercalate "\n" . map render
  where
    render = \case
      UserTurn t -> "user: " <> t
      AssistantTurn t _ _ -> "assistant: " <> t
      ToolTurn _ -> "tool: <result>"

-- LLM billing (§8.4) ---------------------------------------------------------

runBilledText ::
  BuiltinEnv ->
  ModelWithFallbacks ->
  Text ->
  Text ->
  Text ->
  [Turn] ->
  (ChatResponse -> IO (Either RuntimeError RValue)) ->
  IO (Either RuntimeError RValue)
runBilledText env model modelName system prompt turns k = do
  budget <- checkBudgetSeam (beUsage env)
  case budget of
    Left e -> pure (Left e)
    Right _ -> do
      result <- generateTextWithFallbacks (genReq system turns) model
      case result of
        Left gerr -> pure (Left (llmError (T.pack (show gerr))))
        Right resp -> do
          let usage = fromMaybe (Usage 0 0 0) resp.respUsage
          cost <- recordBilledCall (beUsage env) (primaryModel model) usage
          emitLlmUsage env modelName system prompt resp.respText usage cost
          k resp

-- Trace emission -------------------------------------------------------------

emitFileIo :: BuiltinEnv -> FileOp -> Text -> Int -> IO ()
emitFileIo env op path bytes =
  emit_ env (FileIo (srQName (beStep env)) (srStepId (beStep env)) op path bytes)

-- | Emit the @exec@ trace event (§8.3.2). The argv is recorded verbatim (it is
-- @List<String>@, never @Secret<_>@).
emitExec :: BuiltinEnv -> Text -> [Text] -> ExecOutcome -> IO ()
emitExec env program argv outcome =
  emit_
    env
    ( Exec
        (srQName (beStep env))
        (srStepId (beStep env))
        program
        (valueToJson (VList (map VString argv)))
        (eoExitCode outcome)
        (eoTimedOut outcome)
        (eoStdoutBytes outcome)
        (eoStderrBytes outcome)
    )

emitLlmUsage :: BuiltinEnv -> Text -> Text -> Text -> Text -> Usage -> Double -> IO ()
emitLlmUsage env model system prompt response usage cost =
  emit_
    env
    ( LlmCall
        (srQName (beStep env))
        (srStepId (beStep env))
        model
        system
        prompt
        response
        usage.usageInputTokens
        usage.usageOutputTokens
        cost
    )

emit_ :: BuiltinEnv -> EventBody -> IO ()
emit_ env body = void (emit (beTracer env) body)

-- Argument extraction --------------------------------------------------------

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList

-- | Run @k@ on the extracted argument, short-circuiting to a failed IO result
-- when extraction failed.
orFail :: Either RuntimeError a -> (a -> IO (Either RuntimeError b)) -> IO (Either RuntimeError b)
orFail (Left e) _ = pure (Left e)
orFail (Right a) k = k a

argText :: Map Ident RValue -> Ident -> Either RuntimeError Text
argText args name = lookupArg args name >>= asText name

argList :: Map Ident RValue -> Ident -> Either RuntimeError [RValue]
argList args name = lookupArg args name >>= asList name

-- | Extract a @List<String>@ argument as @[Text]@ (spec §6.3 @exec.args@).
argStrList :: Map Ident RValue -> Ident -> Either RuntimeError [Text]
argStrList args name = argList args name >>= traverse (asText name)

argInt :: Map Ident RValue -> Ident -> Either RuntimeError Int
argInt args name = lookupArg args name >>= asInt name

argBool :: Map Ident RValue -> Ident -> Either RuntimeError Bool
argBool args name = lookupArg args name >>= asBool name

argJson :: Map Ident RValue -> Ident -> Either RuntimeError Value
argJson args name = valueToJson <$> lookupArg args name

lookupArg :: Map Ident RValue -> Ident -> Either RuntimeError RValue
lookupArg args name = case Map.lookup name args of
  Just v -> Right v
  Nothing -> Left (evalError ("missing argument '" <> name <> "' at runtime"))

asText :: Ident -> RValue -> Either RuntimeError Text
asText _ (VString t) = Right t
asText _ (VFileRef t) = Right t
asText name v = Left (evalError ("argument '" <> name <> "' is not text: " <> T.pack (show v)))

asList :: Ident -> RValue -> Either RuntimeError [RValue]
asList _ (VList xs) = Right xs
asList name v = Left (evalError ("argument '" <> name <> "' is not a list: " <> T.pack (show v)))

asInt :: Ident -> RValue -> Either RuntimeError Int
asInt _ (VInt n) = Right (fromInteger n)
asInt name v = Left (evalError ("argument '" <> name <> "' is not an integer: " <> T.pack (show v)))

asBool :: Ident -> RValue -> Either RuntimeError Bool
asBool _ (VBool b) = Right b
asBool name v = Left (evalError ("argument '" <> name <> "' is not a boolean: " <> T.pack (show v)))

fieldText :: RValue -> Ident -> Either RuntimeError Text
fieldText (VRecord m) name = case Map.lookup name m of
  Just (VString t) -> Right t
  Just _ -> Left (evalError ("chat message field '" <> name <> "' is not a string"))
  Nothing -> Left (evalError ("chat message missing field '" <> name <> "'"))
fieldText _ _ = Left (evalError "chat message is not a record")

-- Dynamic workflow evaluation (§6.4) -----------------------------------------

evalWorkflowTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
evalWorkflowTool env args =
  case (Map.lookup "source" args, jsonArg args "inputs") of
    (Just (VString source), Right inputs) ->
      case beEvalWorkflow env of
        Nothing ->
          pure (Left (evalError "builtin/eval-workflow is unavailable outside a workflow run"))
        Just seam -> runEvalWorkflow seam source inputs
    _ ->
      pure
        ( Left
            (evalError "builtin/eval-workflow requires source: String and inputs: Json")
        )
  where
    jsonArg m name = case Map.lookup name m of
      Just (VJson j) -> Right j
      Just VNull -> Right Null
      _ -> Left "not Json"

-- Cross-run trace reading (§6.5) ---------------------------------------------

listRunsTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
listRunsTool env args = orFail (argInt args "limit") $ \limit -> do
  let clamped = max 1 (min 100 limit)
  runs <- listRuns (workspaceRoot (beWorkspace env)) clamped
  emitFileIo env OpList ".hwfi/runs" 0
  pure (Right (record [("runs", VList (map runSummaryValue runs))]))
  where
    runSummaryValue RunSummary {..} =
      record
        [ ("id", VString rsId),
          ("started_at", VString rsStartedAt),
          ("entrypoint", VString rsEntrypoint),
          ("status", VString rsStatus)
        ]

readRunTraceTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
readRunTraceTool env args = orFail (argText args "run_id") $ \runId -> do
  let resolved =
        if runId == "current"
          then beRunId env
          else runId
  if resolved == beRunId env
    then do
      events <- snapshotEvents (beTracer env)
      let tracePath = ".hwfi/runs/" <> resolved <> "/trace.jsonl"
      emitFileIo env OpRead tracePath 0
      pure
        ( Right
            ( record
                [ ("ok", VBool True),
                  ("events", VList (map (VJson . eventToJson) events)),
                  ("error", VString "")
                ]
            )
        )
    else
      readRunTrace (workspaceRoot (beWorkspace env)) (beRunId env) runId >>= \case
        Left err ->
          pure
            ( Right
                ( record
                    [ ("ok", VBool False),
                      ("events", VList []),
                      ("error", VString err)
                    ]
                )
            )
        Right events -> do
          let tracePath = ".hwfi/runs/" <> resolved <> "/trace.jsonl"
          emitFileIo env OpRead tracePath 0
          pure
            ( Right
                ( record
                    [ ("ok", VBool True),
                      ("events", VList (map (VJson . eventToJson) events)),
                      ("error", VString "")
                    ]
                )
            )

-- Trace slice (§6.6) ---------------------------------------------------------

traceSliceTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
traceSliceTool env args =
  orFail
    ( (,,,)
        <$> argText args "run_id"
        <*> argText args "qname"
        <*> argText args "step_id"
        <*> argBool args "include_nested"
    )
    $ \(runId, qnameText, stepId, includeNested) -> do
      let targetQ = qnameFromText qnameText
          resolved =
            if runId == "current"
              then beRunId env
              else runId
      loadTrace runId >>= \case
        Left err ->
          pure
            ( Right
                ( record
                    [ ("ok", VBool False),
                      ("events", VList []),
                      ("error", VString err)
                    ]
                )
            )
        Right events -> do
          let tracePath = ".hwfi/runs/" <> resolved <> "/trace.jsonl"
          emitFileIo env OpRead tracePath 0
          let sliced = sliceTrace events targetQ stepId includeNested
          pure
            ( Right
                ( record
                    [ ("ok", VBool True),
                      ("events", VList (map (VJson . eventToJson) sliced)),
                      ("error", VString "")
                    ]
                )
            )
  where
    loadTrace rid
      | rid == "current" || rid == beRunId env =
          snapshotEvents (beTracer env) <&> Right
      | otherwise =
          readRunTrace (workspaceRoot (beWorkspace env)) (beRunId env) rid

-- Data plumbing (§13.1.2) ------------------------------------------------------

jsonGetTool :: Map Ident RValue -> IO (Either RuntimeError RValue)
jsonGetTool args =
  pure $
    case (Map.lookup "json" args, argText args "path") of
      (Just (VJson root), Right pathText) ->
        case jsonGetPath root (T.splitOn "." pathText) of
          Right value ->
            Right
              ( record
                  [ ("ok", VBool True),
                    ("value", VJson value),
                    ("error", VString "")
                  ]
              )
          Left err ->
            Right
              ( record
                  [ ("ok", VBool False),
                    ("value", VJson Null),
                    ("error", VString err)
                  ]
              )
      _ ->
        Left (evalError "builtin/json-get requires json: Json and path: String")

jsonGetPath :: Value -> [Text] -> Either Text Value
jsonGetPath v [] = Right v
jsonGetPath (Object o) (k : ks)
  | T.null k = Left "empty path segment"
  | otherwise =
      case KM.lookup (K.fromText k) o of
        Just v' -> jsonGetPath v' ks
        Nothing -> Left ("missing key '" <> k <> "'")
jsonGetPath _ (k : _) = Left ("not an object at '" <> k <> "'")

jsonValuesTool :: Map Ident RValue -> IO (Either RuntimeError RValue)
jsonValuesTool args =
  pure $
    case (Map.lookup "json" args, argText args "path") of
      (Just (VJson root), Right pathText) ->
        case resolveJsonTarget root pathText of
          Left err ->
            Right
              ( record
                  [ ("ok", VBool False),
                    ("values", VList []),
                    ("error", VString err)
                  ]
              )
          Right target ->
            case jsonValues target of
              Left err ->
                Right
                  ( record
                      [ ("ok", VBool False),
                        ("values", VList []),
                        ("error", VString err)
                      ]
                  )
              Right values ->
                Right
                  ( record
                      [ ("ok", VBool True),
                        ("values", VList (map VJson values)),
                        ("error", VString "")
                      ]
                  )
      _ ->
        Left (evalError "builtin/json-values requires json: Json and path: String")

resolveJsonTarget :: Value -> Text -> Either Text Value
resolveJsonTarget root pathText
  | T.null (T.strip pathText) = Right root
  | otherwise = jsonGetPath root (T.splitOn "." pathText)

jsonValues :: Value -> Either Text [Value]
jsonValues (Object o) =
  Right $
    filter (/= Null) $
      mapMaybe (`KM.lookup` o) (sortObjectKeys o)
jsonValues (Array a) = Right $ filter (/= Null) (V.toList a)
jsonValues _ = Left "expected a JSON object or array"

sortObjectKeys :: KM.KeyMap Value -> [K.Key]
sortObjectKeys o =
  let keys = KM.keys o
   in if all (isJust . readIntegerKey . K.toText) keys
        then sortOn (fromMaybe 0 . readIntegerKey . K.toText) keys
        else sort keys
  where
    readIntegerKey t =
      case decimal t of
        Right (n, rest) | T.null rest -> Just n
        _ -> Nothing

concatTool :: Map Ident RValue -> IO (Either RuntimeError RValue)
concatTool args =
  pure $
    case argStrList args "parts" of
      Right parts -> Right (record [("text", VString (T.concat parts))])
      Left e -> Left e

-- Workflow logging (§13.1.5) ---------------------------------------------------

logTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
logTool env args =
  case (argText args "message", jsonArg args "fields") of
    (Right message, Right fields) -> do
      let q = srQName (beStep env)
          sid = srStepId (beStep env)
          redactedFields = redactJsonFields fields
      emit_ env (WorkflowLog q sid message redactedFields)
      pure (Right (record [("logged", VBool True)]))
    _ ->
      pure (Left (evalError "builtin/log requires message: String and fields: Json"))
  where
    jsonArg m name = case Map.lookup name m of
      Just (VJson j) -> Right j
      Just VNull -> Right Null
      _ -> Left "not Json"
    redactJsonFields Null = Null
    redactJsonFields (Object o) =
      Object (KM.map redactJsonValue o)
    redactJsonFields v = v
    redactJsonValue (String t) = String t
    redactJsonValue v@(Object _) = redactJsonFields v
    redactJsonValue (Array a) = Array (fmap redactJsonValue a)
    redactJsonValue v = v

-- Skill catalog (§6.7) -------------------------------------------------------

discoverSkillsTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
discoverSkillsTool env args =
  orFail ((,,) <$> argText args "query" <*> argStrList args "kinds" <*> argInt args "limit") $
    \(query, kinds, limit) -> do
      let cat = beSkillCatalog env
          entries = Cat.discoverSkills cat query kinds limit
          q = srQName (beStep env)
          sid = srStepId (beStep env)
      emit_ env (SkillDiscover q sid query kinds limit (length entries))
      pure (Right (discoverSkillsResult cat query kinds limit))

loadSkillTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
loadSkillTool env args =
  orFail (argText args "id") $ \skillId -> do
    let cat = beSkillCatalog env
        result = loadSkillScripted cat skillId
        q = srQName (beStep env)
        sid = srStepId (beStep env)
    case result of
      VRecord m
        | Map.lookup "ok" m == Just (VBool True) ->
            let kind = fieldText_ m "kind"
                loaded = Map.lookup "loaded" m == Just (VBool True)
             in do
                  emit_ env (SkillLoad q sid skillId kind loaded)
                  pure (Right result)
      _ -> pure (Right result)
  where
    fieldText_ m name = case Map.lookup name m of
      Just (VString t) -> t
      _ -> ""
