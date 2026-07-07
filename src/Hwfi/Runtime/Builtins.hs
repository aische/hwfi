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

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, renderQName)
import Hwfi.Compat
  ( ChatResponse (..),
    GenRequest (..),
    GenerateErrorResult (..),
    Turn (..),
    Usage (..),
    generateTextWithFallbacks,
    genObjectUntyped,
    llmHooks,
    noHooks,
  )
import Hwfi.Runtime.Error (RuntimeError, StepRef (..), evalError, llmError)
import Hwfi.Runtime.Gateways (ModelStore, lookupModel)
import Hwfi.Runtime.Trace (EventBody (..), FileOp (..), Tracer, emit)
import Hwfi.Runtime.Value (RValue (..), canonicalJson, valueToJson)
import Hwfi.Runtime.Workspace (Workspace, listDir, readTextFile, writeTextFile)
import LLM (defaultDebugHooks)

-- | Everything a builtin needs from the surrounding run.
data BuiltinEnv = BuiltinEnv
  { beWorkspace :: Workspace,
    beModels :: ModelStore,
    beTracer :: Tracer,
    beStep :: StepRef,
    -- | Produce the @builtin/introspect@ dump for the current step (§6). Built
    -- by the executor because it needs the live bindings and trace.
    beIntrospect :: IO Value
  }

-- | Dispatch a builtin call. The caller guarantees @q@ is a builtin qname.
runBuiltin :: BuiltinEnv -> QName -> Map Ident RValue -> IO (Either RuntimeError RValue)
runBuiltin env q args = case renderQName q of
  "builtin/read-file" -> readFileTool env args
  "builtin/write-file" -> writeFileTool env args
  "builtin/list-dir" -> listDirTool env args
  "builtin/llm-generate" -> llmGenerateTool env args
  "builtin/llm-chat" -> llmChatTool env args
  "builtin/llm-gen-object" -> llmGenObjectTool env args
  "builtin/introspect" -> introspectTool env
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

-- LLM tools ------------------------------------------------------------------

llmGenerateTool :: BuiltinEnv -> Map Ident RValue -> IO (Either RuntimeError RValue)
llmGenerateTool env args =
  orFail prep $ \(system, prompt, modelName, model) -> do
    result <- generateTextWithFallbacks (genReq system [UserTurn prompt]) model
    case result of
      Left gerr -> pure (Left (llmError (T.pack (show gerr))))
      Right resp -> do
        emitLlm env modelName system prompt resp
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
    result <- generateTextWithFallbacks (genReq system turns) model
    case result of
      Left gerr -> pure (Left (llmError (T.pack (show gerr))))
      Right resp -> do
        emitLlm env modelName system (renderTurns turns) resp
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
    result <- genObjectUntyped (genReq system [UserTurn prompt]) model schema
    case result of
      Left ger -> pure (Left (llmError (T.pack (show ger.gerError))))
      Right (value, usage) -> do
        emitLlmUsage env modelName system prompt (canonicalJson value) usage
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

-- Trace emission -------------------------------------------------------------

emitFileIo :: BuiltinEnv -> FileOp -> Text -> Int -> IO ()
emitFileIo env op path bytes =
  emit_ env (FileIo (srQName (beStep env)) (srStepId (beStep env)) op path bytes)

emitLlm :: BuiltinEnv -> Text -> Text -> Text -> ChatResponse -> IO ()
emitLlm env model system prompt resp =
  emitLlmUsage env model system prompt resp.respText usage
  where
    usage = maybe (Usage 0 0 0) id resp.respUsage

emitLlmUsage :: BuiltinEnv -> Text -> Text -> Text -> Text -> Usage -> IO ()
emitLlmUsage env model system prompt response usage =
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
    )

emit_ :: BuiltinEnv -> EventBody -> IO ()
emit_ env body = emit (beTracer env) body >> pure ()

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

fieldText :: RValue -> Ident -> Either RuntimeError Text
fieldText (VRecord m) name = case Map.lookup name m of
  Just (VString t) -> Right t
  Just _ -> Left (evalError ("chat message field '" <> name <> "' is not a string"))
  Nothing -> Left (evalError ("chat message missing field '" <> name <> "'"))
fieldText _ _ = Left (evalError "chat message is not a record")
