-- | Navigate the checked AST by 'StmtPath' (v2 runtime).
module Hwfi.Runtime.MachinePath
  ( StmtContext (..),
    resolveStmtPath,
    statementAt,
    advancePath,
    initialStmtPath,
    declStatements,
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (QName, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
  ( IfStmt (..),
    LoopStmt (..),
    Statement (..),
    TryStmt (..),
    WhileBody (..),
    WhileStmt (..),
  )
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Workflow (..))
import Hwfi.Runtime.Machine (BlockKind (..), PathSegment (..), StmtPath (..))
import Hwfi.TypedProject (TypedDecl (..), TypedProject (..), lookupTyped)

-- | Resolved view of a path: the statement list, index, and focused statement.
data StmtContext = StmtContext
  { scStmts :: [Statement],
    scIndex :: Int,
    scStmt :: Statement
  }
  deriving stock (Eq, Show)

-- | Statements of an executable declaration.
declStatements :: Declaration -> [Statement]
declStatements = \case
  DeclWorkflow w -> wfStatements w
  DeclTool t -> toolStatements t
  _ -> []

-- | Build the entry path for a workflow (first statement).
initialStmtPath :: TypedProject -> QName -> Either Text StmtPath
initialStmtPath tp q = do
  _ <- workflowStmts tp q
  pure (StmtPath q [PathSegment 0 Nothing])

-- | Resolve a path to the statement list, index, and statement at that index.
resolveStmtPath :: TypedProject -> StmtPath -> Either Text StmtContext
resolveStmtPath tp (StmtPath q segs) = do
  stmts <- workflowStmts tp q
  case segs of
    [] -> Left "empty stmt path"
    _ -> go stmts segs

workflowStmts :: TypedProject -> QName -> Either Text [Statement]
workflowStmts tp q = case lookupTyped q tp of
  Nothing -> Left ("unknown declaration: " <> renderQName q)
  Just td ->
    let stmts = declStatements (tdDeclaration td)
     in if null stmts
          then Left ("empty body: " <> renderQName q)
          else Right stmts

go :: [Statement] -> [PathSegment] -> Either Text StmtContext
go stmts [PathSegment idx Nothing] = do
  stmt <- statementAt stmts idx
  pure (StmtContext stmts idx stmt)
go stmts (PathSegment idx (Just bk) : rest) = do
  stmt <- statementAt stmts idx
  child <- childBlock stmt bk
  go child rest
go _ [] = Left "path missing terminal segment"

-- | Map a block kind to the child statement list of a control-flow statement.
childBlock :: Statement -> BlockKind -> Either Text [Statement]
childBlock stmt bk = case stmt of
  SIf s -> case bk of
    BkIfThen -> Right (ifThen s)
    BkIfElse -> maybe (Left "if has no else branch") Right (ifElse s)
  SLoop s -> case bk of
    BkLoopBody -> Right (loopBody s)
    _ -> Left "invalid block kind for loop"
  SWhile s -> case (bk, whileBody s) of
    (BkWhileInline, WhileBodyInline body) -> Right body
    _ -> Left "invalid block kind for while"
  STry s -> case bk of
    BkTryTry -> Right (tryTry s)
    BkTryCatch -> Right (tryCatch s)
  _ -> Left "statement has no child block for this path segment"

statementAt :: [Statement] -> Int -> Either Text Statement
statementAt xs i
  | i < 0 = Left "negative statement index"
  | i >= length xs = Left "statement index out of range"
  | otherwise = Right (xs !! i)

-- | Advance to the next sibling statement at the current path depth.
advancePath :: StmtPath -> StmtPath
advancePath (StmtPath q segs) =
  case reverse segs of
    (PathSegment i m) : rest ->
      StmtPath q (reverse rest ++ [PathSegment (i + 1) m])
    [] -> StmtPath q [PathSegment 1 Nothing]
