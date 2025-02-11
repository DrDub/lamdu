-- | A goto-definition widget
{-# LANGUAGE TemplateHaskell #-}
module Lamdu.GUI.CodeEdit.GotoDefinition
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Data.ByteString.Char8 as BS8
import           Data.MRUMemo (memo)
import qualified Data.Text as Text
import           GUI.Momentu ((/|/))
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.TextColors (TextColors)
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.Fuzzy (Fuzzy)
import qualified Lamdu.Fuzzy as Fuzzy
import qualified Lamdu.GUI.Expr.GetVarEdit as GetVarEdit
import qualified Lamdu.GUI.StatusBar.Common as StatusBar
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Name as Texts
import qualified Lamdu.I18N.Navigation as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

data Global o = Global
    { _globalIdx :: !Int
    , _globalPrefix :: !Text
    , _globalColor :: !(Lens.ALens' TextColors M.Color)
    , _globalNameRef :: !(Sugar.NameRef Name o)
    }
Lens.makeLenses ''Global

myId :: Widget.Id
myId = Widget.Id ["goto-def"]

-- TODO: This is redundant to injectSymbol, hard-code it and remove from languages json?
getTagPrefix :: Text -> Maybe Char
getTagPrefix searchTerm = searchTerm ^? Lens.ix 0 . Lens.filtered (`elem` ['\'', '.'])

allowSearchTerm :: Text -> Bool
allowSearchTerm text =
    Text.drop prefixLength text & Name.isValidText
    where
        prefixLength = length (getTagPrefix text)

{-# NOINLINE fuzzyMaker #-}
fuzzyMaker :: [(Text, Int)] -> Fuzzy (Set Int)
fuzzyMaker = memo Fuzzy.make

nameToText :: _ => Name -> m Text
nameToText name =
    Name.visible name <&>
    \(Name.TagText text textCol, tagCol) ->
    text <> collisionText textCol <> collisionText tagCol
    where
        collisionText Name.NoCollision = ""
        collisionText (Name.Collision i) = Text.pack (show i)
        collisionText Name.UnknownCollision = "?"

toGlobal :: Int -> (Text, Lens.ALens' TextColors M.Color, Sugar.NameRef Name o) -> Global o
toGlobal idx (prefix, color, nameRef) = Global idx prefix color nameRef

makeOptions ::
    ( MonadReader env m, Has (Texts.Navigation Text) env, Has (Texts.Name Text) env
    , M.HasCursor env, M.HasAnimIdPrefix env, Has Theme env, Has TextView.Style env
    , Has Dir.Layout env
    , Applicative o
    ) =>
    Sugar.Globals Name m o -> SearchMenu.ResultsContext -> m (Menu.OptionList (Menu.Option m o))
makeOptions globals (SearchMenu.ResultsContext searchTerm prefix)
    | Text.null searchTerm =
        pure Menu.OptionList { Menu._olIsTruncated = False, Menu._olOptions = [] }
    | otherwise =
        do
            env <- Lens.view id
            let toRenderedOption nameRef widget =
                    Menu.RenderedOption
                    { Menu._rWidget = widget
                    , Menu._rPick =
                        Widget.PreEvent
                        { Widget._pDesc = env ^. has . Texts.goto
                        , Widget._pAction =
                            nameRef ^. Sugar.nrGotoDefinition
                            <&> WidgetIds.fromEntityId <&> toPickResult
                        , Widget._pTextRemainder = ""
                        }
                    }
            let makeOption global =
                    Menu.Option
                    { Menu._oId = optId
                    , Menu._oRender =
                        ((TextView.make ?? global ^. globalPrefix)
                            <*> (Element.subAnimId ?? ["."]))
                        /|/
                        GetVarEdit.makeSimpleView (global ^. globalColor) name optId
                        <&> toRenderedOption (global ^. globalNameRef)
                        & local (M.animIdPrefix .~ Widget.toAnimId optId)
                    , Menu._oSubmenuWidgets = Menu.SubmenuEmpty
                    }
                    where
                        name = global ^. globalNameRef . Sugar.nrName
                        idx = global ^. globalIdx
                        optId = prefix `Widget.joinId` [BS8.pack (show idx)]
            globs <-
                case mTagPrefix of
                Just tagPrefix ->
                    globals ^. Sugar.globalTags <&> map ((,,) (Text.singleton tagPrefix) TextColors.baseColor)
                Nothing ->
                    (<>)
                    <$> (globals ^. Sugar.globalDefs <&> map ((,,) "" TextColors.definitionColor))
                    <*> (globals ^. Sugar.globalNominals <&> map ((,,) "" TextColors.nomColor))
            Lens.imap toGlobal globs
                & traverse withText
                <&> (Fuzzy.memoableMake fuzzyMaker ?? searchTerm)
                <&> map (makeOption . snd)
                <&> Menu.OptionList isTruncated
    where
        mTagPrefix = getTagPrefix searchTerm
        isTruncated = False
        withText global =
            nameToText (global ^. globalNameRef . Sugar.nrName) <&>
            \text -> (maybe id Text.cons mTagPrefix text, global)
        toPickResult x = Menu.PickResult x (Just x)

make :: _ => Sugar.Globals Name m o -> m (StatusBar.StatusWidget o)
make globals =
    do
        goto <- Lens.view (has . Texts.goto)
        let onTermStyle x =
                x
                & SearchMenu.emptyStrings . Lens.mapped .~ goto
                & SearchMenu.bgColors . Lens.mapped .~ M.Color 0 0 0 0
        SearchMenu.make (SearchMenu.searchTermEdit myId (pure . allowSearchTerm))
            (makeOptions globals) M.empty myId ?? Menu.Below
            & local (has . Theme.searchTerm %~ onTermStyle)
            <&> \searchWidget -> StatusBar.StatusWidget
            { StatusBar._widget = searchWidget
            , StatusBar._globalEventMap = mempty
            }
