-- | Project loader (spec §2). Walks a project directory, parses each markdown
-- declaration, classifies it by kind (workflow / tool / type-alias / prompt),
-- and assembles a 'Project' keyed by qualified name.
--
-- Classification is by explicit frontmatter @kind@ when present, else by the
-- top-level directory (@workflows/@, @tools/@, @skills/@, @types/@). Each file
-- holds
-- exactly one declaration (§2); type-alias and prompt files must not contain
-- @step@ blocks.
module Hwfi.Parse.Project
  ( loadProject,
    parseDeclaration,
    parseEvalWorkflowSource,
    evalWorkflowDiagPath,
    qnameFromRelPath,
  )
where

import Control.Monad (forM)
import Data.Maybe (fromMaybe)
import Data.Aeson (Object)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.InstructionSkill (InstructionSkill (..))
import Hwfi.Ast.Name (QName (..), qnameFromText, renderQName)
import Hwfi.Ast.Project
import Hwfi.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfi.Ast.Step (Statement)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Signature, Workflow (..))
import Hwfi.Parse.Frontmatter (frontmatterKind, frontmatterName, parseSkillBlock, parseYamlObject, signatureFromYaml)
import Hwfi.Parse.Markdown (MarkdownFile (..), MdStepBlock (..), parseMarkdown)
import Hwfi.Parse.Section (buildSections)
import Hwfi.Parse.Step (parseStepBlock)
import Hwfi.Parse.TypeAlias (parseTypeAlias)
import Hwfi.Project.Manifest (ProjectManifest, loadManifest)
import Hwfi.SkillCatalog (instructionBodyFromMarkdown, summaryFallback)
import Hwfi.Source (Diagnostic (..), Pos (..))
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, splitDirectories, takeExtension, (</>))

-- | Load and parse an entire project. Returns all accumulated diagnostics on
-- failure, or the assembled 'Project' on success.
loadProject :: FilePath -> IO (Either [Diagnostic] Project)
loadProject projectDir = do
  emanifest <- loadManifest projectDir
  case emanifest of
    Left msg -> pure (Left [Diagnostic "project.json" (Pos 1 1) 1 msg])
    Right manifest -> do
      relpaths <- findMarkdownFiles projectDir
      results <- forM relpaths $ \rp -> do
        content <- TIO.readFile (projectDir </> rp)
        pure (fmap (\d -> (declQName d, d)) (parseDeclaration rp content))
      pure $ case collect results of
        Left ds -> Left ds
        Right pairs -> Right (assemble manifest pairs)

assemble :: ProjectManifest -> [(QName, Declaration)] -> Project
assemble manifest pairs =
  Project {projManifest = manifest, projDecls = Map.fromList pairs}

-- | The virtual diagnostic path for dynamically evaluated workflow source
-- (spec §6.4.2).
evalWorkflowDiagPath :: FilePath
evalWorkflowDiagPath = "<eval-workflow>"

-- | Parse runtime-synthesized workflow source for @builtin/eval-workflow@
-- (spec §6.4). Unlike 'parseDeclaration', the qualified name comes from the
-- frontmatter @name@ field (not the file path), and all diagnostics use
-- 'evalWorkflowDiagPath'.
parseEvalWorkflowSource :: Text -> Either [Diagnostic] Declaration
parseEvalWorkflowSource content = do
  md <- parseMarkdown evalWorkflowDiagPath content
  mObj <- case mdFrontmatter md of
    Nothing -> Right Nothing
    Just yamlText -> Just . (,) yamlText <$> parseYamlObject evalWorkflowDiagPath yamlText
  let kindTag =
        case classify "" (snd <$> mObj >>= frontmatterKind) of
          CUnknown -> CWorkflow
          k -> k
  case kindTag of
    CWorkflow -> buildEvalWorkflowDecl md mObj
    CTool ->
      Left
        [ diag evalWorkflowDiagPath "eval-workflow source must be a workflow declaration, not a tool"
        ]
    _ ->
      Left
        [ diag evalWorkflowDiagPath "eval-workflow source must be a workflow declaration"
        ]

buildEvalWorkflowDecl ::
  MarkdownFile -> Maybe (Text, Object) -> Either [Diagnostic] Declaration
buildEvalWorkflowDecl md mObj = do
  (yamlText, o) <- case mObj of
    Just pair -> Right pair
    Nothing -> Left [diag evalWorkflowDiagPath "eval-workflow source must have YAML frontmatter"]
  qname <- case frontmatterName o of
    Just n -> Right (qnameFromText n)
    Nothing -> Left [diag evalWorkflowDiagPath "eval-workflow source must declare 'name' in frontmatter"]
  sig <- signatureFromYaml evalWorkflowDiagPath yamlText o
  stmts <- concat <$> collect (map parseBlock (mdStepBlocks md))
  let sections = buildSections (mdSourceLines md) (mdHeadings md)
  pure (DeclWorkflow (Workflow qname sig stmts sections))
  where
    parseBlock b = parseStepBlock evalWorkflowDiagPath (Pos (msStartLine b) 1) (msContent b)

-- | Parse a single declaration file. @relpath@ is the file path relative to
-- the project root (used both for diagnostics and to derive the qualified
-- name).
parseDeclaration :: FilePath -> Text -> Either [Diagnostic] Declaration
parseDeclaration relpath content = do
  md <- parseMarkdown relpath content
  mObj <- case mdFrontmatter md of
    Nothing -> Right Nothing
    Just yamlText -> Just . (,) yamlText <$> parseYamlObject relpath yamlText
  let qname = qnameFromRelPath relpath
      topDir = case splitDirectories relpath of
        (d : _) -> d
        [] -> ""
      kindTag = classify topDir (snd <$> mObj >>= frontmatterKind)
      skillKind = skillKindFromObj relpath mObj
  case (topDir, skillKind) of
    ("skills", Just SkillInstruction) -> buildInstructionSkillDecl relpath qname md mObj
    _ ->
      case kindTag of
        CTypeAlias -> buildTypeAliasDecl relpath qname md
        CPrompt -> buildPromptDecl relpath qname md
        CWorkflow -> buildWorkflowDecl relpath qname md mObj
        CTool -> buildToolDecl relpath qname md mObj skillKind
        CUnknown ->
          Left [diag relpath ("cannot classify declaration '" <> renderQName qname <> "': unknown kind or location")]

-- Classification ------------------------------------------------------------

data KindTag = CWorkflow | CTool | CTypeAlias | CPrompt | CUnknown

classify :: FilePath -> Maybe Text -> KindTag
classify topDir mkind = case mkind of
  Just "type-alias" -> CTypeAlias
  Just "prompt" -> CPrompt
  Just "workflow" -> CWorkflow
  Just "tool" -> CTool
  Just _ -> CUnknown
  Nothing -> case topDir of
    "workflows" -> CWorkflow
    "tools" -> CTool
    "skills" -> CTool
    "types" -> CTypeAlias
    _ -> CUnknown

-- Builders ------------------------------------------------------------------

buildTypeAliasDecl :: FilePath -> QName -> MarkdownFile -> Either [Diagnostic] Declaration
buildTypeAliasDecl relpath qname md = do
  ensureNoSteps relpath "type-alias" md
  yamlText <- requireFrontmatter relpath "type-alias" md
  DeclTypeAlias <$> parseTypeAlias relpath qname yamlText

buildPromptDecl :: FilePath -> QName -> MarkdownFile -> Either [Diagnostic] Declaration
buildPromptDecl relpath qname md = do
  ensureNoSteps relpath "prompt" md
  Right (DeclPrompt (Prompt qname (buildSections (mdSourceLines md) (mdHeadings md))))

buildWorkflowDecl ::
  FilePath -> QName -> MarkdownFile -> Maybe (Text, Object) -> Either [Diagnostic] Declaration
buildWorkflowDecl relpath qname md mObj = do
  (sig, stmts, sections) <- buildSignatureBody relpath qname md mObj
  Right (DeclWorkflow (Workflow qname sig stmts sections))

buildToolDecl ::
  FilePath ->
  QName ->
  MarkdownFile ->
  Maybe (Text, Object) ->
  Maybe SkillKind ->
  Either [Diagnostic] Declaration
buildToolDecl relpath qname md mObj mSkillKind = do
  (sig, stmts, sections) <- buildSignatureBody relpath qname md mObj
  skillMeta <- parseSkillMeta relpath mObj
  let bodyPreview =
        if mSkillKind == Just SkillInstruction
          then Nothing
          else Just (instructionBodyFromMarkdown md)
  Right (DeclTool (Tool qname sig stmts sections skillMeta bodyPreview))

buildInstructionSkillDecl ::
  FilePath ->
  QName ->
  MarkdownFile ->
  Maybe (Text, Object) ->
  Either [Diagnostic] Declaration
buildInstructionSkillDecl relpath qname md mObj = do
  ensureNoSteps relpath "instruction skill" md
  (yamlText, o) <- case mObj of
    Just pair -> Right pair
    Nothing -> Left [diag relpath "instruction skill file must have YAML frontmatter"]
  validateName relpath qname o
  meta <- parseSkillBlock relpath yamlText o
  let body = instructionBodyFromMarkdown md
      summary = fromMaybe (summaryFallback body) (smSummary meta)
      sections = buildSections (mdSourceLines md) (mdHeadings md)
  pure
    ( DeclInstruction
        ( InstructionSkill
            { isName = qname,
              isSummary = summary,
              isTags = smTags meta,
              isBody = body,
              isSections = sections
            }
        )
    )

skillKindFromObj :: FilePath -> Maybe (Text, Object) -> Maybe SkillKind
skillKindFromObj relpath = \case
  Just (yamlText, o) ->
    case parseSkillBlock relpath yamlText o of
      Right meta -> Just (smKind meta)
      Left _ -> Nothing
  Nothing -> Nothing

parseSkillMeta :: FilePath -> Maybe (Text, Object) -> Either [Diagnostic] (Maybe SkillMeta)
parseSkillMeta relpath = \case
  Just (yamlText, o) -> Just <$> parseSkillBlock relpath yamlText o
  Nothing -> Right Nothing

-- | Shared workflow/tool assembly: validate the declared name, build the
-- typed signature, parse all step blocks, and collect addressable sections.
buildSignatureBody ::
  FilePath ->
  QName ->
  MarkdownFile ->
  Maybe (Text, Object) ->
  Either [Diagnostic] (Signature, [Statement], [Section])
buildSignatureBody relpath qname md mObj = do
  (yamlText, o) <- case mObj of
    Just pair -> Right pair
    Nothing -> Left [diag relpath "workflow/tool file must have YAML frontmatter"]
  validateName relpath qname o
  sig <- signatureFromYaml relpath yamlText o
  stmts <- concat <$> collect (map parseBlock (mdStepBlocks md))
  let sections = buildSections (mdSourceLines md) (mdHeadings md)
  pure (sig, stmts, sections)
  where
    parseBlock b = parseStepBlock relpath (Pos (msStartLine b) 1) (msContent b)

validateName :: FilePath -> QName -> Object -> Either [Diagnostic] ()
validateName relpath qname o =
  case frontmatterName o of
    Just n
      | n == renderQName qname -> Right ()
      | otherwise ->
          Left
            [ diag
                relpath
                ( "frontmatter name '"
                    <> n
                    <> "' must equal the file's qualified name '"
                    <> renderQName qname
                    <> "'"
                )
            ]
    Nothing -> Left [diag relpath "workflow/tool frontmatter must declare 'name'"]

-- Helpers -------------------------------------------------------------------

requireFrontmatter :: FilePath -> Text -> MarkdownFile -> Either [Diagnostic] Text
requireFrontmatter relpath what md =
  case mdFrontmatter md of
    Just y -> Right y
    Nothing -> Left [diag relpath (what <> " file must have YAML frontmatter")]

ensureNoSteps :: FilePath -> Text -> MarkdownFile -> Either [Diagnostic] ()
ensureNoSteps relpath what md =
  case mdStepBlocks md of
    [] -> Right ()
    (b : _) ->
      Left [Diagnostic relpath (Pos (msStartLine b) 1) 1 (what <> " file must not contain step blocks")]

-- | Derive a qualified name from a file path relative to the project root,
-- dropping the extension (e.g. @workflows/main.md@ → @workflows/main@).
qnameFromRelPath :: FilePath -> QName
qnameFromRelPath relpath =
  case map T.pack (splitDirectories (dropExtension relpath)) of
    (s : ss) -> QName (s :| ss)
    [] -> QName (T.empty :| [])

-- | Recursively find @.md@ files under @workflows/@, @tools/@, @skills/@, and
-- @types/@, returning paths relative to the project root.
findMarkdownFiles :: FilePath -> IO [FilePath]
findMarkdownFiles projectDir =
  concat <$> mapM walkTop ["workflows", "tools", "skills", "types"]
  where
    walkTop d = do
      let abs' = projectDir </> d
      exists <- doesDirectoryExist abs'
      if exists then walk d abs' else pure []
    walk relBase absDir = do
      entries <- listDirectory absDir
      fmap concat $ forM entries $ \e -> do
        let absE = absDir </> e
            relE = relBase </> e
        isDir <- doesDirectoryExist absE
        if isDir
          then walk relE absE
          else pure [relE | takeExtension e == ".md"]

collect :: [Either [d] a] -> Either [d] [a]
collect es = case concat [ds | Left ds <- es] of
  [] -> Right [a | Right a <- es]
  ds -> Left ds

diag :: FilePath -> Text -> Diagnostic
diag path msg = Diagnostic path (Pos 1 1) 1 msg
