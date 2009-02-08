module Diff
    ( runDiff
    , DiffMode(..)
    ) where

import Control.Monad ( forM_, mplus )
import Data.Char
import qualified Data.Map as Map
import Network.URI
import Control.Exception ( assert )
import Data.Maybe ( fromJust, listToMaybe )
import Data.List ( sort, sortBy, groupBy )
import Data.Ord ( comparing )

import qualified Portage.Version as Portage
import qualified Portage.Overlay as Portage
import qualified Portage.Cabal as Portage
import qualified Portage.PackageId as Portage

import qualified Data.Version as Cabal

-- cabal
import Distribution.Verbosity
import Distribution.Text(display)
import qualified Distribution.Package as Cabal
import qualified Distribution.Simple.PackageIndex as Cabal
import qualified Distribution.InstalledPackageInfo as Cabal
import Distribution.Simple.Utils (equating)

-- cabal-install
import qualified Distribution.Client.IndexUtils as Index (getAvailablePackages )
import qualified Distribution.Client.Types as Cabal
import Distribution.Client.Utils (mergeBy, MergeResult(..))

data DiffMode
	= ShowAll
	| ShowMissing
	| ShowAdditions
	| ShowNewer
	| ShowCommon
        | ShowPackages [String]
	deriving Eq

type DiffState a = MergeResult a a

tabs :: String -> String
tabs str = let len = length str in str++(if len < 3*8
	then replicate (3*8-len) ' '
	else "")

showDiffState :: Cabal.PackageName -> DiffState Portage.Version -> String
showDiffState pkg st = (tabs (display pkg)) ++ " [" ++ (case st of
  InBoth x y -> display x ++ (case compare x y of
    EQ -> "="
    GT -> ">"
    LT -> "<") ++ display y
  OnlyInLeft x -> display x ++ ">none"
  OnlyInRight y -> "none<" ++ display y) ++ "]"

runDiff :: Verbosity -> FilePath -> DiffMode -> Cabal.Repo -> IO ()
runDiff verbosity overlayPath dm repo = do
  -- get package list from hackage
  pkgDB <- Index.getAvailablePackages verbosity [ repo ]
  let (Cabal.AvailablePackageDb hackageIndex _) = pkgDB

  -- get package list from the overlay
  overlay0 <- (Portage.loadLazy overlayPath)
  let overlayIndex = Portage.fromOverlay (Portage.reduceOverlay overlay0)

  let (subHackage, subOverlay)
        = case dm of
            ShowPackages pkgs ->
              (concatMap (Cabal.searchByNameSubstring hackageIndex) pkgs
              ,concatMap (Cabal.searchByNameSubstring overlayIndex) pkgs)
            _ ->
              (Cabal.allPackages hackageIndex
              ,Cabal.allPackages overlayIndex)
  diff subHackage subOverlay dm

data PackageCompareInfo = PackageCompareInfo {
    name :: Cabal.PackageName,
--    hackageVersions :: [ Cabal.Version ],
--    overlayVersions :: [ Cabal.Version ]
    hackageVersion :: Maybe Cabal.Version,
    overlayVersion :: Maybe Cabal.Version
  } deriving Show

showPackageCompareInfo :: PackageCompareInfo -> String
showPackageCompareInfo pkgCmpInfo =
    display (name pkgCmpInfo) ++ " ["
    ++ hackageS ++ sign ++ overlayS ++ "]" 
  where
  overlay = overlayVersion pkgCmpInfo
  hackage = hackageVersion pkgCmpInfo
  hackageS = maybe "none" display hackage
  overlayS = maybe "none" display overlay
  sign = case compare hackage overlay of
          EQ -> "="
          GT -> ">"
          LT -> "<"

diff :: [Cabal.AvailablePackage]
     -> [Portage.ExistingEbuild]
     -> DiffMode
     -> IO ()
diff hackage overlay dm = do
  mapM_ (putStrLn . showPackageCompareInfo) pkgCmpInfos
  where
  merged = mergePackages (map (Portage.normalizeCabalPackageId . Cabal.packageId) hackage)
                         (map Portage.ebuildCabalId overlay)
  pkgCmpInfos = filter pkgFilter (map (uncurry mergePackageInfo) merged)
  pkgFilter :: PackageCompareInfo -> Bool
  pkgFilter pkgCmpInfo =
    let om = overlayVersion pkgCmpInfo
        hm = hackageVersion pkgCmpInfo
        st = case (om,hm) of
              (Just ov, Just hv) -> InBoth ov hv
              (Nothing, Just hv) -> OnlyInRight hv
              (Just ov, Nothing) -> OnlyInLeft ov
    in
    case dm of
      ShowAll -> True
      ShowPackages _ -> True -- already filtered
      ShowNewer -> case st of
                     InBoth o h -> h>o
                     _ -> False
      ShowMissing -> case st of
                      OnlyInRight _ -> True
                      InBoth x y -> x < y
                      OnlyInLeft _ -> False
      _ -> True
 
-- | We get the 'PackageCompareInfo' by combining the info for the overlay
-- and hackage versions of a package.
--
-- * We're building info about a various versions of a single named package so
-- the input package info records are all supposed to refer to the same
-- package name.
--
mergePackageInfo :: [Cabal.PackageIdentifier]
                 -> [Cabal.PackageIdentifier]
                 -> PackageCompareInfo
mergePackageInfo hackage overlay =
  assert (length overlay + length hackage > 0) $
  PackageCompareInfo {
    name              = combine Cabal.pkgName latestHackage
                                Cabal.pkgName latestOverlay,
--    hackageVersions = map Cabal.pkgVersion hackage,
--    overlayVersions = map Cabal.pkgVersion overlay
    hackageVersion = fmap Cabal.pkgVersion latestHackage,
    overlayVersion = fmap Cabal.pkgVersion latestOverlay
  }
  where
    combine f x g y = fromJust (fmap f x `mplus` fmap g y)
    latestHackage = latestOf hackage
    latestOverlay = latestOf overlay
    latestOf :: [Cabal.PackageIdentifier] -> Maybe Cabal.PackageIdentifier
    latestOf = listToMaybe . reverse . sortBy (comparing Cabal.pkgVersion)

-- | Rearrange installed and available packages into groups referring to the
-- same package by name. In the result pairs, the lists are guaranteed to not
-- both be empty.
--
mergePackages :: [Cabal.PackageIdentifier] -> [Cabal.PackageIdentifier]
              -> [([Cabal.PackageIdentifier], [Cabal.PackageIdentifier])]
mergePackages hackage overlay =
    map collect
  $ mergeBy (\i a -> fst i `compare` fst a)
            (groupOn Cabal.pkgName hackage)
            (groupOn Cabal.pkgName overlay)
  where
    collect (OnlyInLeft  (_,is)       ) = (is, [])
    collect (    InBoth  (_,is) (_,as)) = (is, as)
    collect (OnlyInRight        (_,as)) = ([], as)

groupOn :: Ord key => (a -> key) -> [a] -> [(key,[a])]
groupOn key = map (\xs -> (key (head xs), xs))
            . groupBy (equating key)
            . sortBy (comparing key)
{-
diff :: Portage -> Portage -> DiffMode -> IO ()
diff pt1 pt2 mode = do
  let pkgs1 = Map.map (OnlyLeft  . eVersion . maximum) pt1
  let pkgs2 = Map.map (OnlyRight . eVersion . maximum) pt2
  let union = Map.unionWith (\(OnlyLeft x) (OnlyRight y) -> Both x y) pkgs1 pkgs2
  let showFilter st = case mode of
          ShowAll -> True
          ShowMissing -> case st of
                  OnlyLeft _ -> True
                  Both x y -> x > y
                  OnlyRight _ -> False
          ShowAdditions -> case st of
                  OnlyLeft _ -> False
                  Both x y -> x < y
                  OnlyRight _ -> True
          ShowNewer -> case st of
                  OnlyLeft _ -> False
                  Both x y -> x > y
                  OnlyRight _ -> False
          ShowCommon -> case st of
                  OnlyLeft _ -> False
                  Both x y -> x == y
                  OnlyRight _ -> False
          ShowPackages _ -> True
  let packages = filter (showFilter . snd) (Map.assocs union)
  mapM_ (putStrLn . uncurry showDiffState) packages
-}
