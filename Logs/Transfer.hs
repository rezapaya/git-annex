{- git-annex transfer information files and lock files
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Logs.Transfer where

import Common.Annex
import Annex.Perms
import Annex.Exception
import qualified Git
import Types.Key
import Utility.Metered
import Utility.Percentage
import Utility.QuickCheck
import Utility.PID
#ifdef mingw32_HOST_OS
import Utility.WinLock
#endif

import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Time
import System.Locale
import Control.Concurrent

{- Enough information to uniquely identify a transfer, used as the filename
 - of the transfer information file. -}
data Transfer = Transfer
	{ transferDirection :: Direction
	, transferUUID :: UUID
	, transferKey :: Key
	}
	deriving (Eq, Ord, Read, Show)

{- Information about a Transfer, stored in the transfer information file.
 -
 - Note that the associatedFile may not correspond to a file in the local
 - git repository. It's some file, possibly relative to some directory,
 - of some repository, that was acted on to initiate the transfer.
 -}
data TransferInfo = TransferInfo
	{ startedTime :: Maybe POSIXTime
	, transferPid :: Maybe PID
	, transferTid :: Maybe ThreadId
	, transferRemote :: Maybe Remote
	, bytesComplete :: Maybe Integer
	, associatedFile :: Maybe FilePath
	, transferPaused :: Bool
	}
	deriving (Show, Eq, Ord)

stubTransferInfo :: TransferInfo
stubTransferInfo = TransferInfo Nothing Nothing Nothing Nothing Nothing Nothing False

data Direction = Upload | Download
	deriving (Eq, Ord, Read, Show)

showLcDirection :: Direction -> String
showLcDirection Upload = "upload"
showLcDirection Download = "download"

readLcDirection :: String -> Maybe Direction
readLcDirection "upload" = Just Upload
readLcDirection "download" = Just Download
readLcDirection _ = Nothing

describeTransfer :: Transfer -> TransferInfo -> String
describeTransfer t info = unwords
	[ show $ transferDirection t
	, show $ transferUUID t
	, fromMaybe (key2file $ transferKey t) (associatedFile info)
	, show $ bytesComplete info
	]

{- Transfers that will accomplish the same task. -}
equivilantTransfer :: Transfer -> Transfer -> Bool
equivilantTransfer t1 t2
	| transferDirection t1 == Download && transferDirection t2 == Download &&
	  transferKey t1 == transferKey t2 = True
	| otherwise = t1 == t2

percentComplete :: Transfer -> TransferInfo -> Maybe Percentage
percentComplete (Transfer { transferKey = key }) info =
	percentage <$> keySize key <*> Just (fromMaybe 0 $ bytesComplete info)

type RetryDecider = TransferInfo -> TransferInfo -> Bool

noRetry :: RetryDecider
noRetry _ _ = False

{- Retries a transfer when it fails, as long as the failed transfer managed
 - to send some data. -}
forwardRetry :: RetryDecider
forwardRetry old new = bytesComplete old < bytesComplete new

upload :: UUID -> Key -> AssociatedFile -> RetryDecider -> (MeterUpdate -> Annex Bool) -> Annex Bool
upload u key = runTransfer (Transfer Upload u key)

download :: UUID -> Key -> AssociatedFile -> RetryDecider -> (MeterUpdate -> Annex Bool) -> Annex Bool
download u key = runTransfer (Transfer Download u key)

{- Runs a transfer action. Creates and locks the lock file while the
 - action is running, and stores info in the transfer information
 - file.
 -
 - If the transfer action returns False, the transfer info is 
 - left in the failedTransferDir.
 -
 - If the transfer is already in progress, returns False.
 -
 - An upload can be run from a read-only filesystem, and in this case
 - no transfer information or lock file is used.
 -}
runTransfer :: Transfer -> Maybe FilePath -> RetryDecider -> (MeterUpdate -> Annex Bool) -> Annex Bool
runTransfer t file shouldretry a = do
	info <- liftIO $ startTransferInfo file
	(meter, tfile, metervar) <- mkProgressUpdater t info
	mode <- annexFileMode
	(fd, inprogress) <- liftIO $ prep tfile mode info
	if inprogress
		then do
			showNote "transfer already in progress"
			return False
		else do
			ok <- retry info metervar $
		 		bracketIO (return fd) (cleanup tfile) (const $ a meter)
			unless ok $ recordFailedTransfer t info
			return ok
  where
#ifndef mingw32_HOST_OS
	prep tfile mode info = do
		mfd <- catchMaybeIO $
			openFd (transferLockFile tfile) ReadWrite (Just mode)
				defaultFileFlags { trunc = True }
		case mfd of
			Nothing -> return (Nothing, False)
			Just fd -> do
				locked <- catchMaybeIO $
					setLock fd (WriteLock, AbsoluteSeek, 0, 0)
				if isNothing locked
					then return (Nothing, True)
					else do
						void $ tryIO $ writeTransferInfoFile info tfile
						return (mfd, False)
#else
	prep tfile _mode info = do
		v <- catchMaybeIO $ lockExclusive (transferLockFile tfile)
		case v of
			Nothing -> return (Nothing, False)
			Just Nothing -> return (Nothing, True)
			Just (Just lockhandle) -> do
				void $ tryIO $ writeTransferInfoFile info tfile
				return (Just lockhandle, False)
#endif
	cleanup _ Nothing = noop
	cleanup tfile (Just lockhandle) = do
		void $ tryIO $ removeFile tfile
#ifndef mingw32_HOST_OS
		void $ tryIO $ removeFile $ transferLockFile tfile
		closeFd lockhandle
#else
		{- Windows cannot delete the lockfile until the lock
		 - is closed. So it's possible to race with another
		 - process that takes the lock before it's removed,
		 - so ignore failure to remove.
		 -}
		dropLock lockhandle
		void $ tryIO $ removeFile $ transferLockFile tfile
#endif
	retry oldinfo metervar run = do
		v <- tryAnnex run
		case v of
			Right b -> return b
			Left _ -> do
				b <- getbytescomplete metervar
				let newinfo = oldinfo { bytesComplete = Just b }
				if shouldretry oldinfo newinfo
					then retry newinfo metervar run
					else return False
	getbytescomplete metervar
		| transferDirection t == Upload =
			liftIO $ readMVar metervar
		| otherwise = do
			f <- fromRepo $ gitAnnexTmpObjectLocation (transferKey t)
			liftIO $ catchDefaultIO 0 $
				fromIntegral . fileSize <$> getFileStatus f

{- Generates a callback that can be called as transfer progresses to update
 - the transfer info file. Also returns the file it'll be updating, and a
 - MVar that can be used to read the number of bytesComplete. -}
mkProgressUpdater :: Transfer -> TransferInfo -> Annex (MeterUpdate, FilePath, MVar Integer)
mkProgressUpdater t info = do
	tfile <- fromRepo $ transferFile t
	_ <- tryAnnex $ createAnnexDirectory $ takeDirectory tfile
	mvar <- liftIO $ newMVar 0
	return (liftIO . updater tfile mvar, tfile, mvar)
  where
	updater tfile mvar b = modifyMVar_ mvar $ \oldbytes -> do
		let newbytes = fromBytesProcessed b
		if newbytes - oldbytes >= mindelta
			then do
				let info' = info { bytesComplete = Just newbytes }
				_ <- tryIO $ writeTransferInfoFile info' tfile
				return newbytes
			else return oldbytes
	{- The minimum change in bytesComplete that is worth
	 - updating a transfer info file for is 1% of the total
	 - keySize, rounded down. -}
	mindelta = case keySize (transferKey t) of
		Just sz -> sz `div` 100
		Nothing -> 100 * 1024 -- arbitrarily, 100 kb

startTransferInfo :: Maybe FilePath -> IO TransferInfo
startTransferInfo file = TransferInfo
	<$> (Just . utcTimeToPOSIXSeconds <$> getCurrentTime)
#ifndef mingw32_HOST_OS
	<*> pure Nothing -- pid not stored in file, so omitted for speed
#else
	<*> (Just <$> getPID)
#endif
	<*> pure Nothing -- tid ditto
	<*> pure Nothing -- not 0; transfer may be resuming
	<*> pure Nothing
	<*> pure file
	<*> pure False

{- If a transfer is still running, returns its TransferInfo. -}
checkTransfer :: Transfer -> Annex (Maybe TransferInfo)
checkTransfer t = do
	tfile <- fromRepo $ transferFile t
#ifndef mingw32_HOST_OS
	mode <- annexFileMode
	mfd <- liftIO $ catchMaybeIO $
		openFd (transferLockFile tfile) ReadOnly (Just mode) defaultFileFlags
	case mfd of
		Nothing -> return Nothing -- failed to open file; not running
		Just fd -> do
			locked <- liftIO $
				getLock fd (WriteLock, AbsoluteSeek, 0, 0)
			liftIO $ closeFd fd
			case locked of
				Nothing -> return Nothing
				Just (pid, _) -> liftIO $ catchDefaultIO Nothing $
					readTransferInfoFile (Just pid) tfile
#else
	v <- liftIO $ lockShared $ transferLockFile tfile
	liftIO $ case v of
		Nothing -> catchDefaultIO Nothing $
			readTransferInfoFile Nothing tfile
		Just lockhandle -> do
			dropLock lockhandle
			void $ tryIO $ removeFile $ transferLockFile tfile
			return Nothing
#endif

{- Gets all currently running transfers. -}
getTransfers :: Annex [(Transfer, TransferInfo)]
getTransfers = do
	transfers <- mapMaybe parseTransferFile . concat <$> findfiles
	infos <- mapM checkTransfer transfers
	return $ map (\(t, Just i) -> (t, i)) $
		filter running $ zip transfers infos
  where
	findfiles = liftIO . mapM dirContentsRecursive
		=<< mapM (fromRepo . transferDir) [Download, Upload]
	running (_, i) = isJust i

{- Gets failed transfers for a given remote UUID. -}
getFailedTransfers :: UUID -> Annex [(Transfer, TransferInfo)]
getFailedTransfers u = catMaybes <$> (liftIO . getpairs =<< concat <$> findfiles)
  where
	getpairs = mapM $ \f -> do
		let mt = parseTransferFile f
		mi <- readTransferInfoFile Nothing f
		return $ case (mt, mi) of
			(Just t, Just i) -> Just (t, i)
			_ -> Nothing
	findfiles = liftIO . mapM dirContentsRecursive
		=<< mapM (fromRepo . failedTransferDir u) [Download, Upload]

clearFailedTransfers :: UUID -> Annex [(Transfer, TransferInfo)]
clearFailedTransfers u = do
	failed <- getFailedTransfers u
	mapM_ (removeFailedTransfer . fst) failed
	return failed

removeFailedTransfer :: Transfer -> Annex ()
removeFailedTransfer t = do
	f <- fromRepo $ failedTransferFile t
	liftIO $ void $ tryIO $ removeFile f

recordFailedTransfer :: Transfer -> TransferInfo -> Annex ()
recordFailedTransfer t info = do
	failedtfile <- fromRepo $ failedTransferFile t
	createAnnexDirectory $ takeDirectory failedtfile
	liftIO $ writeTransferInfoFile info failedtfile

{- The transfer information file to use for a given Transfer. -}
transferFile :: Transfer -> Git.Repo -> FilePath
transferFile (Transfer direction u key) r = transferDir direction r
	</> filter (/= '/') (fromUUID u)
	</> keyFile key

{- The transfer information file to use to record a failed Transfer -}
failedTransferFile :: Transfer -> Git.Repo -> FilePath
failedTransferFile (Transfer direction u key) r = failedTransferDir u direction r
	</> keyFile key

{- The transfer lock file corresponding to a given transfer info file. -}
transferLockFile :: FilePath -> FilePath
transferLockFile infofile = let (d,f) = splitFileName infofile in
	combine d ("lck." ++ f)

{- Parses a transfer information filename to a Transfer. -}
parseTransferFile :: FilePath -> Maybe Transfer
parseTransferFile file
	| "lck." `isPrefixOf` takeFileName file = Nothing
	| otherwise = case drop (length bits - 3) bits of
		[direction, u, key] -> Transfer
			<$> readLcDirection direction
			<*> pure (toUUID u)
			<*> fileKey key
		_ -> Nothing
  where
	bits = splitDirectories file

writeTransferInfoFile :: TransferInfo -> FilePath -> IO ()
writeTransferInfoFile info tfile = writeFileAnyEncoding tfile $
	writeTransferInfo info

{- File format is a header line containing the startedTime and any
 - bytesComplete value. Followed by a newline and the associatedFile.
 -
 - On unix, the transferPid is not included; instead it is obtained
 - by looking at the process that locks the file.
 -
 - On windows, the transferPid is included, as a second line.
 -}
writeTransferInfo :: TransferInfo -> String
writeTransferInfo info = unlines
	[ (maybe "" show $ startedTime info) ++
	  (maybe "" (\b -> ' ' : show b) (bytesComplete info))
#ifdef mingw32_HOST_OS
	, maybe "" show (transferPid info)
#endif
	, fromMaybe "" $ associatedFile info -- comes last; arbitrary content
	]

readTransferInfoFile :: Maybe PID -> FilePath -> IO (Maybe TransferInfo)
readTransferInfoFile mpid tfile = catchDefaultIO Nothing $
	readTransferInfo mpid <$> readFileStrictAnyEncoding tfile

readTransferInfo :: Maybe PID -> String -> Maybe TransferInfo
readTransferInfo mpid s = TransferInfo
	<$> time
#ifdef mingw32_HOST_OS
	<*> pure (if isJust mpid then mpid else mpid')
#else
	<*> pure mpid
#endif
	<*> pure Nothing
	<*> pure Nothing
	<*> bytes
	<*> pure (if null filename then Nothing else Just filename)
	<*> pure False
  where
#ifdef mingw32_HOST_OS
	(firstline, otherlines) = separate (== '\n') s
	(secondline, rest) = separate (== '\n') otherlines
	mpid' = readish secondline
#else
	(firstline, rest) = separate (== '\n') s
#endif
	filename
		| end rest == "\n" = beginning rest
		| otherwise = rest
	bits = split " " firstline
	numbits = length bits
	time = if numbits > 0
		then Just <$> parsePOSIXTime =<< headMaybe bits
		else pure Nothing -- not failure
	bytes = if numbits > 1
		then Just <$> readish =<< headMaybe (drop 1 bits)
		else pure Nothing -- not failure

parsePOSIXTime :: String -> Maybe POSIXTime
parsePOSIXTime s = utcTimeToPOSIXSeconds
	<$> parseTime defaultTimeLocale "%s%Qs" s

{- The directory holding transfer information files for a given Direction. -}
transferDir :: Direction -> Git.Repo -> FilePath
transferDir direction r = gitAnnexTransferDir r </> showLcDirection direction

{- The directory holding failed transfer information files for a given
 - Direction and UUID -}
failedTransferDir :: UUID -> Direction -> Git.Repo -> FilePath
failedTransferDir u direction r = gitAnnexTransferDir r
	</> "failed"
	</> showLcDirection direction
	</> filter (/= '/') (fromUUID u)

instance Arbitrary TransferInfo where
	arbitrary = TransferInfo
		<$> arbitrary
		<*> arbitrary
		<*> pure Nothing -- cannot generate a ThreadID
		<*> pure Nothing -- remote not needed
		<*> arbitrary
		-- associated file cannot be empty (but can be Nothing)
		<*> arbitrary `suchThat` (/= Just "")
		<*> arbitrary

prop_read_write_transferinfo :: TransferInfo -> Bool
prop_read_write_transferinfo info
	| isJust (transferRemote info) = True -- remote not stored
	| isJust (transferTid info) = True -- tid not stored
	| otherwise = Just (info { transferPaused = False }) == info'
  where
	info' = readTransferInfo (transferPid info) (writeTransferInfo info)

