module Hwfi.Check.GraphSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Hwfi.Ast.Expr (Expr (..), StringPart (..))
import Hwfi.Ast.Name (QName, qnameFromText)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step (Arg (..), Binder (..), Statement (..), StepStmt (..))
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Signature (..), Workflow (..))
import Hwfi.Check.Graph (computeFingerprints)
import Hwfi.Source (Pos (..), Span (..))
import Hwfi.TypedProject (Fingerprint, ResolvedSignature (..))
import Test.Hspec

-- | A dummy source span; fingerprints must ignore it.
sp :: Span
sp = Span (Pos 1 1) (Pos 1 1)

qn :: String -> QName
qn = qnameFromText . T.pack

lit :: String -> Expr
lit s = EString [SLit (T.pack s)]

-- | A tool that returns a single field with a literal value.
mkTool :: String -> String -> Declaration
mkTool name value =
  DeclTool (Tool (qn name) (Signature [] [] []) [SReturn [Arg "res" (lit value) sp] sp] [])

-- | A workflow that calls the given tool once.
mkCaller :: String -> String -> Declaration
mkCaller name callee =
  DeclWorkflow
    ( Workflow
        (qn name)
        (Signature [] [] [])
        [SStep (StepStmt (BindName "x") (qn callee) [] "x" sp)]
        []
    )

emptySig :: ResolvedSignature
emptySig = ResolvedSignature [] [] []

fingerprints :: Map QName Declaration -> Map QName Fingerprint
fingerprints decls = computeFingerprints decls (Map.map (const emptySig) decls)

spec :: Spec
spec = describe "computeFingerprints — Merkle over the call graph (§8.1, A13)" $ do
  let mk toolValue =
        Map.fromList
          [ (qn "tools/t", mkTool "tools/t" toolValue),
            (qn "workflows/w", mkCaller "workflows/w" "tools/t"),
            (qn "tools/u", mkTool "tools/u" "unrelated")
          ]
      fpsA = fingerprints (mk "A")
      fpsB = fingerprints (mk "B")

  it "changes a callee's fingerprint when its body changes" $
    Map.lookup (qn "tools/t") fpsA `shouldNotBe` Map.lookup (qn "tools/t") fpsB

  it "propagates a callee change to the caller's fingerprint" $
    Map.lookup (qn "workflows/w") fpsA `shouldNotBe` Map.lookup (qn "workflows/w") fpsB

  it "leaves an unrelated declaration's fingerprint unchanged" $
    Map.lookup (qn "tools/u") fpsA `shouldBe` Map.lookup (qn "tools/u") fpsB

  it "is deterministic" $
    fingerprints (mk "A") `shouldBe` fpsA
