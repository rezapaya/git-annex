{- A pool of "git-annex transferkeys" processes available for use
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Types.TransferrerPool where

import Common.Annex
import Utility.NotificationBroadcaster
import Assistant.Types.DaemonStatus

import Control.Concurrent.STM hiding (check)

{- This TMVar is never left empty. -}
type TransferrerPool = TMVar (MkCheckTransferrer, [TransferrerPoolItem])

type CheckTransferrer = IO Bool
type MkCheckTransferrer = IO (IO Bool)

{- Each item in the pool may have a transferrer running, and has an
 - IO action that can be used to check if it's still ok to use the
 - transferrer. -}
data TransferrerPoolItem = TransferrerPoolItem (Maybe Transferrer) CheckTransferrer

data Transferrer = Transferrer
	{ transferrerRead :: Handle
	, transferrerWrite :: Handle
	, transferrerHandle :: ProcessHandle
	}

newTransferrerPool :: MkCheckTransferrer -> IO TransferrerPool
newTransferrerPool c = newTMVarIO (c, [])

popTransferrerPool :: TransferrerPool -> STM (Maybe TransferrerPoolItem, Int)
popTransferrerPool p = do
	(c, l) <- takeTMVar p
	case l of
		[] -> do
			putTMVar p (c, [])
			return (Nothing, 0)
		(i:is) -> do
			putTMVar p (c, is)
			return $ (Just i, length is)

pushTransferrerPool :: TransferrerPool -> TransferrerPoolItem -> STM ()
pushTransferrerPool p i = do
	(c, l) <- takeTMVar p
	let l' = i:l
	putTMVar p (c, l')

{- Note that making a CheckTransferrer may allocate resources,
 - such as a NotificationHandle, so it's important that the returned
 - TransferrerPoolItem is pushed into the pool, and not left to be
 - garbage collected. -}
mkTransferrerPoolItem :: TransferrerPool -> Transferrer -> IO TransferrerPoolItem
mkTransferrerPoolItem p t = do
	mkcheck <- atomically $ fst <$> readTMVar p
	check <- mkcheck
	return $ TransferrerPoolItem (Just t) check

checkNetworkConnections :: DaemonStatusHandle -> MkCheckTransferrer
checkNetworkConnections dstatushandle = do
	dstatus <- atomically $ readTMVar dstatushandle
	h <- newNotificationHandle False (networkConnectedNotifier dstatus)
	return $ not <$> checkNotification h
