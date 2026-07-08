-- | The run-scoped LLM usage record persisted in @run.json@ (spec §8.4.4).
module Hwfi.Runtime.RunUsage
  ( RunUsage (..),
    emptyRunUsage,
    runUsageToJson,
    runUsageFromJson,
    usageRecordValue,
    formatCostUsd,
    renderUsageSummary,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Runtime.Value (RValue (..))
import Text.Printf (printf)

-- | Accumulated token and dollar totals for a logical run (§8.4.4).
data RunUsage = RunUsage
  { ruTokensIn :: !Int,
    ruTokensOut :: !Int,
    ruCostUsd :: !Double
  }
  deriving stock (Eq, Show)

emptyRunUsage :: RunUsage
emptyRunUsage = RunUsage 0 0 0

runUsageToJson :: RunUsage -> Value
runUsageToJson ru =
  object
    [ "tokens_in" .= ruTokensIn ru,
      "tokens_out" .= ruTokensOut ru,
      "cost_usd" .= ruCostUsd ru
    ]

runUsageFromJson :: Value -> Maybe RunUsage
runUsageFromJson = parseMaybe parseRunUsage

parseRunUsage :: Value -> Parser RunUsage
parseRunUsage = withObject "RunUsage" $ \o ->
  RunUsage <$> o .: "tokens_in" <*> o .: "tokens_out" <*> o .: "cost_usd"

-- | The @ctx.run.usage@ record value (spec §8.4.4).
usageRecordValue :: RunUsage -> RValue
usageRecordValue ru =
  VRecord $
    Map.fromList
      [ ("tokens_in", VInt (fromIntegral (ruTokensIn ru))),
        ("tokens_out", VInt (fromIntegral (ruTokensOut ru))),
        ("cost_usd", VDouble (ruCostUsd ru))
      ]

-- | Human-readable cost for @hwfi show@ (rounded to cents, spec §8.4.1).
formatCostUsd :: Double -> Text
formatCostUsd d = T.pack (printf "%.2f" d)

-- | Summary line appended after the trace in @hwfi show@ (spec §8.4.5).
renderUsageSummary :: RunUsage -> Text
renderUsageSummary ru =
  "usage: "
    <> T.pack (show (ruTokensIn ru))
    <> "/"
    <> T.pack (show (ruTokensOut ru))
    <> " tokens, $"
    <> formatCostUsd (ruCostUsd ru)
