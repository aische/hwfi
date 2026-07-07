module Hwfi.Parse.ExprSpec (spec) where

import Data.Text (Text)
import Hwfi.Ast.Expr
import Hwfi.Ast.Name (Slug (..), qnameFromText)
import Hwfi.Parse.Expr (expr)
import Hwfi.Parse.Lexer (runParserAt, scn)
import Hwfi.Source (Pos (..))
import Test.Hspec
import Text.Megaparsec (eof, errorBundlePretty)

parseE :: Text -> Either String Expr
parseE t = either (Left . errorBundlePretty) Right (runParserAt (scn *> expr <* eof) "e" (Pos 1 1) t)

spec :: Spec
spec = describe "expression parser (spec §3.2, §3.4)" $ do
  it "splits interpolated strings into literal and reference parts" $
    parseE "\"hi ${name}!\""
      `shouldBe` Right (EString [SLit "hi ", SInterp (RefPath "name" []), SLit "!"])

  it "treats a whole ${...} as a bare reference with accessors" $
    parseE "${a.b[0]}"
      `shouldBe` Right (ERef (RefPath "a" [AField "b", AIndex 0]))

  it "parses lists" $
    parseE "[1, 2, 3]" `shouldBe` Right (EList [EInt 1, EInt 2, EInt 3])

  it "parses records with '=' and keyword literals" $
    parseE "{ x = true, y = null }"
      `shouldBe` Right (ERecord [("x", EBool True), ("y", ENull)])

  it "distinguishes doubles from ints" $ do
    parseE "42" `shouldBe` Right (EInt 42)
    parseE "1.5e2" `shouldBe` Right (EDouble 150.0)
    parseE "-3" `shouldBe` Right (EInt (-3))

  it "parses bare qnames" $
    parseE "builtin/read-file" `shouldBe` Right (EQName (qnameFromText "builtin/read-file"))

  it "parses @self# references" $
    parseE "@self#system" `shouldBe` Right (ESelf (Slug "system"))

  it "decodes escapes and honours triple-quoted strings" $ do
    parseE "\"a\\nb\"" `shouldBe` Right (EString [SLit "a\nb"])
    parseE "\"\"\"a \"quoted\" b\"\"\"" `shouldBe` Right (EString [SLit "a \"quoted\" b"])
