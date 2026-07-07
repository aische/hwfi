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
    readFileSlice,
    findFiles,
    grepFiles,
    editFile,
    moveFile,
    copyFile,
    removeFile,
    makeDir,
    removeDir,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Hwfi.Runtime.Error (RuntimeError, evalError, ioError_, sandboxError)
import Hwfi.Runtime.Glob (matchGlob, splitGlob)
import System.Directory
  ( canonicalizePath,
    copyFileWithMetadata,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    listDirectory,
    pathIsSymbolicLink,
    removeDirectoryRecursive,
    removePathForcibly,
    renamePath,
  )
import System.FilePath (isAbsolute, joinPath, makeRelative, splitDirectories, takeDirectory, (</>))
import Text.Regex.TDFA (Regex, defaultCompOpt, defaultExecOpt, matchTest)
import Text.Regex.TDFA.String (compile)

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

-- Navigation (§6.2) ----------------------------------------------------------

-- | Files larger than this are skipped by 'grepFiles' and rejected by
-- 'readTextFile'-style reads (they are almost always generated artifacts).
maxFileSizeBytes :: Integer
maxFileSizeBytes = 1024 * 1024

-- | Bytes sniffed for a NUL byte to classify a file as binary (v1 is
-- text-only, §12). Matches the heuristic @git@\/@grep@ use.
binarySniffBytes :: Int
binarySniffBytes = 8000

-- | Maximum directory depth walked by 'findFiles'\/'grepFiles' from the search
-- root, a guard against pathological trees.
maxWalkDepth :: Int
maxWalkDepth = 100

-- | Read a line window of a workspace file (spec §6.2, @builtin/read-file-slice@).
-- Returns @limit@ lines starting at 0-based line @offset@, the @next_offset@ to
-- continue from, whether end-of-file was reached, and the byte size of the
-- returned slice. Invalid UTF-8 fails as an @io@ error, consistent with
-- 'readTextFile' (§12).
readFileSlice :: Workspace -> Text -> Int -> Int -> IO (Either RuntimeError (Text, Int, Bool, Int))
readFileSlice ws rel offset limit = do
  r <- readTextFile ws rel
  pure $ case r of
    Left e -> Left e
    Right (text, _) ->
      let allLines = T.lines text
          total = length allLines
          off = max 0 offset
          lim = max 0 limit
          window = take lim (drop off allLines)
          nextOffset = off + length window
          eof = nextOffset >= total
          slice = T.intercalate "\n" window
       in Right (slice, nextOffset, eof, BS.length (encodeUtf8 slice))

-- | List workspace files\/directories under @path@ matching a glob (spec §6.2,
-- @builtin/find-files@). Matching is against paths relative to @path@; results
-- are workspace-relative and sorted. Symlinks and hidden entries are skipped.
findFiles :: Workspace -> Text -> Text -> IO (Either RuntimeError [Text])
findFiles ws rel glob = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right root -> do
    isDir <- doesDirectoryExist root
    if not isDir
      then pure (Left (ioError_ ("not a directory: '" <> rel <> "'")))
      else do
        entries <- walkEntries root
        let globSegs = splitGlob glob
            matched =
              [ T.pack (makeRelative (workspaceRoot ws) full)
              | (segs, full, _) <- entries,
                matchGlob globSegs segs
              ]
        pure (Right (sort matched))

-- | Regex-search workspace files under @path@ (spec §6.2, @builtin/grep@). A
-- malformed pattern is an @eval@ error. @path@ may be a single file or a
-- directory (walked recursively). Binary and oversize files are skipped.
-- Returns @(workspace-relative file, 1-based line, matching line text)@.
grepFiles :: Workspace -> Text -> Text -> IO (Either RuntimeError [(Text, Int, Text)])
grepFiles ws pattern rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right root -> case compile defaultCompOpt defaultExecOpt (T.unpack pattern) of
    Left err -> pure (Left (evalError ("invalid grep pattern: " <> T.pack err)))
    Right regex -> do
      isDir <- doesDirectoryExist root
      isFile <- doesFileExist root
      if not (isDir || isFile)
        then pure (Left (ioError_ ("path does not exist: '" <> rel <> "'")))
        else do
          files <-
            if isFile
              then pure [root]
              else map (\(_, f, _) -> f) . filter (\(_, _, d) -> not d) <$> walkEntries root
          matches <- concat <$> traverse (grepOne ws regex) (sort files)
          pure (Right matches)

grepOne :: Workspace -> Regex -> FilePath -> IO [(Text, Int, Text)]
grepOne ws regex full = do
  bin <- isBinaryOrBig full
  if bin
    then pure []
    else do
      r <- try (BS.readFile full) :: IO (Either IOException ByteString)
      pure $ case r of
        Left _ -> []
        Right bytes -> case decodeUtf8' bytes of
          Left _ -> []
          Right content ->
            let relPath = T.pack (makeRelative (workspaceRoot ws) full)
             in [ (relPath, n, line)
                | (n, line) <- zip [1 ..] (T.lines content),
                  matchTest regex (T.unpack line)
                ]

-- Mutation (§6.2) ------------------------------------------------------------

-- | Literal (non-regex) whole-string replacement (spec §6.2, @builtin/edit-file@).
-- Replaces every non-overlapping occurrence of @find_@ with @replace_@; the
-- @expect@ count (≥ 0) must equal the actual number of occurrences or the step
-- fails with an @eval@ error and the file is left unchanged (A23). Returns the
-- number of replacements and the byte size written.
editFile :: Workspace -> Text -> Text -> Text -> Int -> IO (Either RuntimeError (Int, Int))
editFile ws rel find_ replace_ expect
  | T.null find_ = pure (Left (evalError "edit-file 'find' must be a non-empty string"))
  | otherwise = do
      r <- readTextFile ws rel
      case r of
        Left e -> pure (Left e)
        Right (text, _) -> do
          let n = T.count find_ text
          if n /= expect
            then
              pure . Left . evalError $
                "edit-file expected "
                  <> T.pack (show expect)
                  <> " occurrence(s) of the target but found "
                  <> T.pack (show n)
                  <> " (§6.2); file left unchanged"
            else do
              let newText = T.replace find_ replace_ text
              w <- writeTextFile ws rel newText
              pure (fmap (n,) w)

-- | Move\/rename a workspace file or directory (spec §6.2, @builtin/move-file@).
moveFile :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
moveFile = mutate2 renamePath "move"

-- | Copy a workspace file (spec §6.2, @builtin/copy-file@).
copyFile :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
copyFile = mutate2 copyFileWithMetadata "copy"

-- | Remove a workspace file (spec §6.2, @builtin/remove-file@).
removeFile :: Workspace -> Text -> IO (Either RuntimeError ())
removeFile ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> guardIo ("remove failed for '" <> rel <> "'") (removePathForcibly path)

-- | Create a workspace directory and any missing parents (spec §6.2,
-- @builtin/make-dir@).
makeDir :: Workspace -> Text -> IO (Either RuntimeError ())
makeDir ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> guardIo ("make-dir failed for '" <> rel <> "'") (createDirectoryIfMissing True path)

-- | Remove a workspace directory and its contents recursively (spec §6.2,
-- @builtin/remove-dir@), confined to the workspace.
removeDir :: Workspace -> Text -> IO (Either RuntimeError ())
removeDir ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    isDir <- doesDirectoryExist path
    if not isDir
      then pure (Left (ioError_ ("not a directory: '" <> rel <> "'")))
      else guardIo ("remove-dir failed for '" <> rel <> "'") (removeDirectoryRecursive path)

-- | Resolve both endpoints of a two-path mutation (move\/copy) and run it,
-- creating the destination's parent directory inside the workspace.
mutate2 ::
  (FilePath -> FilePath -> IO ()) ->
  Text ->
  Workspace ->
  Text ->
  Text ->
  IO (Either RuntimeError ())
mutate2 act label ws from to = case (,) <$> resolvePath ws from <*> resolvePath ws to of
  Left e -> pure (Left e)
  Right (fromPath, toPath) ->
    guardIo
      (label <> " failed for '" <> from <> "' -> '" <> to <> "'")
      (createDirectoryIfMissing True (takeDirectory toPath) >> act fromPath toPath)

-- | Run an effectful mutation, mapping any 'IOException' to an @io@ error.
guardIo :: Text -> IO () -> IO (Either RuntimeError ())
guardIo msg act = do
  r <- try act :: IO (Either IOException ())
  pure $ case r of
    Left ex -> Left (ioError_ (msg <> ": " <> T.pack (show ex)))
    Right () -> Right ()

-- Directory walk (shared by find\/grep) --------------------------------------

-- | Recursively enumerate entries under a search root, skipping symlinks and
-- hidden (dot-prefixed) entries. Each entry is @(segments-relative-to-root,
-- absolute-path, is-directory)@. Directories are yielded and descended.
walkEntries :: FilePath -> IO [([Text], FilePath, Bool)]
walkEntries searchRoot = go 0 [] searchRoot
  where
    go depth relSegs dir
      | depth > maxWalkDepth = pure []
      | otherwise = do
          names <- sort <$> safeList dir
          foldM (visit depth relSegs dir) [] (filter (not . hidden) names)
    visit depth relSegs dir acc name = do
      let full = dir </> name
          segs = relSegs <> [T.pack name]
      isLink <- pathIsSymbolicLink full
      if isLink
        then pure acc
        else do
          isDir <- doesDirectoryExist full
          if isDir
            then do
              sub <- go (depth + 1) segs full
              pure (acc <> [(segs, full, True)] <> sub)
            else pure (acc <> [(segs, full, False)])
    hidden ('.' : _) = True
    hidden _ = False

safeList :: FilePath -> IO [FilePath]
safeList path = do
  r <- try (listDirectory path) :: IO (Either IOException [FilePath])
  pure (either (const []) id r)

-- | Whether a file should be skipped by 'grepFiles': too large, or binary
-- (a NUL byte in the first 'binarySniffBytes').
isBinaryOrBig :: FilePath -> IO Bool
isBinaryOrBig path = do
  szR <- try (getFileSize path) :: IO (Either IOException Integer)
  case szR of
    Left _ -> pure True
    Right sz
      | sz > maxFileSizeBytes -> pure True
      | otherwise -> do
          sniff <- try (BS.take binarySniffBytes <$> BS.readFile path) :: IO (Either IOException ByteString)
          pure (either (const True) (BS.elem 0) sniff)
