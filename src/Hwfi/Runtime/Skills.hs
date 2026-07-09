-- | Shared skill discovery/loading logic for builtins and the agent loop (§6.7).
module Hwfi.Runtime.Skills
  ( discoverSkillsResult,
    loadSkillScripted,
    skillEntryDiscoverJson,
    loadSkillResultRecord,
    instructionInjectionText,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (fromMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (QName, qnameFromText, renderQName)
import Hwfi.Project.Manifest ()
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.SkillCatalog
  ( SkillCatalog,
    SkillEntry (..),
    SkillKind (..),
    discoverSkills,
    lookupSkillEntry,
    skillKindText,
  )

discoverSkillsResult :: SkillCatalog -> Text -> [Text] -> Int -> RValue
discoverSkillsResult cat query kinds limit =
  let entries = discoverSkills cat query kinds limit
   in record
        [ ("ok", VBool True),
          ("skills", VList (map skillEntryDiscoverJson entries)),
          ("error", VString "")
        ]

skillEntryDiscoverJson :: SkillEntry -> RValue
skillEntryDiscoverJson e =
  record
    [ ("id", VString (renderQName (seId e))),
      ("kind", VString (skillKindText (seKind e))),
      ("summary", VString (seSummary e)),
      ("tags", VList (map VString (seTags e))),
      ("checked", VBool (seChecked e)),
      ("agent_eligible", VBool (seAgentEligible e))
    ]

loadSkillScripted :: SkillCatalog -> Text -> RValue
loadSkillScripted cat skillId =
  case lookupSkillById cat skillId of
    Nothing ->
      loadSkillResultRecord False "" False False "" ("unknown skill id '" <> skillId <> "'")
    Just e ->
      case seKind e of
        SkillInstruction ->
          loadSkillResultRecord True (skillKindText SkillInstruction) False True (fromMaybe "" (seBody e)) ""
        SkillCallable ->
          loadSkillResultRecord True (skillKindText SkillCallable) False False "" ""

loadSkillResultRecord :: Bool -> Text -> Bool -> Bool -> Text -> Text -> RValue
loadSkillResultRecord ok kind loaded isLoaded content err =
  record
    [ ("ok", VBool ok),
      ("kind", VString kind),
      ("loaded", VBool isLoaded),
      ("content", VString content),
      ("error", VString err)
    ]

lookupSkillById :: SkillCatalog -> Text -> Maybe SkillEntry
lookupSkillById cat skillId = lookupSkillEntry (qnameFromText skillId) cat

instructionInjectionText :: Text -> Text -> Text
instructionInjectionText skillId body =
  "## Loaded skill: " <> skillId <> "\n\n" <> body

record :: [(Text, RValue)] -> RValue
record pairs = VRecord (Map.fromList pairs)
