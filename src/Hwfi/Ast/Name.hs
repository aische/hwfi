-- | Names shared across the AST: identifiers, qualified names, and heading
-- slugs. See spec §3.4 (grammar) and §3.2.
module Hwfi.Ast.Name
  ( Ident,
    QName (..),
    qnameSegments,
    qnameFromText,
    renderQName,
    isBareQName,
    Slug (..),
    renderSlug,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T

-- | An identifier, e.g. a binder or a field name. Lexically constrained by
-- the grammar (§3.4) at parse time; represented plainly here.
type Ident = Text

-- | A qualified name: either a multi-segment path to a declared
-- workflow/tool/type-alias (e.g. @builtin/read-file@, @types/message@) or a
-- single bare identifier that refers to a @ToolRef@/@WorkflowRef@ value in
-- scope (§3.4). Segments are stored without the separating slashes.
newtype QName = QName (NonEmpty Text)
  deriving stock (Eq, Ord, Show)

-- | The segments of a qualified name.
qnameSegments :: QName -> [Text]
qnameSegments (QName segs) = NE.toList segs

-- | Build a 'QName' from its slash-separated textual form. An empty string
-- yields a single empty segment; callers should validate lexically first.
qnameFromText :: Text -> QName
qnameFromText t =
  case T.splitOn "/" t of
    [] -> QName (T.empty :| [])
    (s : ss) -> QName (s :| ss)

-- | Render a 'QName' back to its slash-separated textual form.
renderQName :: QName -> Text
renderQName = T.intercalate "/" . qnameSegments

-- | A bare qname is a single-segment name (a first-class ref parameter),
-- as opposed to a declared multi-segment path.
isBareQName :: QName -> Bool
isBareQName (QName (_ :| rest)) = null rest

-- | A heading slug used by @\@self#slug@ references (§3.4). Stored verbatim;
-- matching is case-insensitive (see 'Hwfi.Parse.Section').
newtype Slug = Slug Text
  deriving stock (Eq, Ord, Show)

-- | The textual form of a slug.
renderSlug :: Slug -> Text
renderSlug (Slug t) = t
