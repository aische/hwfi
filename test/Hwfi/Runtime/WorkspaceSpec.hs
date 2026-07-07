module Hwfi.Runtime.WorkspaceSpec (spec) where

import Data.Either (isLeft, isRight)
import Hwfi.Runtime.Workspace
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
