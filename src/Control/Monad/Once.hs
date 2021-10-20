{-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables, TemplateHaskell, TypeApplications, DerivingVia #-}

module Control.Monad.Once
    ( MonadOnce(..)
    , OnceT(..), _OnceT
    , OnceState
    , Typeable
    , onceList
    , runOnceT, evalOnceT
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.ListT (ListT(..))
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State (StateT, evalStateT, runStateT)
import           Data.Dynamic (Dynamic, toDyn, fromDynamic)
import           Data.IORef
import qualified Data.List.Class as ListClass
import qualified Data.Monoid as Monoid
import qualified Data.Sequence as Sequence
import           Data.Typeable (Typeable, typeRep)

import           Lamdu.Prelude

class Monad m => MonadOnce m where
    once :: Typeable a => m a -> m (m a)

instance MonadOnce IO where
    once a =
        newIORef Nothing
        <&>
        \r ->
        readIORef r
        >>=
        \case
        Just x -> pure x
        Nothing ->
            do
                x <- a
                x <$ writeIORef r (Just x)

type OnceState = Sequence.Seq Dynamic

newtype OnceT m a = OnceT (StateT OnceState m a)
    deriving newtype (Functor, Applicative, Monad, MonadTrans)
    deriving (Semigroup, Monoid) via Monoid.Ap (OnceT m) a

Lens.makePrisms ''OnceT

instance Monad m => MonadOnce (OnceT m) where
    once (a :: OnceT m a) =
        id <<%= (|> toDyn (Nothing :: Maybe a)) <&> Sequence.length & OnceT
        <&>
        \r ->
        OnceT (Lens.use id) <&> (^? Lens.ix r)
        >>=
        \case
        Nothing ->
            "Once used incorrectly, key beyond length of Seq: " <> show r <> "/" <> show (typeRep (Proxy @a))
            & error
        Just d ->
            case fromDynamic d of
            Just (Just x) -> pure x
            Just Nothing ->
                do
                    x <- a
                    x <$ OnceT (Lens.ix r .= toDyn (Just x))
            Nothing -> error "Once used incorrectly: wrong type for key!"

onceList ::
    (MonadOnce m, Typeable m, Typeable a) =>
    ListT m a -> m (ListT m a)
onceList (ListT a) =
    once
    ( a >>=
        \case
        ListClass.Nil -> pure ListClass.Nil
        ListClass.Cons x xs -> onceList xs <&> ListClass.Cons x
    ) <&> ListT

-- | Evaluate a OnceT without any cache!
evalOnceT :: Monad m => OnceT m a -> m a
evalOnceT (OnceT x) = evalStateT x mempty

runOnceT :: OnceState -> OnceT m a -> m (a, OnceState)
runOnceT s (OnceT x) = runStateT x s

-- lifters:
instance MonadOnce m => MonadOnce (ReaderT r m) where once = mapReaderT (fmap lift . once)
