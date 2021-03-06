{-# LANGUAGE CPP #-}
import Control.Shell
import Data.Bits
import System.Info (os)
import Control.Monad
import System.Environment (getArgs)
import System.Exit

inBuildDir :: [String] -> Shell a -> Shell a
inBuildDir args act = do
  srcdir <- pwd
  isdir <- isDirectory "_build"
  when (isdir && not ("no-rebuild" `elem` args)) $ rmdir "_build"
  mkdir True "_build"
  inDirectory "_build" $ do
    unless ("no-rebuild" `elem` args) $ run_ "git" ["clone", srcdir] ""
    inDirectory "haste-compiler" act

-- Packages will end up in ghc-$GHC_MAJOR.$GHC_MINOR. If the directory does
-- not exist, it is created. If the package already exists in that directory,
-- it is overwritten.
main = do
    args <- fixAllArg `fmap` getArgs
    when (null args) $ do
      putStrLn $ "Usage: runghc build-release.hs [no-rebuild|in-place] formats\n"
      putStrLn $ "Supported formats: deb, tarball, 7z, all\n"
      putStrLn $ "no-rebuild\n  Repackage whatever is already in the " ++
                 "_build directory\n  instead of rebuilding from scratch."
      putStrLn $ "in-place\n  Build package in current directory.\n" ++
                 "  Packages end up in ghc-$GHC_MAJOR.$GHC_MINOR."
      exitFailure

    when ("--debghcdeps" `elem` args) $ do
      putStr "ghc"
      exitSuccess

    let inplace = "in-place" `elem` args
        chdir = if inplace then id else inBuildDir args

    res <- shell $ do
      chdir $ do
        (ver, ghcver) <- if ("no-rebuild" `elem` args)
                           then do
                             getVersions
                           else do
                             vers <- buildPortable
                             bootPortable
                             return vers

        let (major, '.':rest) = break (== '.') ghcver
            (minor, _) = break (== '.') rest
            outdir
              | inplace   = "ghc-" ++ major ++ "." ++ minor
              | otherwise = ".." </> ".." </> ("ghc-" ++ major ++ "." ++ minor)
        mkdir True outdir

        when ("tarball" `elem` args) $ do
          tar <- buildBinaryTarball ver ghcver
          mv tar (outdir </> tar)

        when ("7z" `elem` args) $ do
          f <- buildBinary7z ver ghcver
          mv f (outdir </> f)

        when ("deb" `elem` args) $ do
          deb <- buildDebianPackage ver ghcver
          mv (".." </> deb) (outdir </> deb)

    case res of
      Left err -> error $ "FAILED: " ++ err
      _        -> return ()
  where
    fixAllArg args | "all" `elem` args = "deb" : "tarball" : "7z" : args
                   | otherwise         = args

buildPortable = do
    -- Build compiler
    run_ "cabal" ["configure", "-f", "portable", "-f", "static"] ""
    run_ "cabal" ["haddock"] ""
    run_ "dist/setup/setup" ["build"] ""

    -- Copy docs
    cpDir "dist/doc/html/haste-compiler" "haste-compiler/docs"

    -- Strip symbols
    case os of
      "mingw32" -> do
        -- windows
        run_ "strip" ["-s", "haste-compiler\\bin\\haste-pkg.exe"] ""
        run_ "strip" ["-s", "haste-compiler\\bin\\hastec.exe"] ""
        run_ "strip" ["-s", "haste-compiler\\bin\\haste-cat.exe"] ""
      "linux" -> do
        -- linux
        run_ "strip" ["-s", "haste-compiler/bin/haste-pkg"] ""
        run_ "strip" ["-s", "haste-compiler/bin/hastec"] ""
        run_ "strip" ["-s", "haste-compiler/bin/haste-cat"] ""
      _ -> do
        -- darwin
        run_ "strip" ["haste-compiler/bin/haste-pkg"] ""
        run_ "strip" ["haste-compiler/bin/hastec"] ""
        run_ "strip" ["haste-compiler/bin/haste-cat"] ""

    -- Get versions
    getVersions

getVersions = do
    ver <- fmap init $ run "haste-compiler/bin/hastec" ["--version"] ""
    ghcver <- fmap init $ run "ghc" ["--numeric-version"] ""
    return (ver, ghcver)

bootPortable = do
    -- Build libs
    run_ "haste-compiler/bin/haste-boot" ["--force", "--initial"] ""

    -- Remove unnecessary binaries
    case os of
      "mingw32" -> do
        -- windows
        rm "haste-compiler\\bin\\haste-boot.exe"
        rm "haste-compiler\\bin\\haste-copy-pkg.exe"
        rm "haste-compiler\\bin\\haste-install-his.exe"
      _ -> do
        -- linux/darwin
        rm "haste-compiler/bin/haste-boot"
        rm "haste-compiler/bin/haste-copy-pkg"
        rm "haste-compiler/bin/haste-install-his"
    forEachFile "haste-compiler" $ \f -> do
      when ((f `hasExt` ".o") || (f `hasExt` ".a")) $ rm f
  where
    f `hasExt` e = takeExtension f == e

buildBinaryTarball ver ghcver = do
    -- Get versions and create binary tarball
    run_ "tar" ["-cjf", tarball, "haste-compiler"] ""
    return tarball
  where
    tarball =
      concat ["haste-compiler-",ver,"_ghc-",ghcver,"-",os,".tar.bz2"]

buildBinary7z ver ghcver = do
    -- Get versions and create binary tarball
    run_ "7z" ["a", "-i!haste-compiler", name] ""
    return $ name
  where
    name =
      concat ["haste-compiler-",ver,"_ghc-",ghcver,"-",os,".7z"]

arch :: String
arch = "amd64" -- only amd64 supported

-- Debian packaging based on https://wiki.debian.org/IntroDebianPackaging.
-- Requires build-essential, devscripts and debhelper.
buildDebianPackage ver ghcver = do
  run_ "debuild" ["-e", "LD_LIBRARY_PATH=haste-compiler/haste-cabal",
                  "-us", "-uc", "-b"] ""
  return $ "haste-compiler_" ++ ver ++ "_" ++ arch ++ ".deb"
