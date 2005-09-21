module Main where

import System.Console.GetOpt
import System.Environment
import System.Exit
import Distribution.Package
import Data.Version
import Control.Exception
import Data.Typeable
import Error
import Query
import GenerateEbuild
import Cabal2Ebuild
import Bash

data HackPortOptions
	= TarCommand String
	| PortageTree String
	| Category String
	| Server String
	| TempDir String
	| Verify

data OperationMode
	= Query String
	| Merge String String
	| ListAll
	| ShowHelp

data Config = Config
	{ tarCommand		::String
	, portageTree		::Maybe String
	, portageCategory	::String
	, server		::String
	, tmp			::String
	, verify		::Bool
	}

defaultConfig :: Config
defaultConfig = Config
	{ tarCommand = "/bin/tar"
	, portageTree = Nothing
	, portageCategory = "dev-haskell"
	, server = "http://hackage.haskell.org/ModHackage/Hackage.hs?action=xmlrpc"
	, tmp = "/tmp"
	, verify = False
	}

options :: [OptDescr HackPortOptions]
options = [Option ['p'] ["portage-tree"] (ReqArg PortageTree "PATH") "The portage tree to merge to"
	  ,Option ['c'] ["portage-category"] (ReqArg Category "CATEGORY") "The cateory the program belongs to"
	  ,Option ['s'] ["server"] (ReqArg Server "URL") "The Hackage server to query"
	  ,Option ['t'] ["temp-dir"] (ReqArg TempDir "PATH") "A temp directory where tarballs can be stored"
          ,Option [] ["tar"] (ReqArg TarCommand "PATH") "Path to the \"tar\" executable"
	  ,Option [] ["verify"] (NoArg Verify) "Verify downloaded tarballs using GnuPG"
	  ]

optionsToConfig :: Config -> [HackPortOptions] -> Config
optionsToConfig cfg [] = cfg
optionsToConfig cfg (x:xs) = optionsToConfig (case x of
	TarCommand str -> cfg { tarCommand = str }
	PortageTree str -> cfg { portageTree = Just str }
	Category str -> cfg { portageCategory = str }
	Server str -> cfg { server = str }
	TempDir str -> cfg { tmp = str }
	Verify -> cfg { verify = True }) xs

parseConfig :: [String] -> Either String (Config,OperationMode)
parseConfig opts = case getOpt Permute options opts of
	(popts,"query":package:[],[]) -> Right (ropts popts,Query package)
	(popts,"merge":package:version:[],[]) -> Right (ropts popts,Merge package version)
	(popts,"list":[],[]) -> Right (ropts popts,ListAll)
	(popts,[],[]) -> Right (ropts popts,ShowHelp)
	(_,_,[]) -> Left "Unknown opertation mode\n"
	(_,_,errs) -> Left ("Error parsing flags:\n"++concat errs)
	where
	ropts op = optionsToConfig defaultConfig op

listAll :: Config -> IO ()
listAll cfg = do
	pkgs <- getPackages (server cfg)
	putStr (unlines pkgs)

usage :: IO ()
usage = putStr (usageInfo "Usage:\t\"hackport [OPTION] MODE [MODETARGET]\"\n\t\"hackport [OPTION] list\" lists all available packages\n\t\"hackport [OPTION] query PKG\" shows all versions of a package\n\t\"hackport [OPTION] merge PKG VERSION\" merges a package into the portage tree\nOptions:" options)

query :: Config -> String -> IO ()
query cfg name = do
	pkgvers <- getPackageVersions (server cfg) name
	putStr (unlines (map showVersion pkgvers))

merge :: Config -> String -> String -> IO ()
merge cfg name vers = do
	portTree <- case portageTree cfg of
		Nothing -> getOverlay
		Just tree -> return tree
	case parseVersion' vers of
		Nothing -> putStr ("Error: couldn't parse version number '"++vers++"'\n")
		Just realvers -> do
			ebuild <- hackage2ebuild (tarCommand cfg) (server cfg) (tmp cfg) (verify cfg) (PackageIdentifier {pkgName=name,pkgVersion=realvers})
			mergeEbuild portTree (portageCategory cfg) ebuild

main :: IO ()
main = do
	args <- getArgs
	case parseConfig args of
		Left err -> do
			putStr err
			exitWith (ExitFailure 1)
		Right (config,mode) -> (case mode of
			ShowHelp -> usage
			ListAll -> listAll config
			Query pkg -> query config pkg
			Merge pkg vers -> merge config pkg vers) `catchDyn` (\x->putStr ((hackPortShowError (server config) Nothing x)++"\n"))
