-- | The workspace abstraction (spec §7.1): a canonicalised root directory that
-- is the only filesystem area a workflow may read or write, with a
-- path-traversal guard applied to every 'FileRef' before use.
--
-- The root is canonicalised once at startup ('newWorkspace'). Every
-- workspace-relative path is then resolved /lexically/ (collapsing @.@ and
-- @..@) and rejected if it would escape the root (A5). Lexical resolution is
-- deliberate: it does not follow symlinks, so a relative path can never reach
-- outside the workspace even through a symlinked entry created during the run.
module Hwfi.Runtime.Workspace
  ( Workspace,
    workspaceRoot,
    newWorkspace,
    resolvePath,
    readTextFile,
    writeTextFile,
    listDir,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Hwfi.Runtime.Error (RuntimeError, ioError_, sandboxError)
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
  )
import System.FilePath (isAbsolute, joinPath, splitDirectories, takeDirectory, (</>))

-- | A canonicalised workspace root.
newtype Workspace = Workspace {workspaceRoot :: FilePath}

-- | Canonicalise the workspace root, creating it if absent. Done once at
-- startup (spec §7.1).
newWorkspace :: FilePath -> IO Workspace
newWorkspace dir = do
  createDirectoryIfMissing True dir
  Workspace <$> canonicalizePath dir

-- | Resolve a workspace-relative 'FileRef' to an absolute path, rejecting any
-- path that is absolute or escapes the root via @..@ (spec §7.1, A5).
resolvePath :: Workspace -> Text -> Either RuntimeError FilePath
resolvePath ws rel
  | isAbsolute relStr =
      Left (sandboxError ("absolute paths are not allowed inside the workspace: " <> rel))
  | otherwise = case resolveSegments (splitDirectories relStr) of
      Nothing ->
        Left (sandboxError ("path escapes the workspace root: " <> rel))
      Just segs -> Right (workspaceRoot ws </> joinPath segs)
  where
    relStr = T.unpack rel

-- | Collapse @.@\/@..@ segments, returning 'Nothing' if @..@ would rise above
-- the root.
resolveSegments :: [FilePath] -> Maybe [FilePath]
resolveSegments = go []
  where
    go acc [] = Just (reverse acc)
    go acc ("." : rest) = go acc rest
    go acc (".." : rest) = case acc of
      [] -> Nothing
      (_ : t) -> go t rest
    go acc (s : rest) = go (s : acc) rest

-- | Read a workspace file as UTF-8 text (spec §12: text-only in v1, invalid
-- UTF-8 is an error). Returns the decoded text and its byte size.
readTextFile :: Workspace -> Text -> IO (Either RuntimeError (Text, Int))
readTextFile ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    result <- try (BS.readFile path) :: IO (Either IOException ByteString)
    pure $ case result of
      Left ex -> Left (ioError_ ("read failed for '" <> rel <> "': " <> T.pack (show ex)))
      Right bytes -> case decodeUtf8' bytes of
        Left _ -> Left (ioError_ ("file '" <> rel <> "' is not valid UTF-8 (§12)"))
        Right txt -> Right (txt, BS.length bytes)

-- | Write UTF-8 text to a workspace file, creating parent directories inside
-- the workspace as needed. Returns the byte size written.
writeTextFile :: Workspace -> Text -> Text -> IO (Either RuntimeError Int)
writeTextFile ws rel content = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    result <- try (doWrite path) :: IO (Either IOException ())
    pure $ case result of
      Left ex -> Left (ioError_ ("write failed for '" <> rel <> "': " <> T.pack (show ex)))
      Right () -> Right (BS.length (encodeUtf8 content))
  where
    doWrite path = do
      createDirectoryIfMissing True (takeDirectory path)
      BS.writeFile path (encodeUtf8 content)

-- | List a workspace directory, returning entry names sorted lexicographically
-- (spec §6: @builtin/list-dir@).
listDir :: Workspace -> Text -> IO (Either RuntimeError [Text])
listDir ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    exists <- doesDirectoryExist path
    if not exists
      then pure (Left (ioError_ ("not a directory: '" <> rel <> "'")))
      else do
        result <- try (listDirectory path) :: IO (Either IOException [FilePath])
        pure $ case result of
          Left ex -> Left (ioError_ ("list failed for '" <> rel <> "': " <> T.pack (show ex)))
          Right entries -> Right (sort (map T.pack entries))
