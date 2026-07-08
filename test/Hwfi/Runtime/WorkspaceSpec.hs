module Hwfi.Runtime.WorkspaceSpec (spec) where

import Control.Monad (void)
import Data.Either (isLeft, isRight)
import Hwfi.Runtime.Workspace
import System.Directory (createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Workspace sandbox (§7.1, A5)" $ do
  it "resolves an in-workspace relative path" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "sub/file.txt" `shouldSatisfy` isRight

  it "rejects an absolute path" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "/etc/passwd" `shouldSatisfy` isLeft

  it "rejects a traversal that escapes the root" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "../outside.txt" `shouldSatisfy` isLeft
      resolvePath ws "a/../../outside.txt" `shouldSatisfy` isLeft

  it "allows internal .. that stays within the root" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "a/b/../c.txt" `shouldSatisfy` isRight

  describe "symlink containment (§7.1 stage 2, H1.2)" $ do
    it "rejects read-file through a symlink that escapes the workspace" $
      withSystemTempDirectory "hwfi-ws" $ \dir -> do
        ws <- newWorkspace dir
        createFileLink "/etc/passwd" (dir </> "escape")
        r <- readTextFile ws "escape"
        r `shouldSatisfy` isLeft

    it "rejects write-file through a symlink that escapes the workspace" $
      withSystemTempDirectory "hwfi-ws" $ \dir -> do
        ws <- newWorkspace dir
        createFileLink "/etc/passwd" (dir </> "escape")
        w <- writeTextFile ws "escape" "nope"
        w `shouldSatisfy` isLeft

    it "allows read-file through an in-workspace symlink" $
      withSystemTempDirectory "hwfi-ws" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "real.txt" "secret"
        createFileLink (dir </> "real.txt") (dir </> "link.txt")
        r <- readTextFile ws "link.txt"
        r `shouldBe` Right ("secret", 6)

  it "round-trips write then read, reporting byte size" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      w <- writeTextFile ws "out/hello.txt" "hi"
      w `shouldBe` Right 2
      r <- readTextFile ws "out/hello.txt"
      r `shouldBe` Right ("hi", 2)

  it "refuses to write outside the workspace" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      w <- writeTextFile ws "../escape.txt" "nope"
      w `shouldSatisfy` isLeft

  it "lists directory entries sorted" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "d/b.txt" "b"
      _ <- writeTextFile ws "d/a.txt" "a"
      entries <- listDir ws "d"
      entries `shouldBe` Right ["a.txt", "b.txt"]

  navigationSpec
  mutationSpec

-- Navigation builtins (§6.2) -------------------------------------------------

navigationSpec :: Spec
navigationSpec = describe "Navigation (§6.2)" $ do
  it "read-file-slice returns a line window with next_offset and eof" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "f.txt" "l0\nl1\nl2\nl3\nl4"
      r1 <- readFileSlice ws "f.txt" 0 2
      r1 `shouldBe` Right ("l0\nl1", 2, False, 5)
      r2 <- readFileSlice ws "f.txt" 4 10
      r2 `shouldBe` Right ("l4", 5, True, 2)

  it "find-files matches a glob and returns workspace-relative paths sorted" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "src/Main.hs" "x"
      _ <- writeTextFile ws "src/sub/Util.hs" "y"
      _ <- writeTextFile ws "src/readme.md" "z"
      r <- findFiles ws "." "**/*.hs"
      r `shouldBe` Right ["src/Main.hs", "src/sub/Util.hs"]

  it "grep finds regex matches with file, 1-based line, and text" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "alpha\nbeta\ngamma"
      r <- grepFiles ws "^b" "a.txt"
      r `shouldBe` Right [("a.txt", 2, "beta")]

  it "grep reports a malformed pattern as an eval error" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "x"
      r <- grepFiles ws "a[" "a.txt"
      r `shouldSatisfy` isLeft

-- Mutation builtins (§6.2, A22, A23) -----------------------------------------

mutationSpec :: Spec
mutationSpec = describe "Mutation (§6.2)" $ do
  it "edit-file replaces every occurrence when expect matches" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "f.txt" "foo bar foo"
      r <- editFile ws "f.txt" "foo" "baz" 2
      fmap fst r `shouldBe` Right 2
      readTextFile ws "f.txt" `shouldReturn` Right ("baz bar baz", 11)

  it "edit-file fails and leaves the file unchanged when expect mismatches (A23)" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "f.txt" "foo bar foo"
      r <- editFile ws "f.txt" "foo" "baz" 1
      r `shouldSatisfy` isLeft
      readTextFile ws "f.txt" `shouldReturn` Right ("foo bar foo", 11)

  it "move-file relocates a file" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "hi"
      _ <- moveFile ws "a.txt" "b/c.txt"
      readTextFile ws "b/c.txt" `shouldReturn` Right ("hi", 2)

  it "copy-file duplicates a file" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "hi"
      _ <- copyFile ws "a.txt" "b.txt"
      readTextFile ws "a.txt" `shouldReturn` Right ("hi", 2)
      readTextFile ws "b.txt" `shouldReturn` Right ("hi", 2)

  it "make-dir then remove-dir removes recursively" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- makeDir ws "d/e"
      _ <- writeTextFile ws "d/e/f.txt" "x"
      rm <- removeDir ws "d"
      rm `shouldBe` Right ()
      gone <- readTextFile ws "d/e/f.txt"
      gone `shouldSatisfy` isLeft

  it "remove-file deletes a file" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "x"
      _ <- removeFile ws "a.txt"
      gone <- readTextFile ws "a.txt"
      gone `shouldSatisfy` isLeft

  it "confines mutations to the workspace: escaping paths fail (A22)" $
    withSystemTempDirectory "hwfi-ws" $ \dir -> do
      ws <- newWorkspace dir
      _ <- writeTextFile ws "a.txt" "x"
      e1 <- editFile ws "../escape.txt" "x" "y" 1
      e2 <- moveFile ws "a.txt" "../escape.txt"
      e3 <- removeFile ws "../escape.txt"
      e4 <- makeDir ws "../escape"
      e5 <- removeDir ws "../escape"
      mapM_ (`shouldSatisfy` isLeft) [void e1, e2, e3, e4, e5]
