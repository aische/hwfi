-- | Check-time skill catalog (spec §6.7). Built from @skills/*.md@ declarations
-- and consumed by @builtin/discover-skills@ and @builtin/load-skill@.
module Hwfi.SkillCatalog
  ( SkillKind (..),
    SkillMeta (..),
    skillKindText,
    parseSkillKind,
    SkillEntry (..),
    SkillCatalog (..),
    emptySkillCatalog,
    buildSkillCatalog,
    skillPolicyFromManifest,
    lookupSkillEntry,
    discoverSkills,
    instructionBodyFromMarkdown,
    summaryFallback,
    isSkillQName,
  )
where

import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.InstructionSkill (InstructionSkill (..))
import Hwfi.Ast.Name (Ident, QName, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..), Project (..))
import Hwfi.Ast.Skill (SkillKind (..), SkillMeta (..), parseSkillKind, skillKindText)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Type (Type (..))
import Hwfi.Parse.Markdown (MarkdownFile (..))
import Hwfi.Project.Manifest (ProjectManifest (..), SkillPolicy (..), defaultSkillPolicy)
import Hwfi.Runtime.Schema (ineligibilityReasons)
import Data.Set (Set)
import Data.Set qualified as Set

skillPolicyFromManifest :: ProjectManifest -> SkillPolicy
skillPolicyFromManifest manifest = fromMaybe defaultSkillPolicy (pmSkills manifest)

-- | One catalog row returned by @discover-skills@ (metadata only).
data SkillEntry = SkillEntry
  { seId :: QName,
    seKind :: SkillKind,
    seSummary :: Text,
    seTags :: [Text],
    sePath :: FilePath,
    seChecked :: Bool,
    seAgentEligible :: Bool,
  -- | Full markdown body for instruction skills (never exposed via discover).
    seBody :: Maybe Text
  }
  deriving stock (Eq, Show)

data SkillCatalog = SkillCatalog
  { scPolicy :: SkillPolicy,
    scEntries :: Map QName SkillEntry
  }
  deriving stock (Eq, Show)

emptySkillCatalog :: SkillPolicy -> SkillCatalog
emptySkillCatalog policy = SkillCatalog policy Map.empty

lookupSkillEntry :: QName -> SkillCatalog -> Maybe SkillEntry
lookupSkillEntry q cat = Map.lookup q (scEntries cat)

isSkillQName :: QName -> Bool
isSkillQName q = case qnameSegments q of
  s : _ -> s == "skills"
  [] -> False

-- | Build the catalog after a successful @hwfi check@.
buildSkillCatalog ::
  Project ->
  Set QName ->
  Map QName [(Ident, Type)] ->
  (QName -> Bool) ->
  SkillCatalog
buildSkillCatalog proj checked inputSigs reaches =
  SkillCatalog policy (Map.fromList entries)
  where
    policy = skillPolicyFromManifest (projManifest proj)
    entries =
      mapMaybe entryFor (Map.toList (projDecls proj))
    entryFor (q, d) = case d of
      DeclInstruction is ->
        Just
          ( isName is,
            SkillEntry
              { seId = isName is,
                seKind = SkillInstruction,
                seSummary = isSummary is,
                seTags = isTags is,
                sePath = declPath q,
                seChecked = True,
                seAgentEligible = False,
                seBody = Just (isBody is)
              }
          )
      DeclTool t
        | isSkillQName (toolName t) ->
            Just
              ( toolName t,
                SkillEntry
                  { seId = toolName t,
                    seKind = SkillCallable,
                    seSummary = callableSummary t,
                    seTags = maybe [] smTags (toolSkillMeta t),
                    sePath = declPath q,
                    seChecked = q `Set.member` checked,
                    seAgentEligible = callableEligible q t,
                    seBody = Nothing
                  }
              )
      _ -> Nothing
    callableSummary t =
      fromMaybe (maybe "" summaryFallback (toolBodyPreview t)) (toolSkillMeta t >>= smSummary)
    callableEligible q _ =
      let ins = Map.findWithDefault [] q inputSigs
       in null (ineligibilityReasons ins) && not (reaches q)

declPath :: QName -> FilePath
declPath q = T.unpack (renderQName q) <> ".md"

-- | Filter and rank catalog entries for @discover-skills@ (§6.7.1).
discoverSkills :: SkillCatalog -> Text -> [Text] -> Int -> [SkillEntry]
discoverSkills cat query kinds limit =
  take effectiveLimit ranked
  where
    effectiveLimit = if limit <= 0 then 20 else limit
    qLower = T.toLower (T.strip query)
    kindFilter = mapMaybe parseSkillKind kinds
    matched =
      filter matchesKind $
        filter matchesQuery $
          Map.elems (scEntries cat)
    matchesKind e =
      null kindFilter || seKind e `elem` kindFilter
    matchesQuery e
      | T.null qLower = True
      | otherwise =
          textHits qLower (renderQName (seId e))
            || textHits qLower (seSummary e)
            || any (tagHits qLower) (seTags e)
    ranked =
      sortOn
        ( \e ->
            ( Down (scoreTag e),
              Down (scoreSummary e),
              Down (scoreId e),
              renderQName (seId e)
            )
        )
        matched
    scoreTag :: SkillEntry -> Int
    scoreTag e =
      if any (tagHits qLower) (seTags e) then (1 :: Int) else 0
    scoreSummary :: SkillEntry -> Int
    scoreSummary e =
      if textHits qLower (seSummary e) then (1 :: Int) else 0
    scoreId :: SkillEntry -> Int
    scoreId e =
      if textHits qLower (renderQName (seId e)) then (1 :: Int) else 0

-- | Case-insensitive substring match in either direction.
textHits :: Text -> Text -> Bool
textHits q t =
  let ql = T.toLower q
      tl = T.toLower t
   in ql `T.isInfixOf` tl || tl `T.isInfixOf` ql

-- | Match a query (including individual words) against a tag.
tagHits :: Text -> Text -> Bool
tagHits q tag =
  let tl = T.toLower tag
   in textHits q tl || any (`textHits` tl) (map T.toLower (T.words q))

-- | Markdown body after frontmatter (instruction skills).
instructionBodyFromMarkdown :: MarkdownFile -> Text
instructionBodyFromMarkdown md =
  T.strip $
    case mdFrontmatter md of
      Nothing -> T.unlines (mdSourceLines md)
      Just _ -> bodyAfterFence (mdSourceLines md)
  where
    bodyAfterFence lines = case lines of
      (_ : rest) ->
        case break (\l -> T.strip l == "---") rest of
          (_, _ : bodyLines) -> T.unlines bodyLines
          _ -> ""
      [] -> ""

-- | First non-empty, non-fence body line when @skill.summary@ is absent.
summaryFallback :: Text -> Text
summaryFallback body =
  fromMaybe "" $
    find isGood (map T.strip (T.lines body))
  where
    isGood l = not (T.null l) && not ("```" `T.isPrefixOf` l)
