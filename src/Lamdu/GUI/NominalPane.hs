module Lamdu.GUI.NominalPane
    ( make
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property)
import qualified GUI.Momentu as M
import           GUI.Momentu.Direction (Orientation(..), Order(..))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Options as ResponsiveOptions
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.DropDownList as DropDownList
import qualified GUI.Momentu.Widgets.Label as Label
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import           GUI.Momentu.Widgets.StdKeys (dirKey)
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.Config.Theme.ValAnnotation as ValAnnotation
import qualified Lamdu.GUI.Expr.TagEdit as TagEdit
import qualified Lamdu.GUI.ParamEdit as ParamEdit
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.TaggedList as TaggedList
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

make :: _ => Sugar.NominalPane Name i o -> GuiM env i o (Responsive o)
make nom =
    do
        hbox <- ResponsiveOptions.boxSpaced ?? ResponsiveOptions.disambiguationNone
        o <- Lens.view has <&> \d -> Lens.cloneLens . dirKey d Horizontal
        keys <-
            traverse Lens.view TaggedList.Keys
            { TaggedList._kAdd = has . Config.addNextParamKeys
            , TaggedList._kOrderBefore = has . Config.orderDirKeys . o Backward
            , TaggedList._kOrderAfter = has . Config.orderDirKeys . o Forward
            }
        (addFirstEventMap, itemsR) <-
            -- TODO: rhs id
            TaggedList.make (has . Texts.parameter) keys nameEditId myId (nom ^. Sugar.npParams)
        nameEdit <-
            TagEdit.makeBinderTagEdit TextColors.nomColor (nom ^. Sugar.npName)
            <&> Responsive.fromWithTextPos
            <&> M.weakerEvents addFirstEventMap
        paramEdits <-
            (<>)
            <$> ParamEdit.mkAddParam (nom ^. Sugar.npParams . Sugar.tlAddFirst) nameEditId
            <*> (traverse makeParam itemsR <&> concat)
        sep <- Styled.grammar (Label.make ":") <&> Responsive.fromTextView
        bodyEdit <- makeNominalPaneBody (nom ^. Sugar.npBody)
        hbox [hbox ((nameEdit : paramEdits) <> [sep]), bodyEdit]
            & pure
        & local (M.animIdPrefix .~ Widget.toAnimId myId)
        & GuiState.assignCursor myId nameEditId
    where
        myId = nom ^. Sugar.npEntityId & WidgetIds.fromEntityId
        nameEditId =
            nom ^. Sugar.npName . Sugar.oTag . Sugar.tagRefTag . Sugar.tagInstance
            & WidgetIds.fromEntityId

paramKindEdit :: _ => Property o Sugar.ParamKind -> Widget.Id -> GuiM env i o (M.TextWidget o)
paramKindEdit prop myId@(Widget.Id animId) =
    (DropDownList.make ?? prop)
    <*> Lens.sequenceOf (traverse . _2)
        [(Sugar.TypeParam, Styled.focusableLabel Texts.typ), (Sugar.RowParam, Styled.focusableLabel Texts.row)]
    <*> (DropDownList.defaultConfig <*> Lens.view (has . Texts.parameter))
    ?? myId
    & local (M.animIdPrefix .~ animId)

makeParam :: _ => TaggedList.Item Name i o (Property o Sugar.ParamKind) -> GuiM env i o [Responsive o]
makeParam item =
    (:)
    <$> ( TagEdit.makeParamTag Nothing (item ^. TaggedList.iTag)
            M./-/ (Lens.view (has . Theme.valAnnotation . ValAnnotation.valAnnotationSpacing) >>= Spacer.vspaceLines)
            M./-/ paramKindEdit (item ^. TaggedList.iValue) (Widget.joinId myId ["kind"])
            <&> Responsive.fromWithTextPos
            <&> M.weakerEvents (item ^. TaggedList.iEventMap)
        )
    <*> ParamEdit.mkAddParam (item ^. TaggedList.iAddAfter) myId
    where
        myId = item ^. TaggedList.iTag . Sugar.tagRefTag . Sugar.tagInstance & WidgetIds.fromEntityId

makeNominalPaneBody :: _ => Maybe (Sugar.Scheme Name o) -> f (Responsive a)
makeNominalPaneBody Nothing =
    Styled.grammar (Styled.focusableLabel Texts.opaque)
    <&> Responsive.fromWithTextPos
makeNominalPaneBody (Just scheme) = TypeView.makeScheme scheme <&> Responsive.fromTextView
