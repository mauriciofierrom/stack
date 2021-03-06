{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
module Pantry.TypesSpec (spec) where

import Test.Hspec
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Pantry
import qualified Pantry.SHA256 as SHA256
import Pantry.Internal (parseTree, renderTree, Tree (..), TreeEntry (..), mkSafeFilePath)
import RIO
import Distribution.Types.Version (mkVersion)
import qualified RIO.Text as T
import qualified Data.Yaml as Yaml
import Data.Aeson.Extended (WithJSONWarnings (..))
import qualified Data.ByteString.Char8 as S8
import RIO.Time (Day (..))

hh :: HasCallStack => String -> Property -> Spec
hh name p = it name $ do
  result <- check p
  unless result $ throwString "Hedgehog property failed" :: IO ()

genBlobKey :: Gen BlobKey
genBlobKey = BlobKey <$> genSha256 <*> (FileSize <$> (Gen.word (Range.linear 1 10000)))

genSha256 :: Gen SHA256
genSha256 = SHA256.hashBytes <$> Gen.bytes (Range.linear 1 500)

spec :: Spec
spec = do
  describe "WantedCompiler" $ do
    hh "parse/render works" $ property $ do
      wc <- forAll $
        let ghc = WCGhc <$> genVersion
            ghcjs = WCGhcjs <$> genVersion <*> genVersion
            genVersion = mkVersion <$> Gen.list (Range.linear 1 5) (Gen.int (Range.linear 0 100))
         in Gen.choice [ghc, ghcjs]
      let text = utf8BuilderToText $ display wc
      case parseWantedCompiler text of
        Left e -> throwIO e
        Right actual -> liftIO $ actual `shouldBe` wc

  describe "Tree" $ do
    hh "parse/render works" $ property $ do
      tree <- forAll $
        let sfp = do
              pieces <- Gen.list (Range.linear 1 10) sfpComponent
              let combined = T.intercalate "/" pieces
              case mkSafeFilePath combined of
                Nothing -> error $ "Incorrect SafeFilePath in test suite: " ++ show pieces
                Just sfp' -> pure sfp'
            sfpComponent = Gen.text (Range.linear 1 15) Gen.alphaNum
            entry = TreeEntry
              <$> genBlobKey
              <*> Gen.choice (map pure [minBound..maxBound])
         in TreeMap <$> Gen.map (Range.linear 1 20) ((,) <$> sfp <*> entry)
      let bs = renderTree tree
      liftIO $ parseTree bs `shouldBe` Just tree

  describe "(Raw)SnapshotLayer" $ do
    let parseSl :: String -> IO RawSnapshotLayer
        parseSl str = case Yaml.decodeThrow . S8.pack $ str of
          (Just (WithJSONWarnings x _)) -> resolvePaths Nothing x
          Nothing -> fail "Can't parse RawSnapshotLayer"

    it "parses snapshot using 'resolver'" $ do
      RawSnapshotLayer{..} <- parseSl $
        "name: 'test'\n" ++
        "resolver: lts-2.10\n"
      rslParent `shouldBe` ltsSnapshotLocation 2 10

    it "parses snapshot using 'snapshot'" $ do
      RawSnapshotLayer{..} <- parseSl $
        "name: 'test'\n" ++
        "snapshot: lts-2.10\n"
      rslParent `shouldBe` ltsSnapshotLocation 2 10

    it "throws if both 'resolver' and 'snapshot' are present" $ do
      let go = parseSl $
                "name: 'test'\n" ++
                "resolver: lts-2.10\n" ++
                "snapshot: lts-2.10\n"
      go `shouldThrow` anyException

    it "throws if both 'snapshot' and 'compiler' are not present" $ do
      let go = parseSl "name: 'test'\n"
      go `shouldThrow` anyException

    it "works if no 'snapshot' specified" $ do
      RawSnapshotLayer{..} <- parseSl $
        "name: 'test'\n" ++
        "compiler: ghc-8.0.1\n"
      rslParent `shouldBe` RSLCompiler (WCGhc (mkVersion [8, 0, 1]))

    hh "rendering an LTS gives a nice name" $ property $ do
      (major, minor) <- forAll $ (,)
        <$> Gen.integral (Range.linear 1 10000)
        <*> Gen.integral (Range.linear 1 10000)
      liftIO $
        Yaml.toJSON (ltsSnapshotLocation major minor) `shouldBe`
        Yaml.String (T.pack $ concat ["lts-", show major, ".", show minor])

    hh "rendering a nightly gives a nice name" $ property $ do
      days <- forAll $ Gen.integral $ Range.linear 1 10000000
      let day = ModifiedJulianDay days
      liftIO $
        Yaml.toJSON (nightlySnapshotLocation day) `shouldBe`
        Yaml.String (T.pack $ "nightly-" ++ show day)
