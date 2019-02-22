-- | Deal with pending transactions
module Cardano.Wallet.Kernel.Pending (
    newPending
  , newForeign
  , cancelPending
  , NewPendingError
  , PartialTxMeta
  ) where

import           Universum hiding (State)

import           Control.Concurrent.MVar (modifyMVar_)
import           Data.Acid.Advanced (update')
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import           Formatting (build, sformat)

import           Cardano.Wallet.Kernel.DB.AcidState (CancelPending (..),
                     NewForeign (..), NewForeignError (..), NewPending (..),
                     NewPendingError (..))
import           Cardano.Wallet.Kernel.DB.HdRootId (HdRootId)
import           Cardano.Wallet.Kernel.DB.HdWallet
import           Cardano.Wallet.Kernel.DB.InDb
import qualified Cardano.Wallet.Kernel.DB.Spec.Pending as Pending
import           Cardano.Wallet.Kernel.DB.TxMeta (TxMeta, putTxMeta)
import           Cardano.Wallet.Kernel.Internal
import           Cardano.Wallet.Kernel.Read (getEncryptedSecretKeys,
                     getWalletSnapshot)
import           Cardano.Wallet.Kernel.Submission (Cancelled, addPending)
import           Cardano.Wallet.Kernel.Util.Core
import           Pos.Chain.Txp (Tx (..), TxAux (..), TxOut (..))
import           Pos.Core (Coin (..))
import           Pos.Crypto (EncryptedSecretKey)

{-------------------------------------------------------------------------------
  Submit pending transactions
-------------------------------------------------------------------------------}

-- | When we create a new Transaction, we don`t yet know which outputs belong to us
-- (it may not be just the change addresses change we create, but also addresses the user specifies).
-- This check happenes in @newTx@. Until then we move around this partial TxMetadata.
-- @Bool@ indicates if all outputs are ours and @Coin@ the sum of the coin of our outputs.
type PartialTxMeta = Bool -> Coin -> TxMeta

-- | Submit a new pending transaction
--
-- If the pending transaction is successfully added to the wallet state, the
-- submission layer is notified accordingly.
--
-- NOTE: we select "our" output addresses from the transaction and pass it along to the data layer
newPending :: ActiveWallet
           -> HdAccountId
           -> TxAux
           -> PartialTxMeta
           -> IO (Either NewPendingError TxMeta)
newPending w accountId tx partialMeta = do
    newTx w accountId tx partialMeta $ \ourAddrs ->
        update' ((walletPassive w) ^. wallets) $ NewPending accountId (InDb tx) ourAddrs

-- | Submit new foreign transaction
--
-- A foreign transaction is a transaction that transfers funds from /another/
-- wallet to this one.
newForeign :: ActiveWallet
           -> HdAccountId
           -> TxAux
           -> TxMeta
           -> IO (Either NewForeignError ())
newForeign w accountId tx meta = do
    map void <$> newTx w accountId tx (\_ _ ->  meta) $ \ourAddrs ->
        update' ((walletPassive w) ^. wallets) $ NewForeign accountId (InDb tx) ourAddrs

-- | Submit a new transaction
--
-- Will fail if the HdAccountId does not exist or if some inputs of the
-- new transaction are not available for spending.
--
-- If the transaction is successfully added to the wallet state, transaction metadata
-- is persisted and the submission layer is notified accordingly.
--
-- NOTE: we select "our" output addresses from the transaction and pass it along to the data layer
newTx :: forall e. ActiveWallet
      -> HdAccountId
      -> TxAux
      -> PartialTxMeta
      -> ([HdAddress] -> IO (Either e ())) -- ^ the update to run, takes ourAddrs as arg
      -> IO (Either e TxMeta)
newTx ActiveWallet{..} accountId tx partialMeta upd = do
    snapshot <- getWalletSnapshot walletPassive
    -- run the update
    hdRnds <- Map.traverseWithKey invariant =<< getEncryptedSecretKeys walletPassive snapshot

    let allOurAddresses = fst <$> allOurs hdRnds
    res <- upd $ allOurAddresses
    case res of
        Left e   -> return (Left e)
        Right () -> do
            -- process transaction on success
            -- myCredentials should be a list with a single element.
            let thisHdRndRoot = Map.filterWithKey (\hdRoot _ -> accountId ^. hdAccountIdParent == hdRoot) hdRnds
                ourOutputCoins = snd <$> allOurs thisHdRndRoot
                gainedOutputCoins = sumCoinsUnsafe ourOutputCoins
                allOutsOurs = length ourOutputCoins == length txOut
                txMeta = partialMeta allOutsOurs gainedOutputCoins
            putTxMeta (walletPassive ^. walletMeta) txMeta
            submitTx
            return (Right txMeta)
    where
        invariant :: HdRootId -> Maybe a -> IO a
        invariant rootId = flip maybe return $ fail $ toString $
            "Cardano.Wallet.Kernel.Pending.newTx: invariant violation: encrypted secret key \
            \hasn't been found for the given root id: " <> sformat build rootId

        (txOut :: [TxOut]) = NE.toList $ (_txOutputs . taTx $ tx)

        -- | NOTE: we recognise addresses in the transaction outputs that belong to _all_ wallets,
        --  not only for the wallet to which this transaction is being submitted
        allOurs
            :: Map HdRootId EncryptedSecretKey
            -> [(HdAddress, Coin)]
        allOurs = evalState $ fmap catMaybes $ forM txOut $ \out -> do
            fmap (, txOutValue out) <$> state (isOurs $ txOutAddress out)


        submitTx :: IO ()
        submitTx = modifyMVar_ (walletPassive ^. walletSubmission) $
                    return . addPending accountId (Pending.singleton tx)

-- | Cancel a pending transaction
--
-- NOTE: This gets called in response to events /from/ the wallet submission
-- layer, so we shouldn't be notifying the submission in return here.
--
-- This removes the transaction from either pending or foreign.
cancelPending :: PassiveWallet -> Cancelled -> IO ()
cancelPending passiveWallet cancelled =
    update' (passiveWallet ^. wallets) $ CancelPending (fmap InDb cancelled)
