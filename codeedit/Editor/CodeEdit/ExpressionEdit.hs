{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit(make) where

import Control.Arrow (first)
import Control.Monad (liftM)
import Data.Monoid (Monoid(..))
import Data.Store.Transaction (Transaction)
import Data.Vector.Vector2 (Vector2(..))
import Editor.Anchors (ViewTag)
import Editor.CTransaction (CTransaction, TWidget)
import Editor.CodeEdit.ExpressionEdit.ExpressionMaker(ExpressionEditMaker)
import Editor.MonadF (MonadF)
import Graphics.UI.Bottle.Widget (Widget, EventHandlers)
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ApplyEdit as ApplyEdit
import qualified Editor.CodeEdit.ExpressionEdit.BuiltinEdit as BuiltinEdit
import qualified Editor.CodeEdit.ExpressionEdit.FuncEdit as FuncEdit
import qualified Editor.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Editor.CodeEdit.ExpressionEdit.LiteralEdit as LiteralEdit
import qualified Editor.CodeEdit.ExpressionEdit.PiEdit as PiEdit
import qualified Editor.CodeEdit.ExpressionEdit.SectionEdit as SectionEdit
import qualified Editor.CodeEdit.ExpressionEdit.VarEdit as VarEdit
import qualified Editor.CodeEdit.ExpressionEdit.WhereEdit as WhereEdit
import qualified Editor.CodeEdit.Parens as Parens
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer

data HoleResultPicker m = NotAHole | IsAHole (Maybe (HoleEdit.ResultPicker m))
foldHolePicker
  :: r -> (Maybe (HoleEdit.ResultPicker m) -> r)
  -> HoleResultPicker m -> r
foldHolePicker notHole _isHole NotAHole = notHole
foldHolePicker _notHole isHole (IsAHole x) = isHole x

make :: MonadF m => ExpressionEditMaker m
make sExpr = do
  let
    parenify mkParens hasParens mkWidget myId =
      mkWidget myId >>=
      case hasParens of
      Sugar.HaveParens -> mkParens myId
      Sugar.DontHaveParens -> return
    isAHole = (fmap . liftM . first) IsAHole
    notAHole = (fmap . liftM) ((,) NotAHole)
    wrapNonHoleExpr =
      notAHole .
      BWidgets.wrapDelegatedWithKeys Config.exprFocusDelegatorKeys FocusDelegator.Delegating id
    exprId = WidgetIds.fromGuid . Sugar.guid . Sugar.rActions $ sExpr
    textParenify = parenify Parens.addHighlightedTextParens
    squareParenify = parenify (Parens.addSquareParens . Widget.toAnimId)
    makeEditor =
      case Sugar.rExpression sExpr of
      Sugar.ExpressionWhere hasParens w ->
        wrapNonHoleExpr . squareParenify hasParens $
          WhereEdit.makeWithBody make w
      Sugar.ExpressionFunc hasParens f ->
        wrapNonHoleExpr . textParenify hasParens $ FuncEdit.make make f
      Sugar.ExpressionHole hole ->
        isAHole . HoleEdit.make hole . Sugar.guid $ Sugar.rActions sExpr
      Sugar.ExpressionGetVariable varRef ->
        notAHole {- TODO: May need parenification -} $ VarEdit.make varRef
      Sugar.ExpressionApply hasParens apply ->
        wrapNonHoleExpr . textParenify hasParens $ ApplyEdit.make make apply
      Sugar.ExpressionPi hasParens funcType ->
        wrapNonHoleExpr . textParenify hasParens $ PiEdit.make make funcType
      Sugar.ExpressionSection hasParens section ->
        wrapNonHoleExpr . textParenify hasParens $ SectionEdit.make make section
      Sugar.ExpressionLiteralInteger integer ->
        notAHole $ LiteralEdit.makeInt integer
      Sugar.ExpressionBuiltin builtin ->
        wrapNonHoleExpr $ BuiltinEdit.make builtin

  (holePicker, exprWidget) <- makeEditor exprId
  widget <- addType exprId (Sugar.rType sExpr) exprWidget
  eventMap <- expressionEventMap sExpr holePicker
  return $ Widget.weakerEvents eventMap widget

addType
  :: MonadF m
  => Widget.Id -> [Sugar.ExpressionRef m]
  -> Widget (Transaction ViewTag m)
  -> TWidget ViewTag m
addType _ [] widget = return widget
addType exprId sTypes widget = do
  typeEdits <- mapM make sTypes
  let typeEdit = Widget.scale Config.typeScaleFactor $ BWidgets.vbox typeEdits
  return .
    Box.toWidget $ Box.make Box.vertical
    [ Widget.align (Vector2 0.5 0.5) widget
      -- must not be aligned if space is to be used
    , Spacer.makeHorizLineWidget underlineId
    , Widget.align (Vector2 0.5 0.5) typeEdit
    ]
  where
    underlineId = WidgetIds.underlineId $ Widget.toAnimId exprId

expressionEventMap
  :: MonadF m
  => Sugar.ExpressionRef m
  -> HoleResultPicker m
  -> CTransaction ViewTag m (EventHandlers (Transaction ViewTag m))
expressionEventMap sExpr holePicker =
  return . mconcat $
    [ giveAsArg
    , callWithArg
    , addArg
    , delete
    , replace
    , lambdaWrap
    , addWhereItem
    ]
  where
    giveAsArg =
      maybeMempty (Sugar.giveAsArg actions) $
      moveUnlessOnHole .
      Widget.actionEventMapMovesCursor
      Config.giveAsArgumentKeys "Give as argument" .
      liftM WidgetIds.fromGuid
    callWithArg =
      maybeMempty (Sugar.callWithArg actions) $
      moveUnlessOnHole .
      Widget.actionEventMapMovesCursor
      Config.callWithArgumentKeys "Call with argument" .
      liftM WidgetIds.fromGuid
    addArg =
      maybeMempty (Sugar.mNextArg actions) moveToIfHole
      -- Move to next arg overrides add arg's keys.
      `mappend`
      maybeMempty (Sugar.addNextArg actions)
      (withPickResultFirst Config.addNextArgumentKeys "Add arg" .
       liftM WidgetIds.fromGuid)
    delete =
      -- Replace has the keys of Delete if delete is not available:
      maybeMempty (Sugar.mDelete actions) $
      Widget.actionEventMapMovesCursor Config.delKeys "Delete" .
      liftM WidgetIds.fromGuid
    replace =
      maybeMempty (Sugar.mReplace actions) $
      Widget.actionEventMapMovesCursor (Config.replaceKeys ++ Config.delKeys) "Replace" .
      liftM (FocusDelegator.delegatingId . WidgetIds.fromGuid)
    lambdaWrap =
      maybeMempty (Sugar.lambdaWrap actions) $
      Widget.actionEventMapMovesCursor Config.lambdaWrapKeys "Lambda wrap" .
      liftM (FocusDelegator.delegatingId . WidgetIds.paramId)
    addWhereItem =
      maybeMempty (Sugar.addWhereItem actions) $
      Widget.actionEventMapMovesCursor Config.addWhereItemKeys "Add where item" .
      liftM (FocusDelegator.delegatingId . WidgetIds.paramId)

    withPickResultFirst keys doc action=
      ifHole pickResultFirst .
      Widget.actionEventMapMovesCursor
      keys (ifHole (const ("Pick result and " ++)) doc) $ action
    actions = Sugar.rActions sExpr
    moveUnlessOnHole = ifHole $ (const . fmap . liftM . Widget.atECursor . const) Nothing
    pickResultFirst = maybe id (fmap . joinEvents)
    ifHole whenHole = foldHolePicker id whenHole holePicker
    joinEvents x y = do
      r <- liftM Widget.eAnimIdMapping x
      (liftM . Widget.atEAnimIdMapping) (. r) y
    maybeMempty x f = maybe mempty f x
    moveToIfHole nextArg =
      case Sugar.rExpression nextArg of
      Sugar.ExpressionHole{} ->
        withPickResultFirst Config.addNextArgumentKeys "Move to next arg" .
        return . WidgetIds.fromGuid . Sugar.guid . Sugar.rActions $ nextArg
      _ -> mempty
