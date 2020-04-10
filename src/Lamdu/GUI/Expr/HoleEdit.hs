module Lamdu.GUI.Expr.HoleEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Data.Char as Char
import qualified Data.Text as Text
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.I18N as MomentuTexts
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified Lamdu.Config as Config
import qualified Lamdu.GUI.Expr.EventMap as ExprEventMap
import qualified Lamdu.GUI.Expr.HoleEdit.SearchArea as SearchArea
import           Lamdu.GUI.Expr.HoleEdit.ValTerms (allowedSearchTermCommon)
import           Lamdu.GUI.Expr.HoleEdit.WidgetIds (WidgetIds(..))
import qualified Lamdu.GUI.Expr.HoleEdit.WidgetIds as HoleWidgetIds
import           Lamdu.GUI.ExpressionGui.Monad (GuiM)
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.Definitions as Texts
import qualified Lamdu.I18N.Name as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

allowedHoleSearchTerm :: Text -> Bool
allowedHoleSearchTerm searchTerm =
    any (searchTerm &)
    [ allowedSearchTermCommon ":."
    , isPositiveNumber
    , isNegativeNumber
    , isLiteralBytes
    ]
    where
        isPositiveNumber t =
            case Text.splitOn "." t of
            [digits]             -> Text.all Char.isDigit digits
            [digits, moreDigits] -> Text.all Char.isDigit (digits <> moreDigits)
            _ -> False
        isLiteralBytes = prefixed '#' (Text.all Char.isHexDigit)
        isNegativeNumber = prefixed '-' isPositiveNumber
        prefixed char restPred t =
            case Text.uncons t of
            Just (c, rest) -> c == char && restPred rest
            _ -> False

make ::
    ( Monad i, Monad o
    , Has (Texts.Code Text) env
    , Has (Texts.CodeUI Text) env
    , Has (Texts.Definitions Text) env
    , Has (Texts.Name Text) env
    , Glue.HasTexts env
    , TextEdit.HasTexts env
    , SearchMenu.HasTexts env
    ) =>
    Annotated (Sugar.Payload Name i o ExprGui.Payload) #
        Const (Sugar.Hole (Sugar.EvaluationScopes Name i) Name i o) ->
    GuiM env i o (Responsive o)
make (Ann (Const pl) (Const hole)) =
    do
        searchTerm <- SearchMenu.readSearchTerm searchMenuId
        delKeys <- Lens.view id <&> Config.delKeys
        env <- Lens.view id
        let (mkLitEventMap, delEventMap)
                | searchTerm == "" =
                    ( ExprEventMap.makeLiteralEventMap ?? pl ^. Sugar.plActions
                    , foldMap
                        (E.keysEventMapMovesCursor delKeys
                            (E.toDoc env
                                [has . MomentuTexts.edit, has . MomentuTexts.delete])
                            . fmap WidgetIds.fromEntityId)
                        (hole ^. Sugar.holeMDelete)
                    )
                | searchTerm == "-" =
                    ( ExprEventMap.makeLiteralNumberEventMap "-" ?? pl ^. Sugar.plActions . Sugar.setToLiteral
                    , mempty
                    )
                | otherwise = (mempty, mempty)
        litEventMap <- mkLitEventMap
        (ExprEventMap.add options pl <&> (Align.tValue %~))
            <*> ( SearchArea.make SearchArea.WithAnnotation (hole ^. Sugar.holeOptions)
                    pl allowedHoleSearchTerm widgetIds ?? Menu.AnyPlace
                    <&> Align.tValue . Widget.eventMapMaker . Lens.mapped %~ (<> delEventMap)
                )
            <&> Align.tValue . Widget.eventMapMaker . Lens.mapped %~ (litEventMap <>)
            <&> Responsive.fromWithTextPos
    where
        searchMenuId = hidOpen widgetIds
        widgetIds = pl ^. Sugar.plEntityId & HoleWidgetIds.make
        options =
            ExprEventMap.defaultOptions
            { ExprEventMap.addOperatorSetHoleState = Just (pl ^. Sugar.plEntityId)
            }
