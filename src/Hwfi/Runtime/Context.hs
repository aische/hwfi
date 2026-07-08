-- | Construction of the ambient @ctx : Context@ value injected into every step
-- (spec §5.2, §5.4, task 4.2).
--
-- @ctx@ is rebuilt for each step because two of its fields vary per step:
-- @ctx.self.step_id@ and @ctx.trace@ (the ordered events preceding the step,
-- §8.3.5). The remaining fields come from the immutable 'RunInfo' assembled at
-- startup. @ctx.env@ is populated only from the whitelisted process variables
-- (§7.2); a variable whose name matches the secret patterns (§5.5) is wrapped
-- as @Secret<String>@ so it redacts in traces.
module Hwfi.Runtime.Context
  ( RunInfo (..),
    buildEnvRecord,
    contextValue,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName, renderQName)
import Hwfi.Runtime.Trace (TraceEvent, eventToJson)
import Hwfi.Runtime.RunUsage (RunUsage (..), usageRecordValue)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Type (isSecretEnvName)

-- | Immutable per-run information used to build every step's @ctx@ (§5.2).
-- @riRootInputs@ is the JSON of the /root/ workflow inputs (secrets redacted),
-- surfaced verbatim as @ctx.inputs@ in every workflow, including sub-workflows.
data RunInfo = RunInfo
  { riRunId :: Text,
    riStartedAt :: Text,
    riEntrypoint :: Text,
    riRootInputs :: Value,
    -- | Prebuilt @ctx.env@ fields (secret-named vars already wrapped, §5.5).
    riEnvFields :: [(Ident, RValue)]
  }
  deriving stock (Show)

-- | Build the @ctx.env@ record fields from the whitelisted variables (§5.7),
-- auto-wrapping secret-named values as @Secret<String>@ (§5.5).
buildEnvRecord :: Map Text Text -> [(Ident, RValue)]
buildEnvRecord vars =
  [ (name, fieldValue name value)
  | (name, value) <- Map.toList vars
  ]
  where
    fieldValue name value
      | isSecretEnvName name = VSecret (Just name) (VString value)
      | otherwise = VString value

-- | Build the ambient @ctx@ value for a step (spec §5.2). @q@\/@stepId@ are the
-- enclosing workflow qname and the step id; @events@ is the trace snapshot the
-- step observes (§8.3.5).
contextValue :: RunInfo -> RunUsage -> QName -> Ident -> [TraceEvent] -> RValue
contextValue ri usage q stepId events =
  VRecord $
    Map.fromList
      [ ("workspace", VFileRef "."),
        ( "run",
          VRecord $
            Map.fromList
              [ ("id", VString (riRunId ri)),
                ("started_at", VString (riStartedAt ri)),
                ("entrypoint", VString (riEntrypoint ri)),
                ("usage", usageRecordValue usage)
              ]
        ),
        ( "self",
          VRecord $
            Map.fromList
              [ ("qname", VString (renderQName q)),
                ("step_id", VString stepId)
              ]
        ),
        ("inputs", VJson (riRootInputs ri)),
        ("trace", VList (map (VJson . eventToJson) events)),
        ("env", VRecord (Map.fromList (riEnvFields ri)))
      ]
