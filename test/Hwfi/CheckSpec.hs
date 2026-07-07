module Hwfi.CheckSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Text (pack)
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Check.Error (TypeError (..), TypeErrorKind (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.TypedProject
import Hwfi.Type (Type (..))
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
          all (\s -> tsCalleeFingerprint s /= Nothing) steps `shouldBe` True
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

-- Helpers --------------------------------------------------------------------

declSteps :: String -> TypedProject -> [TypedStep]
declSteps name tp = maybe [] tdSteps (lookupTyped (qnameFromText (pack name)) tp)

declFingerprint :: String -> TypedProject -> Fingerprint
declFingerprint name tp = maybe (Fingerprint "") tdFingerprint (lookupTyped (qnameFromText (pack name)) tp)
