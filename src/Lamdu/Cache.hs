-- | Functions memoized with Data.Cache.Fenced

{-# LANGUAGE ScopedTypeVariables, TypeOperators #-}

module Lamdu.Cache
    ( Functions(..)
    , infer
    , make, FencedCache.Cache, FencedCache.fence
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.RWS (RWST(..))
import           Data.Cache.Fenced (Decl, function)
import qualified Data.Cache.Fenced as FencedCache
import           Hyper
import           Hyper.Infer (InferResult)
import           Hyper.Unify.Binding (UVar)
import           Lamdu.Calc.Infer (InferState, PureInfer(..), runPureInfer)
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Definition as Definition
import           Lamdu.Sugar.Convert.Load (unmemoizedInfer, InferFunc)

import           Lamdu.Prelude

-- Like InferFunc but has the form of (a -> b) where *entire* input is
-- inside "a" and *entire* output is inside "b"
type MemoableInferFunc =
    ( Definition.Expr (Val ())
    , V.Scope # UVar
    , InferState
    ) ->
    Either (Pure # T.TypeError)
    (Ann (InferResult UVar) # V.Term, V.Scope # UVar, InferState)

newtype Functions = Functions
    { inferMemoized :: MemoableInferFunc
    }

-- | We know that inferMemoized retains the shape, so we strip the
-- payload and cover it after
infer :: forall a. Functions -> InferFunc a
infer funcs defExpr =
    fmap (Lens._1 %~ unvoid) . PureInfer . RWST $
    \env s ->
    inferMemoized funcs (defExpr <&> hflipped . hmapped1 .~ Const (), env, s)
    <&> \(iterm, topLevelScope, s') -> ((iterm, topLevelScope), s', ())
    where
        origExpr = defExpr ^. Definition.expr
        unvoid ::
            Ann (InferResult UVar) # V.Term ->
            Ann (a :*: InferResult UVar) # V.Term
        unvoid resExpr =
            resExpr
            & hflipped . hmapped1 %~ (Const () :*:)
            & Lens.unsafePartsOf (hflipped . htraverse1 . Lens._1) .~
                origExpr ^.. hflipped . hfolded1

memoableInfer :: MemoableInferFunc
memoableInfer (expr, env, state) =
    unmemoizedInfer expr & runPureInfer env state
    <&>
    \((resTerm, topLevelScope), newState) ->
    ( resTerm & hflipped . hmapped1 %~ (^. Lens._2)
    , topLevelScope
    , newState
    )

decl :: Decl Functions
decl =
    Functions
    <$> function memoableInfer

make :: IO (FencedCache.Cache, Functions)
make = FencedCache.make decl
