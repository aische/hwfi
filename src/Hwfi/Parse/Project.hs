-- | Project loader (spec §2). Walks a project directory, parses each markdown
-- declaration, classifies it by kind (workflow / tool / type-alias / prompt),
-- and assembles a 'Project' keyed by qualified name.
--
-- Classification is by explicit frontmatter @kind@ when present, else by the
-- top-level directory (@workflows/@, @tools/@, @types/@). Each file holds
-- exactly one declaration (§2); type-alias and prompt files must not contain
-- @step@ blocks.
module Hwfi.Parse.Project
  ( loadProject,
    parseDeclaration,
    qnameFromRelPath,
  )
where

import Control.Monad (forM)
import Data.Aeson (Object)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (QName (..), renderQName)
import Hwfi.Ast.Project
import Hwfi.Ast.Step (Statement)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Signature, Workflow (..))
import Hwfi.Parse.Frontmatter (frontmatterKind, frontmatterName, parseYamlObject, signatureFromYaml)
import Hwfi.Parse.Markdown (MarkdownFile (..), MdStepBlock (..), parseMarkdown)
import Hwfi.Parse.Section (buildSections)
import Hwfi.Parse.Step (parseStepBlock)
import Hwfi.Parse.TypeAlias (parseTypeAlias)
import Hwfi.Project.Manifest (ProjectManifest, loadManifest)
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
  case kindTag of
    CTypeAlias -> buildTypeAliasDecl relpath qname md
    CPrompt -> buildPromptDecl relpath qname md
    CWorkflow -> buildWorkflowDecl relpath qname md mObj
    CTool -> buildToolDecl relpath qname md mObj
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
  FilePath -> QName -> MarkdownFile -> Maybe (Text, Object) -> Either [Diagnostic] Declaration
buildToolDecl relpath qname md mObj = do
  (sig, stmts, sections) <- buildSignatureBody relpath qname md mObj
  Right (DeclTool (Tool qname sig stmts sections))

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

-- | Recursively find @.md@ files under @workflows/@, @tools/@, and @types/@,
-- returning paths relative to the project root.
findMarkdownFiles :: FilePath -> IO [FilePath]
findMarkdownFiles projectDir =
  concat <$> mapM walkTop ["workflows", "tools", "types"]
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
