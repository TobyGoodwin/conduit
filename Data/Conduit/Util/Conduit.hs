{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
-- | Utilities for constructing and covnerting conduits. Please see
-- "Data.Conduit.Types.Conduit" for more information on the base types.
module Data.Conduit.Util.Conduit
    ( bconduitM
    , bconduit
    , conduitM
    , conduitMState
    , transConduitM
    ) where

import Control.Monad.Trans.Resource (ResourceT, transResourceT)
import Data.Conduit.Types.Conduit
import Data.Conduit.Types.Source (StreamState (..))
import Control.Monad.Base (MonadBase (liftBase))
import qualified Data.IORef as I
import Control.Monad (liftM)

-- | Construct a 'ConduitM' with some stateful functions. This function address
-- all mutable state for you.
conduitMState
    :: MonadBase IO m
    => state -- ^ initial state
    -> (state -> [input] -> ResourceT m (state, ConduitResult input output)) -- ^ Push function.
    -> (state -> [input] -> ResourceT m (ConduitCloseResult input output)) -- ^ Close function. The state need not be returned, since it will not be used again.
    -> ConduitM input m output
conduitMState state0 push close = conduitM
    (liftBase $ I.newIORef state0)
    (const $ return ())
    (\istate input -> do
        state <- liftBase $ I.readIORef istate
        (state', res) <- push state input
        liftBase $ I.writeIORef istate state'
        return res)
    (\istate input -> liftBase (I.readIORef istate) >>= flip close input)

-- | Construct a 'ConduitM'.
conduitM :: Monad m
         => ResourceT m state -- ^ resource and/or state allocation
         -> (state -> ResourceT m ()) -- ^ resource and/or state cleanup
         -> (state -> [input] -> ResourceT m (ConduitResult input output)) -- ^ Push function. Note that this need not explicitly perform any cleanup.
         -> (state -> [input] -> ResourceT m (ConduitCloseResult input output)) -- ^ Close function. Note that this need not explicitly perform any cleanup.
         -> ConduitM input m output
conduitM alloc cleanup push close = ConduitM $ do
    state <- alloc
    return Conduit
        { conduitPush = \input -> do
            res@(ConduitResult sstate _ _) <- push state input
            case sstate of
                StreamClosed -> cleanup state
                StreamOpen -> return ()
            return res
        , conduitClose = \input -> do
            output <- close state input
            cleanup state
            return output
        }

bconduitM :: MonadBase IO m
          => ConduitM input m output
          -> ResourceT m (BConduit input m output)
bconduitM (ConduitM mc) = mc >>= bconduit

-- | State of a 'BSource'
data BState a = EmptyOpen -- ^ nothing in buffer, EOF not received yet
              | EmptyClosed -- ^ nothing in buffer, EOF has been received
              | Open [a] -- ^ something in buffer, EOF not received yet
              | Closed [a] -- ^ something in buffer, EOF has been received
    deriving Show

-- | Convert a 'SourceM' into a 'BSource'.
bconduit :: MonadBase IO m
         => Conduit input m output
         -> ResourceT m (BConduit input m output)
bconduit con = do
    istate <- liftBase (I.newIORef EmptyOpen)
    return BConduit
        { bconduitPull =
            liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open buffer -> (EmptyOpen, buffer)
                    Closed buffer -> (EmptyClosed, buffer)
                    EmptyOpen -> (EmptyOpen, [])
                    EmptyClosed -> (EmptyClosed, [])
        , bconduitUnpull = \x ->
            if null x
                then return ()
                else liftBase $ I.atomicModifyIORef istate $ \state ->
                    case state of
                        Open buffer -> (Open (x ++ buffer), ())
                        Closed buffer -> (Closed (x ++ buffer), ())
                        EmptyOpen -> (Open x, ())
                        EmptyClosed -> (Closed x, ())
        , bconduitClose = \input -> do
            action <- liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open x -> (Closed x, conduitClose con input)
                    Closed _ -> (state, return $ ConduitCloseResult input [])
                    EmptyOpen -> (EmptyClosed, conduitClose con input)
                    EmptyClosed -> (state, return $ ConduitCloseResult input [])
            action
        , bconduitPush = \x -> do
            buffer <- liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open buffer -> (EmptyOpen, buffer)
                    Closed buffer -> (EmptyClosed, buffer)
                    EmptyOpen -> (EmptyOpen, [])
                    EmptyClosed -> (EmptyClosed, [])
            if null buffer
                then conduitPush con x
                else return $ ConduitResult StreamOpen x buffer
        }

-- | Transform the monad a 'ConduitM' lives in.
transConduitM :: Monad m
              => (forall a. m a -> n a)
              -> ConduitM input m output
              -> ConduitM input n output
transConduitM f (ConduitM mc) =
    ConduitM (transResourceT f (liftM go mc))
  where
    go c = c
        { conduitPush = transResourceT f . conduitPush c
        , conduitClose = transResourceT f . conduitClose c
        }