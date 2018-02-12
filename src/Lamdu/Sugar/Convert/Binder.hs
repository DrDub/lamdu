{-# LANGUAGE NoImplicitPrelude, FlexibleContexts, TypeFamilies, RankNTypes, DisambiguateRecordFields #-}
module Lamdu.Sugar.Convert.Binder
    ( convertDefinitionBinder, convertLam, convertBinderBody
    ) where

import qualified Control.Lens as Lens
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Data.Ops.Subexprs as SubExprs
import           Lamdu.Expr.IRef (DefI, ValIProperty)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.UniqueId as UniqueId
import qualified Lamdu.Infer as Infer
import           Lamdu.Sugar.Convert.Binder.Float (makeFloatLetToOuterScope)
import           Lamdu.Sugar.Convert.Binder.Inline (inlineLet)
import           Lamdu.Sugar.Convert.Binder.Params (ConventionalParams(..), convertParams, convertLamParams, cpParams)
import           Lamdu.Sugar.Convert.Binder.Redex (Redex(..))
import qualified Lamdu.Sugar.Convert.Binder.Redex as Redex
import           Lamdu.Sugar.Convert.Binder.Types (BinderKind(..))
import           Lamdu.Sugar.Convert.Expression.Actions (addActions, makeAnnotation, makeActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM, scScopeInfo, siLetItems)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.Types
import qualified Revision.Deltum.Property as Property
import           Revision.Deltum.Transaction (Transaction, MkProperty, mkProperty)

import           Lamdu.Prelude

type T = Transaction

lamParamToHole ::
    Monad m =>
    V.Lam (Val (Input.Payload m a)) -> T m ()
lamParamToHole (V.Lam param body) =
    SubExprs.getVarsToHole param (body <&> (^. Input.stored))

mkLetItemActions ::
    Monad m =>
    Input.Payload m a -> Redex (Input.Payload m a) ->
    ConvertM m (LetActions (T m))
mkLetItemActions topLevelPl redex =
    do
        postProcess <- ConvertM.postProcess
        nodeActions <- makeActions topLevelPl
        pure LetActions
            { _laDelete =
                do
                    lamParamToHole (redex ^. Redex.lam)
                    redex ^. Redex.lam . V.lamResult . Val.payload . Input.stored
                        & replaceWith topLevelProp & void
                <* postProcess
            , _laNodeActions = nodeActions
            }
    where
        topLevelProp = topLevelPl ^. Input.stored

localNewExtractDestPos ::
    Val (Input.Payload m x) -> ConvertM m a -> ConvertM m a
localNewExtractDestPos val =
    ConvertM.scScopeInfo . ConvertM.siMOuter ?~
    ConvertM.OuterScopeInfo
    { _osiPos = val ^. Val.payload . Input.stored
    , _osiScope = val ^. Val.payload . Input.inferred . Infer.plScope
    }
    & ConvertM.local

makeInline :: Monad m => ValIProperty m -> Redex (Input.Payload m a) -> BinderVarInline (T m)
makeInline stored redex =
    case redex ^. Redex.paramRefs of
    [_singleUsage] ->
        inlineLet stored (redex <&> (^. Input.stored) <&> Property.value)
        & InlineVar
    [] -> CannotInline
    uses -> CannotInlineDueToUses uses

convertRedex ::
    (Monad m, Monoid a) =>
    Val (Input.Payload m a) ->
    Redex (Input.Payload m a) ->
    ConvertM m (Let InternalName (T m) (ExpressionU m a))
convertRedex expr redex =
    do
        (_pMode, value) <-
            convertBinder binderKind param (redex ^. Redex.arg)
            & localNewExtractDestPos expr
        actions <- mkLetItemActions (expr ^. Val.payload) redex
        letBody <-
            convertBinderBody body
            & localNewExtractDestPos expr
            & ConvertM.local (scScopeInfo . siLetItems <>~
                Map.singleton param (makeInline stored redex))
        ann <- redex ^. Redex.arg . Val.payload & makeAnnotation
        float <- makeFloatLetToOuterScope (Property.set stored) redex
        protectedSetToVal <- ConvertM.typeProtectedSetToVal
        let fixValueNodeActions nodeActions =
                nodeActions
                & extract .~ float
                & mReplaceParent ?~
                    ( protectedSetToVal stored
                        (redex ^. Redex.arg . Val.payload . Input.stored . Property.pVal)
                        <&> EntityId.ofValI
                    )
        pure Let
            { _lEntityId = defEntityId
            , _lValue = value & bActions . baMNodeActions . Lens._Just %~ fixValueNodeActions
            , _lActions = actions
            , _lName = UniqueId.toUUID param & InternalName
            , _lAnnotation = ann
            , _lBodyScope = redex ^. Redex.bodyScope
            , _lBody =
                letBody
                & bbContent .
                    Lens.failing
                    (_BinderExpr . rPayload . plActions)
                    (_BinderLet . lActions . laNodeActions) . mReplaceParent ?~
                    (letBody ^. bbContent . SugarLens.binderContentEntityId <$ actions ^. laDelete)
            , _lUsages = redex ^. Redex.paramRefs
            }
    where
        stored = expr ^. Val.payload . Input.stored
        binderKind =
            redex ^. Redex.lam
            <&> Lens.mapped %~ (^. Input.stored)
            & BinderKindLet
        V.Lam param body = redex ^. Redex.lam
        defEntityId = EntityId.ofLambdaParam param

makeBinderContent ::
    (Monad m, Monoid a) =>
    Val (Input.Payload m a) ->
    ConvertM m (BinderContent InternalName (T m) (ExpressionU m a))
makeBinderContent expr =
    case Redex.check expr of
    Nothing ->
        ConvertM.convertSubexpression expr & localNewExtractDestPos expr
        <&> BinderExpr
    Just redex -> convertRedex expr redex <&> BinderLet

convertBinderBody ::
    (Monad m, Monoid a) =>
    Val (Input.Payload m a) ->
    ConvertM m (BinderBody InternalName (T m) (ExpressionU m a))
convertBinderBody expr =
    makeBinderContent expr
    <&>
    \content ->
    BinderBody
    { _bbAddOuterLet =
        expr ^. Val.payload . Input.stored & DataOps.redexWrap <&> EntityId.ofLambdaParam
    , _bbContent = content
    }

makeBinder ::
    (Monad m, Monoid a) =>
    MkProperty m (Maybe BinderParamScopeId) ->
    ConventionalParams m -> Val (Input.Payload m a) -> Input.Payload m a ->
    ConvertM m (Binder InternalName (T m) (ExpressionU m a))
makeBinder chosenScopeProp params funcBody pl =
    do
        binderBody <- convertBinderBody funcBody
        nodeActions <- makeActions pl
        let mRemoveSetToHole
                | Lens.has (cpParams . _BinderWithoutParams) params
                && Lens.has (bbContent . _BinderExpr . rBody . _BodyHole) binderBody =
                    mSetToHole .~ Nothing
                | otherwise = id
        pure Binder
            { _bParams = _cpParams params
            , _bChosenScopeProp = chosenScopeProp ^. mkProperty
            , _bLamId = cpMLamParam params ^? Lens._Just . _1
            , _bBody = binderBody
            , _bBodyScopes = cpScopes params
            , _bActions =
                BinderActions
                { _baAddFirstParam = _cpAddFirstParam params
                , _baMNodeActions = Just (mRemoveSetToHole nodeActions)
                }
            }
    & ConvertM.local (ConvertM.scScopeInfo %~ addParams)
    where
        addParams ctx =
            ctx
            & ConvertM.siTagParamInfos <>~ _cpParamInfos params
            & ConvertM.siNullParams <>~
            case _cpParams params of
            NullParam {} -> Set.fromList (cpMLamParam params ^.. Lens._Just . _2)
            _ -> Set.empty

convertLam ::
    (Monad m, Monoid a) =>
    V.Lam (Val (Input.Payload m a)) ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convertLam lam exprPl =
    do
        convParams <- convertLamParams lam exprPl
        binder <-
            makeBinder
            (lam ^. V.lamParamId & Anchors.assocScopeRef)
            convParams (lam ^. V.lamResult) exprPl
            <&> bActions . baMNodeActions .~ Nothing
        let paramNames =
                binder ^.. bParams . _FieldParams . traverse . fpInfo . fpiTag . tagName
                & Set.fromList
        let lambda
                | useNormalLambda paramNames binder =
                    Lambda NormalBinder binder
                | otherwise =
                    binder
                    & bBody . Lens.traverse %~ markLightParams paramNames
                    & Lambda LightLambda
        BodyLam lambda
            & addActions exprPl
            <&> rBody . Lens.mapped . rPayload . plActions . mReplaceParent . Lens._Just %~ (lamParamToHole lam >>)

useNormalLambda :: Set InternalName -> Binder InternalName (T m) (Expression InternalName (T m) a) -> Bool
useNormalLambda paramNames binder =
    any (binder &)
    [ Lens.hasn't (bParams . _FieldParams)
    , Lens.has (bBody . bbContent . _BinderLet)
    , Lens.has (bBody . Lens.traverse . SugarLens.payloadsOf forbiddenLightLamSubExprs)
    , not . allParamsUsed paramNames
    ]
    where
        forbiddenLightLamSubExprs :: Lens.Traversal' (Body name m a) ()
        forbiddenLightLamSubExprs =
            Lens.failing SugarLens.bodyUnfinished
            (_BodyLam . lamBinder . bParams . namedParams .
             Lens.united)
        namedParams :: Lens.Traversal' (BinderParams name m) ()
        namedParams = Lens.failing (_VarParam . Lens.united) (_FieldParams . Lens.united)

allParamsUsed :: Set InternalName -> Binder InternalName (T m) (Expression InternalName (T m) a) -> Bool
allParamsUsed paramNames binder =
    Set.null (paramNames `Set.difference` usedParams)
    where
        usedParams =
            binder ^.. Lens.traverse . SugarLens.subExprPayloads . Lens.asIndex .
            rBody . _BodyGetVar . _GetParam . pNameRef . nrName
            & Set.fromList

markLightParams ::
    Monad m => Set InternalName -> Expression InternalName (T m) a -> Expression InternalName (T m) a
markLightParams paramNames (Expression body pl) =
    case body of
    BodyGetVar (GetParam n)
        | Set.member (n ^. pNameRef . nrName) paramNames ->
            n
            & pBinderMode .~ LightLambda
            & GetParam & BodyGetVar
    BodyFragment w -> w <&> markLightParams paramNames & BodyFragment
    _ -> body <&> markLightParams paramNames
    & (`Expression` pl)

-- Let-item or definition (form of <name> [params] = <body>)
convertBinder ::
    (Monad m, Monoid a) =>
    BinderKind m -> V.Var -> Val (Input.Payload m a) ->
    ConvertM m
    ( Maybe (MkProperty m PresentationMode)
    , Binder InternalName (T m) (ExpressionU m a)
    )
convertBinder binderKind defVar expr =
    do
        (mPresentationModeProp, convParams, funcBody) <-
            convertParams binderKind defVar expr
        makeBinder (Anchors.assocScopeRef defVar) convParams
            funcBody (expr ^. Val.payload)
            <&> (,) mPresentationModeProp

convertDefinitionBinder ::
    (Monad m, Monoid a) =>
    DefI m -> Val (Input.Payload m a) ->
    ConvertM m
    ( Maybe (MkProperty m PresentationMode)
    , Binder InternalName (T m) (ExpressionU m a)
    )
convertDefinitionBinder defI =
    convertBinder (BinderKindDef defI) (ExprIRef.globalId defI)
