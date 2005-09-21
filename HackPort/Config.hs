module Config where

import System.Console.GetOpt
import Control.Exception
import Error
import Verbosity

data HackPortOptions
	= TarCommand String
	| PortageTree String
	| Category String
	| Server String
	| TempDir String
	| Verify
	| Verbosity String

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
	, verbosity		::Verbosity
	}

defaultConfig :: Config
defaultConfig = Config
	{ tarCommand = "/bin/tar"
	, portageTree = Nothing
	, portageCategory = "dev-haskell"
	, server = "http://hackage.haskell.org/ModHackage/Hackage.hs?action=xmlrpc"
	, tmp = "/tmp"
	, verify = False
	, verbosity = Normal
	}

hackageOptions :: [OptDescr HackPortOptions]
hackageOptions = [Option ['p'] ["portage-tree"] (ReqArg PortageTree "PATH") "The portage tree to merge to"
	  ,Option ['c'] ["portage-category"] (ReqArg Category "CATEGORY") "The cateory the program belongs to"
	  ,Option ['s'] ["server"] (ReqArg Server "URL") "The Hackage server to query"
	  ,Option ['t'] ["temp-dir"] (ReqArg TempDir "PATH") "A temp directory where tarballs can be stored"
          ,Option [] ["tar"] (ReqArg TarCommand "PATH") "Path to the \"tar\" executable"
	  ,Option [] ["verify"] (NoArg Verify) "Verify downloaded tarballs using GnuPG"
	  ,Option ['v'] ["verbosity"] (ReqArg Verbosity "debug|normal|silent") "Set verbosity level(default is 'normal')"
	  ]

optionsToConfig :: Config -> [HackPortOptions] -> Config
optionsToConfig cfg [] = cfg
optionsToConfig cfg (x:xs) = optionsToConfig (case x of
	TarCommand str -> cfg { tarCommand = str }
	PortageTree str -> cfg { portageTree = Just str }
	Category str -> cfg { portageCategory = str }
	Server str -> cfg { server = str }
	TempDir str -> cfg { tmp = str }
	Verify -> cfg { verify = True }
	Verbosity str -> cfg { verbosity=maybe (throwDyn (UnknownVerbosityLevel str)) id (parseVerbosity str) }) xs

parseConfig :: [String] -> Either String (Config,OperationMode)
parseConfig opts = case getOpt Permute hackageOptions opts of
	(popts,"query":[],[]) -> Left "Need a package name to query.\n"
	(popts,"query":package:[],[]) -> Right (ropts popts,Query package)
	(popts,"query":package:rest,[]) -> Left ("'query' takes one argument("++show ((length rest)+1)++" given).\n")
	(popts,"merge":[],[]) -> Left "Need a package's name and version to merge it.\n"
	(popts,"merge":package:[],[]) -> Left ("Need version of '"++package++"' to merge. Find available versions using 'hackport query package-name.\n")
	(popts,"merge":package:version:[],[]) -> Right (ropts popts,Merge package version)
	(popts,"merge":_:_:rest,[]) -> Left ("'merge' takes 2 arguments("++show ((length rest)+2)++" given).\n")
	(popts,"list":[],[]) -> Right (ropts popts,ListAll)
	(popts,"list":rest,[]) -> Left ("'list' takes zero arguments("++show (length rest)++" given).\n")
	(popts,[],[]) -> Right (ropts popts,ShowHelp)
	(_,_,[]) -> Left "Unknown opertation mode\n"
	(_,_,errs) -> Left ("Error parsing flags:\n"++concat errs)
	where
	ropts op = optionsToConfig defaultConfig op

hackageUsage :: IO ()
hackageUsage = putStr (usageInfo "Usage:\t\"hackport [OPTION] MODE [MODETARGET]\"\n\t\"hackport [OPTION] list\" lists all available packages\n\t\"hackport [OPTION] query PKG\" shows all versions of a package\n\t\"hackport [OPTION] merge PKG VERSION\" merges a package into the portage tree\nOptions:" hackageOptions)

parseVerbosity :: String -> Maybe Verbosity
parseVerbosity "debug" = Just Debug
parseVerbosity "normal" = Just Normal
parseVerbosity "silent" = Just Silent
parseVerbosity _ = Nothing

