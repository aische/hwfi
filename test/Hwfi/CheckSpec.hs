module Hwfi.CheckSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (pack)
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Check.Error (TypeError (..), TypeErrorKind (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Type (Type (..))
import Hwfi.TypedProject
import Test.Hspec

-- | Parse a fixture project and run the pure checker over it.
checkFixture :: FilePath -> IO (Either [TypeError] TypedProject)
checkFixture name = do
  eproj <- loadProject ("test/fixtures/check/" <> name)
  either (\ds -> error ("fixture failed to parse: " <> show ds)) (pure . checkProject) eproj

errKinds :: Either [TypeError] TypedProject -> [TypeErrorKind]
errKinds = either (map errKind) (const [])

spec :: Spec
spec = do
  describe "checkProject — accepting a well-formed project (A1)" $ do
    it "accepts the ok fixture" $ do
      res <- checkFixture "ok"
      res `shouldSatisfy` isRight

    it "resolves a shared type alias in a signature (A10)" $ do
      res <- checkFixture "ok"
      case res of
        Right tp ->
          Map.lookup (qnameFromText "types/message") (tpAliases tp)
            `shouldBe` Just (TyRecord [("role", TyString), ("content", TyString)])
        Left errs -> expectationFailure (show errs)

    it "classifies ordinary steps as cacheable and assigns fingerprints" $ do
      res <- checkFixture "ok"
      case res of
        Right tp -> do
          let steps = declSteps "workflows/main" tp
          length steps `shouldBe` 3
          map tsCacheable steps `shouldBe` [True, True, True]
          -- Every step target here is statically known, so has a fingerprint.
          all (isJust . tsCalleeFingerprint) steps `shouldBe` True
          declFingerprint "workflows/main" tp `shouldNotBe` Fingerprint ""
        Left errs -> expectationFailure (show errs)

    it "marks introspect and volatile-ctx steps non-cacheable (§8.1)" $ do
      res <- checkFixture "noncacheable"
      case res of
        Right tp ->
          map tsCacheable (declSteps "workflows/main" tp) `shouldBe` [False, False]
        Left errs -> expectationFailure (show errs)

  describe "checkProject — rejecting ill-formed projects (A2)" $ do
    it "rejects an undeclared reference" $ do
      res <- checkFixture "undeclared-ref"
      errKinds res `shouldContain` [UndeclaredRef]

    it "rejects a type mismatch" $ do
      res <- checkFixture "type-mismatch"
      errKinds res `shouldContain` [TypeMismatch]

    it "rejects an undeclared call target" $ do
      res <- checkFixture "undeclared-target"
      errKinds res `shouldContain` [UndeclaredTarget]

    it "rejects interpolating a Secret<_> env value (§5.5, A8)" $ do
      res <- checkFixture "secret-interp"
      errKinds res `shouldContain` [SecretInterp]

    it "rejects a missing @self#slug (§5.6.4, A9)" $ do
      res <- checkFixture "self-missing"
      errKinds res `shouldContain` [SelfNotFound]

    it "rejects a workflow that needs an explicit return (§5.6.5)" $ do
      res <- checkFixture "return-rule"
      errKinds res `shouldContain` [ReturnRule]

    it "rejects a cyclic type alias (§2.1, A10)" $ do
      res <- checkFixture "alias-cycle"
      errKinds res `shouldContain` [CyclicAlias]

    it "rejects an import cycle in the call graph (§5.6.6, A2)" $ do
      res <- checkFixture "import-cycle"
      errKinds res `shouldContain` [ImportCycle]

    it "rejects a duplicate bind name (§3.4)" $ do
      res <- checkFixture "dup-bind"
      errKinds res `shouldContain` [DuplicateBind]

    it "enforces a sub-workflow's signature at the call site (A6)" $ do
      res <- checkFixture "subworkflow-bad"
      errKinds res `shouldContain` [TypeMismatch]

  describe "checkProject — agent builtins (§6.1, A18)" $ do
    it "accepts an agent advertising eligible tools" $ do
      res <- checkFixture "agent-ok"
      res `shouldSatisfy` isRight

    it "classifies an agent step as non-cacheable (§8.1)" $ do
      res <- checkFixture "agent-ok"
      case res of
        Right tp -> map tsCacheable (declSteps "workflows/main" tp) `shouldBe` [False]
        Left errs -> expectationFailure (show errs)

    it "rejects advertising a tool with a Secret<_> input (§6.1.1)" $ do
      res <- checkFixture "agent-secret-tool"
      errKinds res `shouldContain` [ArgMismatch]

    it "rejects advertising an introspect-reaching workflow (§6.1.5)" $ do
      res <- checkFixture "agent-introspect-tool"
      errKinds res `shouldContain` [ArgMismatch]

    it "accepts an agent advertising mutation and exec tools (§7.5)" $ do
      res <- checkFixture "agent-coding-tools"
      res `shouldSatisfy` isRight

    it "A50: accepts a runtime-built tools list with a check warning (§6.1.6)" $ do
      res <- checkFixture "agent-runtime-tools"
      res `shouldSatisfy` isRight
      case res of
        Right tp -> length (tpWarnings tp) `shouldBe` 1
        Left errs -> expectationFailure (show errs)

  describe "checkProject — exec policy (§7.5, A24)" $ do
    it "accepts a builtin/exec call whose literal program is allowlisted" $ do
      res <- checkFixture "exec-ok"
      res `shouldSatisfy` isRight

    it "rejects a builtin/exec call whose literal program is not allowlisted" $ do
      res <- checkFixture "exec-not-allowed"
      errKinds res `shouldContain` [ExecPolicyViolation]

    it "rejects a builtin/exec call when no exec policy is configured" $ do
      res <- checkFixture "exec-no-policy"
      errKinds res `shouldContain` [ExecPolicyViolation]

-- Helpers --------------------------------------------------------------------

declSteps :: String -> TypedProject -> [TypedStep]
declSteps name tp = maybe [] tdSteps (lookupTyped (qnameFromText (pack name)) tp)

declFingerprint :: String -> TypedProject -> Fingerprint
declFingerprint name tp = maybe (Fingerprint "") tdFingerprint (lookupTyped (qnameFromText (pack name)) tp)
