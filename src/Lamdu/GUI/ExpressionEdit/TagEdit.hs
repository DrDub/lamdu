{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
module Lamdu.GUI.ExpressionEdit.TagEdit
    ( makeRecordTag, makeCaseTag, Mode(..)
    , makeArgTag
    , diveToRecordTag, diveToCaseTag
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.Function (on)
import           Data.Store.Transaction (Transaction)
import qualified Data.Text as Text
import           GUI.Momentu.Align (WithTextPos)
import qualified GUI.Momentu.Align as Align
import           GUI.Momentu.CursorState (cursorState)
import qualified GUI.Momentu.Draw as Draw
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.Hover as Hover
import           GUI.Momentu.MetaKey (MetaKey(..), noMods)
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.View (View)
import           GUI.Momentu.Widget (Widget)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.Names.Types (Name(..))
import qualified Lamdu.Sugar.Names.Types as Name
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

tagRenameId :: Widget.Id -> Widget.Id
tagRenameId = (`Widget.joinId` ["rename"])

tagHoleId :: Widget.Id -> Widget.Id
tagHoleId = (`Widget.joinId` ["hole"])

tagViewId :: Widget.Id -> Widget.Id
tagViewId = (`Widget.joinId` ["view"])

setTagName :: Monad m => Sugar.Tag (Name m) m -> Text -> T m ()
setTagName tag name =
    do
        (tag ^. Sugar.tagName . Name.setName) name
        (tag ^. Sugar.tagActions . Sugar.taSetPublished) (not (Text.null name))

makeTagNameEdit ::
    Monad m =>
    NearestHoles -> Sugar.Tag (Name m) m ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeTagNameEdit nearestHoles tag =
    do
        config <- Lens.view Config.config <&> Config.hole
        let keys = Config.holePickAndMoveToNextHoleKeys config
        let jumpNextEventMap =
                nearestHoles ^. NearestHoles.next
                & maybe mempty
                  (Widget.keysEventMapMovesCursor keys
                   (E.Doc ["Navigation", "Jump to next hole"]) .
                   return . WidgetIds.fromEntityId)
        ExpressionGui.makeBareNameEdit
            (tag ^. Sugar.tagName & Name.setName .~ setTagName tag)
            (tagRenameId myId)
            <&> Align.tValue . E.eventMap %~ E.filterChars (/= ',')
            <&> Align.tValue %~ E.weakerEvents jumpNextEventMap
            <&> Align.tValue %~ E.weakerEvents stopEditingEventMap
    where
        myId = WidgetIds.fromEntityId (tag ^. Sugar.tagInfo . Sugar.tagInstance)
        stopEditingEventMap =
            Widget.keysEventMapMovesCursor
            [ MetaKey noMods MetaKey.Key'Escape
            , MetaKey noMods MetaKey.Key'Enter
            ]
            (E.Doc ["Edit", "Tag", "Stop editing"]) (pure (tagViewId myId))

insensitiveInfixOf :: Text -> Text -> Bool
insensitiveInfixOf = Text.isInfixOf `on` Text.toLower

tagId :: Sugar.Tag name m -> Widget.Id
tagId tag = tag ^. Sugar.tagInfo . Sugar.tagInstance & WidgetIds.fromEntityId

makePickEventMap ::
    (Functor f, Config.HasConfig env, MonadReader env m) =>
    NearestHoles -> Sugar.Tag name n -> E.Doc -> f b ->
    m (Widget.EventMap (f Widget.EventResult))
makePickEventMap nearestHoles tag doc action =
    Lens.view Config.config <&> Config.hole <&>
    \config ->
    let pickKeys = Config.holePickResultKeys config
        jumpNextKeys = Config.holePickAndMoveToNextHoleKeys config
        actionAndClose = tagId tag <$ action
    in
    case nearestHoles ^. NearestHoles.next of
    Nothing -> Widget.keysEventMapMovesCursor (pickKeys <> jumpNextKeys) doc actionAndClose
    Just nextHole ->
        Widget.keysEventMapMovesCursor pickKeys doc actionAndClose
        <> Widget.keysEventMapMovesCursor jumpNextKeys
            (doc & E.docStrs . Lens.reversed . Lens.ix 0 %~ (<> " and jump to next hole"))
            (WidgetIds.fromEntityId nextHole <$ action)

makeOptions ::
    Monad m =>
    (Widget.EventResult -> a) -> NearestHoles -> Sugar.Tag (Name n) m -> Text ->
    ExprGuiM m [WithTextPos (Widget (T m a))]
makeOptions fixCursor nearestHoles tag searchTerm
    | Text.null searchTerm = pure []
    | otherwise =
        tag ^. Sugar.tagActions . Sugar.taOptions & transaction
        <&> filter (Lens.anyOf (_1 . Name.form . Name._Stored . _1) (insensitiveInfixOf searchTerm))
        <&> take 4
        >>= mapM makeOptionGui
    where
        makeOptionGui (name, t) =
            do
                eventMap <-
                    (tag ^. Sugar.tagActions . Sugar.taChangeTag) t
                    & makePickEventMap nearestHoles tag (E.Doc ["Edit", "Tag", "Select"])
                (Widget.makeFocusableView <*> Widget.makeSubId optionId <&> fmap)
                    <*> ExpressionGui.makeNameView (name ^. Name.form) optionId
                    <&> Align.tValue %~ E.weakerEvents eventMap
            <&> Align.tValue . Lens.mapped . Lens.mapped %~ fixCursor
            where
                optionId = Widget.toAnimId (WidgetIds.hash t)

makeTagHoleEditH ::
    Monad m =>
    NearestHoles -> Sugar.Tag (Name m) m ->
    Text -> (Text -> Widget.EventResult -> Widget.EventResult) -> (Widget.EventResult -> Widget.EventResult) ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeTagHoleEditH nearestHoles tag searchTerm updateState fixCursor =
    do
        setNameEventMap <-
            setTagName tag searchTerm
            & makePickEventMap nearestHoles tag (E.Doc ["Edit", "Tag", "Set name"])
        term <-
            TextEdit.make ?? textEditNoEmpty ?? searchTerm ?? searchTermId
            <&> Align.tValue . Lens.mapped %~ pure . uncurry updateState
            <&> Align.tValue %~ E.strongerEvents setNameEventMap
        label <- (TextView.make ?? labelText) <*> Element.subAnimId ["label"]
        let topLine = term /|/ label
        options <- makeOptions fixCursor nearestHoles tag searchTerm
        case options of
            [] -> return topLine
            _ ->
                Hover.hover ?? Glue.vbox (options <&> (^. Align.tValue))
                <&>
                \optionsBox ->
                let anchored = topLine <&> Hover.anchor
                in
                anchored
                <&> Hover.hoverInPlaceOf (Hover.hoverBesideOptions optionsBox (anchored ^. Align.tValue))
    & Widget.assignCursor holeId searchTermId
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId holeId)
    where
        labelText
            | Text.null searchTerm = "(pick tag)"
            | otherwise = " (new tag)"
        holeId = tagHoleId (tagId tag)
        searchTermId = holeId <> Widget.Id ["term"]
        textEditNoEmpty = TextEdit.EmptyStrings "" ""

makeTagHoleEdit ::
    Monad m => NearestHoles -> Sugar.Tag (Name m) m -> ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeTagHoleEdit nearestHoles tag =
    cursorState myId "" (makeTagHoleEditH nearestHoles tag)
    where
        myId = tag ^. Sugar.tagInfo . Sugar.tagInstance & WidgetIds.fromEntityId & tagHoleId

data Mode = WithTagHoles | WithoutTagHoles

makeTagEdit ::
    Monad m =>
    Mode -> Draw.Color -> NearestHoles -> Sugar.Tag (Name m) m ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeTagEdit mode tagColor nearestHoles tag =
    do
        jumpHolesEventMap <- ExprEventMap.jumpHolesEventMap nearestHoles
        isRenaming <- Widget.isSubCursor ?? tagRenameId myId
        isHole <- Widget.isSubCursor ?? tagHoleId myId
        config <- Lens.view Config.config
        let eventMap =
                Widget.keysEventMapMovesCursor (Config.jumpToDefinitionKeys config)
                (E.Doc ["Edit", "Tag", "Open"]) (pure (tagRenameId myId))
                <>
                case mode of
                WithTagHoles ->
                    Widget.keysEventMapMovesCursor (Config.delKeys config)
                    (E.Doc ["Edit", "Tag", "Choose"])
                    (tag ^. Sugar.tagActions . Sugar.taReplaceWithNew
                        <&> (^. Sugar.tagInstance)
                        <&> tagHoleId . WidgetIds.fromEntityId)
                WithoutTagHoles -> mempty
        nameView <-
            (Widget.makeFocusableView ?? viewId <&> fmap) <*>
            ExpressionGui.makeNameView (tag ^. Sugar.tagName . Name.form) (Widget.toAnimId myId)
            <&> Lens.mapped %~ E.weakerEvents eventMap
        let hover = Hover.hoverBeside Align.tValue ?? nameView
        widget <-
            if isRenaming
            then
                hover <*>
                (makeTagNameEdit nearestHoles tag <&> (^. Align.tValue))
            else if isHole
            then makeTagHoleEdit nearestHoles tag
            else pure nameView
        widget
            <&> E.weakerEvents jumpHolesEventMap
            & pure
    & Reader.local (TextView.color .~ tagColor)
    & Widget.assignCursor myId viewId
    where
        myId = WidgetIds.fromEntityId (tag ^. Sugar.tagInfo . Sugar.tagInstance)
        viewId = tagViewId myId

makeRecordTag ::
    Monad m =>
    Mode -> NearestHoles -> Sugar.Tag (Name m) m ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeRecordTag mode nearestHoles tag =
    do
        theme <- Lens.view Theme.theme <&> Theme.name
        makeTagEdit mode (Theme.recordTagColor theme) nearestHoles tag

makeCaseTag ::
    Monad m =>
    Mode -> NearestHoles -> Sugar.Tag (Name m) m ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeCaseTag mode nearestHoles tag =
    do
        theme <- Lens.view Theme.theme <&> Theme.name
        makeTagEdit mode (Theme.caseTagColor theme) nearestHoles tag

-- | Unfocusable tag view (e.g: in apply args)
makeArgTag :: Monad m => Name m -> Sugar.EntityId -> ExprGuiM m (WithTextPos View)
makeArgTag name entityId =
    do
        theme <- Lens.view Theme.theme <&> Theme.name
        ExpressionGui.makeNameView (name ^. Name.form) animId
            & Reader.local (TextView.color .~ Theme.paramTagColor theme)
    where
        animId = WidgetIds.fromEntityId entityId & Widget.toAnimId

diveToRecordTag :: Widget.Id -> Widget.Id
diveToRecordTag = tagHoleId

diveToCaseTag :: Widget.Id -> Widget.Id
diveToCaseTag = tagHoleId
