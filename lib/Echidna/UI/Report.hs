module Echidna.UI.Report where

import Control.Monad.Reader (MonadReader, asks)
import Data.List (intercalate, nub, sortOn)
import Data.Map (toList)
import Data.Maybe (catMaybes)
import Data.Text (Text, unpack)
import Data.Text qualified as T

import Echidna.ABI (GenDict(..), encodeSig)
import Echidna.Events (Events)
import Echidna.Pretty (ppTxCall)
import Echidna.Types (Gas)
import Echidna.Types.Campaign
import Echidna.Types.Corpus (Corpus, corpusSize)
import Echidna.Types.Coverage (CoverageMap, scoveragePoints)
import Echidna.Types.Test (testEvents, testState, TestState(..), testType, TestType(..), testReproducer, testValue)
import Echidna.Types.Tx (Tx(..), TxCall(..), TxConf(..))
import Echidna.Types.Config

import EVM.Types (W256)

ppCampaign :: MonadReader EConfig m => Campaign -> m String
ppCampaign campaign = do
  testsPrinted <- ppTests campaign
  gasInfoPrinted <- ppGasInfo campaign
  let coveragePrinted = ppCoverage campaign._coverage
      corpusPrinted = "\n" <> ppCorpus campaign._corpus
      seedPrinted = "\nSeed: " <> show campaign._genDict.defSeed
  pure $
    testsPrinted
    <> gasInfoPrinted
    <> coveragePrinted
    <> corpusPrinted
    <> seedPrinted

-- | Given rules for pretty-printing associated address, and whether to print them, pretty-print a 'Transaction'.
ppTx :: MonadReader EConfig m => Bool -> Tx -> m String
ppTx _ Tx { call = NoCall, delay } =
  pure $ "*wait*" <> ppDelay delay
ppTx printName tx = do
  names <- asks (.namesConf)
  tGas  <- asks (.txConf.txGas)
  pure $
    ppTxCall tx.call
    <> (if not printName then "" else names Sender tx.src <> names Receiver tx.dst)
    <> (if tx.gas == tGas then "" else " Gas: " <> show tx.gas)
    <> (if tx.gasprice == 0 then "" else " Gas price: " <> show tx.gasprice)
    <> (if tx.value == 0 then "" else " Value: " <> show tx.value)
    <> ppDelay tx.delay

ppDelay :: (W256, W256) -> [Char]
ppDelay (time, block) =
  (if time == 0 then "" else " Time delay: " <> show (toInteger time) <> " seconds")
  <> (if block == 0 then "" else " Block delay: " <> show (toInteger block))

-- | Pretty-print the coverage a 'Campaign' has obtained.
ppCoverage :: CoverageMap -> String
ppCoverage s = "Unique instructions: " <> show (scoveragePoints s)
               <> "\nUnique codehashes: " <> show (length s)

-- | Pretty-print the corpus a 'Campaign' has obtained.
ppCorpus :: Corpus -> String
ppCorpus c = "Corpus size: " <> show (corpusSize c)

-- | Pretty-print the gas usage information a 'Campaign' has obtained.
ppGasInfo :: MonadReader EConfig m => Campaign -> m String
ppGasInfo Campaign { _gasInfo } | _gasInfo == mempty = pure ""
ppGasInfo Campaign { _gasInfo } = do
  items <- mapM ppGasOne $ sortOn (\(_, (n, _)) -> n) $ toList _gasInfo
  pure $ intercalate "" items

-- | Pretty-print the gas usage for a function.
ppGasOne :: MonadReader EConfig m => (Text, (Gas, [Tx])) -> m String
ppGasOne ("", _)      = pure ""
ppGasOne (func, (gas, txs)) = do
  let header = "\n" <> unpack func <> " used a maximum of " <> show gas <> " gas\n"
               <> "  Call sequence:\n"
  prettyTxs <- mapM (ppTx $ length (nub $ (.src) <$> txs) /= 1) txs
  pure $ header <> unlines (("    " <>) <$> prettyTxs)

-- | Pretty-print the status of a solved test.
ppFail :: MonadReader EConfig m => Maybe (Int, Int) -> Events -> [Tx] -> m String
ppFail _ _ []  = pure "failed with no transactions made ⁉️  "
ppFail b es xs = do
  let status = case b of
        Nothing    -> ""
        Just (n,m) -> ", shrinking " <> progress n m
  prettyTxs <- mapM (ppTx $ length (nub $ (.src) <$> xs) /= 1) xs
  pure $ "failed!💥  \n  Call sequence" <> status <> ":\n"
         <> unlines (("    " <>) <$> prettyTxs) <> "\n"
         <> ppEvents es

ppEvents :: Events -> String
ppEvents es = if null es then "" else "Event sequence: " <> T.unpack (T.intercalate ", " es)

-- | Pretty-print the status of a test.

ppTS :: MonadReader EConfig m => TestState -> Events -> [Tx] -> m String
ppTS (Failed e) _ _  = pure $ "could not evaluate ☣\n  " <> show e
ppTS Solved     es l = ppFail Nothing es l
ppTS Passed     _ _  = pure " passed! 🎉"
ppTS (Open i)   es [] = do
  t <- asks (.campaignConf.testLimit)
  if i >= t then ppTS Passed es [] else pure $ " fuzzing " <> progress i t
ppTS (Open _)   es r = ppFail Nothing es r
ppTS (Large n) es l  = do
  m <- asks (.campaignConf.shrinkLimit)
  ppFail (if n < m then Just (n, m) else Nothing) es l

ppOPT :: MonadReader EConfig m => TestState -> Events -> [Tx] -> m String
ppOPT (Failed e) _ _  = pure $ "could not evaluate ☣\n  " <> show e
ppOPT Solved     es l = ppOptimized Nothing es l
ppOPT Passed     _ _  = pure " passed! 🎉"
ppOPT (Open _)   es r = ppOptimized Nothing es r
ppOPT (Large n) es l  = do
  m <- asks (.campaignConf.shrinkLimit)
  ppOptimized (if n < m then Just (n, m) else Nothing) es l

-- | Pretty-print the status of a optimized test.
ppOptimized :: MonadReader EConfig m => Maybe (Int, Int) -> Events -> [Tx] -> m String
ppOptimized _ _ []  = pure "Call sequence:\n(no transactions)"
ppOptimized b es xs = do
  let status = case b of
        Nothing    -> ""
        Just (n,m) -> ", shrinking " <> progress n m
  prettyTxs <- mapM (ppTx $ length (nub $ (.src) <$> xs) /= 1) xs
  pure $ "\n  Call sequence" <> status <> ":\n"
         <> unlines (("    " <>) <$> prettyTxs) <> "\n"
         <> ppEvents es

-- | Pretty-print the status of all 'SolTest's in a 'Campaign'.
ppTests :: MonadReader EConfig m => Campaign -> m String
ppTests Campaign { _tests = ts } = unlines . catMaybes <$> mapM pp ts
  where
  pp t =
    case t.testType of
      PropertyTest n _ -> do
        status <- ppTS t.testState t.testEvents t.testReproducer
        pure $ Just (T.unpack n <> ": " <> status)
      CallTest n _ -> do
        status <- ppTS t.testState t.testEvents t.testReproducer
        pure $ Just (T.unpack n <> ": " <> status)
      AssertionTest _ s _ -> do
        status <- ppTS t.testState t.testEvents t.testReproducer
        pure $ Just (T.unpack (encodeSig s) <> ": " <> status)
      OptimizationTest n _ -> do
        status <- ppOPT t.testState t.testEvents t.testReproducer
        pure $ Just (T.unpack n <> ": max value: " <> show t.testValue <> "\n" <> status)
      Exploration -> pure Nothing

-- | Given a number of boxes checked and a number of total boxes, pretty-print progress in box-checking.
progress :: Int -> Int -> String
progress n m = "(" <> show n <> "/" <> show m <> ")"
