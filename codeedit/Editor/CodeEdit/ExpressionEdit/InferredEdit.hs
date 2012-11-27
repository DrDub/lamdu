{-# LANGUAGE TypeFamilies #-}
module Editor.CodeEdit.ExpressionEdit.InferredEdit(make) where

import Data.Store.Guid (Guid)
import Editor.Anchors (ViewM)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad (ExprGuiM)
import Editor.MonadF (MonadF)
import qualified Control.Lens as Lens
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Editor.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.WidgetEnvT as WE
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

fdConfig :: FocusDelegator.Config
fdConfig = FocusDelegator.Config
  { FocusDelegator.startDelegatingKey = Config.replaceInferredValueKey
  , FocusDelegator.startDelegatingDoc = "Replace inferred value"
  , FocusDelegator.stopDelegatingKey = Config.keepInferredValueKey
  , FocusDelegator.stopDelegatingDoc = "Keep inferred value"
  }

make
  :: (MonadF m, m ~ ViewM) => Sugar.Inferred m (Sugar.Expression m) -> Guid -> Widget.Id
  -> ExprGuiM m (ExpressionGui m)
make inferred guid =
  ExpressionGui.wrapDelegated fdConfig FocusDelegator.NotDelegating $
  makeUnwrapped inferred guid

makeUnwrapped
  :: Sugar.Inferred ViewM (Sugar.Expression ViewM) -> Guid
  -> Widget.Id
  -> ExprGuiM ViewM (ExpressionGui ViewM)
makeUnwrapped inferred guid myId = do
  mInnerCursor <- ExprGuiM.widgetEnv $ WE.subCursor myId
  case mInnerCursor of
    Nothing ->
      Lens.mapMOf ExpressionGui.egWidget
      ( ExprGuiM.widgetEnv
      . BWidgets.makeFocusableView myId
      . Widget.tint Config.inferredValueTint
      . Widget.scale Config.inferredValueScaleFactor
      ) =<< ExprGuiM.makeSubexpresion (Sugar.iValue inferred)
    Just _ ->
      HoleEdit.makeUnwrapped (Sugar.iHole inferred) Nothing guid myId
