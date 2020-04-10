module Lamdu.GUI.Expr.LiteralEdit
    ( make
    ) where

import           Control.Lens (LensLike')
import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.Char as Char
import           Data.Property (Property)
import qualified Data.Property as Property
import qualified Data.Text as Text
import           GUI.Momentu.Align (TextWidget)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.I18N as MomentuTexts
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.ModKey (ModKey(..))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.FocusDelegator as FocusDelegator
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextEdit.Property as TextEdits
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Formatting (Format(..))
import           Lamdu.GUI.Expr.EventMap (makeLiteralEventMap)
import qualified Lamdu.GUI.Expr.HoleEdit.WidgetIds as HoleWidgetIds
import           Lamdu.GUI.ExpressionGui.Monad (GuiM)
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrap)
import           Lamdu.GUI.Styled (label)
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.Definitions as Texts
import qualified Lamdu.I18N.Name as Texts
import qualified Lamdu.I18N.Navigation as Texts
import           Lamdu.Name (Name)
import           Lamdu.Style (Style, HasStyle)
import qualified Lamdu.Style as Style
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

mkEditEventMap ::
    ( MonadReader env m
    , Has (MomentuTexts.Texts Text) env, Has (Texts.CodeUI Text) env
    , Monad o
    ) =>
    m (Text -> o Sugar.EntityId -> EventMap (o GuiState.Update))
mkEditEventMap =
    Lens.view id
    <&> \env valText setToHole ->
    setToHole <&> HoleWidgetIds.make <&> HoleWidgetIds.hidOpen
    <&> SearchMenu.enterWithSearchTerm valText
    & E.keyPresses [ModKey mempty MetaKey.Key'Enter]
    (E.toDoc env [has . MomentuTexts.edit, has . Texts.value])

withStyle ::
    (MonadReader env m, HasStyle env) =>
    Lens.Getting TextEdit.Style Style TextEdit.Style -> m a -> m a
withStyle whichStyle =
    Reader.local (\x -> x & has .~ x ^. has . whichStyle)

genericEdit ::
    ( Monad o, Format a, MonadReader env f, HasStyle env, GuiState.HasCursor env
    , Has (MomentuTexts.Texts Text) env, Has (Texts.CodeUI Text) env
    , Has Dir.Layout env
    ) =>
    LensLike' (Lens.Const TextEdit.Style) Style TextEdit.Style ->
    Property o a ->
    Sugar.Payload v name i o ExprGui.Payload -> f (Responsive o)
genericEdit whichStyle prop pl =
    do
        editEventMap <-
            case pl ^. Sugar.plActions . Sugar.mSetToHole of
            Just action -> mkEditEventMap ?? valText ?? action
            _ -> error "Cannot set literal to hole?!"
        TextView.makeFocusable ?? valText ?? myId
            <&> Align.tValue %~ Widget.weakerEvents editEventMap
            <&> Responsive.fromWithTextPos
            & withStyle whichStyle
    where
        myId = WidgetIds.fromExprPayload pl
        valText = prop ^. Property.pVal & format

fdConfig ::
    ( MonadReader env m, Has Config env, Has Menu.Config env
    , Has (MomentuTexts.Texts Text) env, Has (Texts.CodeUI Text) env
    ) =>
    m FocusDelegator.Config
fdConfig =
    Lens.view id
    <&> \env ->
    let litConf = env ^. has . Config.literal
        menuKeys = env ^. has . Menu.configKeys
    in
    FocusDelegator.Config
    { FocusDelegator.focusChildKeys = litConf ^. Config.literalStartEditingKeys
    , FocusDelegator.focusChildDoc =
        E.toDoc env
        [ has . MomentuTexts.edit
        , has . Texts.literal
        , has . Texts.startEditing
        ]
    , FocusDelegator.focusParentKeys =
        litConf ^. Config.literalStopEditingKeys
        -- The literal edit should behave like holes, in that the "pick option"
        -- key goes to the resulting expr.
        <> menuKeys ^. Menu.keysPickOption
        -- Only taken when the literal edit doesn't handle it by
        -- jumping to next entry:
        <> menuKeys ^. Menu.keysPickOptionAndGotoNext
    , FocusDelegator.focusParentDoc =
        E.toDoc env
        [ has . MomentuTexts.edit
        , has . Texts.literal
        , has . Texts.stopEditing
        ]
    }

withFd ::
    ( MonadReader env m, Has Config env, GuiState.HasCursor env
    , Has Menu.Config env, Applicative f
    , Has (MomentuTexts.Texts Text) env, Has (Texts.CodeUI Text) env
    ) =>
    m (Widget.Id -> TextWidget f -> TextWidget f)
withFd =
    (FocusDelegator.make <*> fdConfig ?? FocusDelegator.FocusEntryParent)
    <&> Lens.mapped %~ (Align.tValue %~)

textEdit ::
    ( MonadReader env m, Has Config env, HasStyle env, Has Menu.Config env
    , Element.HasAnimIdPrefix env, GuiState.HasCursor env
    , Glue.HasTexts env, TextEdit.HasTexts env
    , Has (Texts.Code Text) env, Has (Texts.CodeUI Text) env
    , Monad o
    ) =>
    Property o Text ->
    Sugar.Payload v name i o ExprGui.Payload ->
    m (TextWidget o)
textEdit prop pl =
    do
        text <- TextEdits.make ?? empty ?? prop ?? WidgetIds.literalEditOf myId
        (withFd ?? myId) <*>
            label Texts.textOpener
            /|/ pure text
            /|/ ((Align.tValue %~)
                    <$> (Element.padToSize ?? (text ^. Element.size & _1 .~ 0) ?? 1)
                    <*> label Texts.textCloser
                )
    & withStyle Style.text
    where
        empty = TextEdit.Modes "" ""
        myId = WidgetIds.fromExprPayload pl

parseNum :: Text -> Maybe Double
parseNum newText
    | newText /= Text.strip newText = Nothing
    | newText `elem` ["", "-", ".", "-."] = Just 0
    | otherwise = tryParse newText

numEdit ::
    ( MonadReader env m, Monad o
    , Has Config env, HasStyle env, Has Menu.Config env
    , Has (Texts.CodeUI Text) env, Has (MomentuTexts.Texts Text) env
    , Has (Dir.Texts Text) env, Has (Texts.Navigation Text) env
    , Has (TextEdit.Texts Text) env, Has Dir.Layout env
    , GuiState.HasState env
    ) =>
    Property o Double ->
    Sugar.Payload v name i o ExprGui.Payload ->
    m (TextWidget o)
numEdit prop pl =
    (withFd ?? myId) <*>
    do
        text <-
            GuiState.readWidgetState myId
            <&> (^? Lens._Just . Lens.filtered ((== Just prevVal) . parseNum))
            <&> fromMaybe (format prevVal)
        let preEvent =
                Widget.PreEvent
                { Widget._pDesc = ""
                , Widget._pAction = pure mempty
                , Widget._pTextRemainder = if "." `Text.isSuffixOf` text then "." else ""
                }
        pos <- TextEdit.getCursor ?? text ?? innerId <&> fromMaybe (Text.length text)
        let negateText
                | "-" `Text.isPrefixOf` text = Text.tail text
                | otherwise = "-" <> text
        toDoc <- Lens.view id <&> E.toDoc
        let negateEvent
                -- '-' at last position should apply operator rather than negate
                | pos /= Text.length text =
                    setPos (pos + Text.length negateText - Text.length text)
                    <> GuiState.updateWidgetState myId negateText
                    <$
                    (prop ^. Property.pSet) (negate curVal)
                    & const
                    & E.charGroup Nothing
                      (toDoc
                          [ has . MomentuTexts.edit
                          , has . Texts.literal
                          , has . Texts.negate
                          ]) "-"
                | otherwise = mempty
        strollEvent <-
            Lens.view (has . Menu.configKeys . Menu.keysPickOptionAndGotoNext)
            <&>
            \keys ->
            E.keysEventMap keys
            (toDoc
                [ has . MomentuTexts.navigation
                , has . Texts.nextEntry
                ])
            (pure ())
            <&> Lens.mapped . GuiState.uPreferStroll .~ (True ^. Lens._Unwrapped)
        let delEvent =
                case pl ^. Sugar.plActions . Sugar.mSetToHole of
                -- Allow to delete when text is empty
                Just action | Text.null text ->
                    E.keyPresses [ModKey mempty MetaKey.Key'Backspace]
                    (toDoc [has . MomentuTexts.edit, has . MomentuTexts.delete])
                    (action <&> WidgetIds.fromEntityId <&> GuiState.updateCursor)
                    <>
                    E.charEventMap "Letter"
                    (toDoc [has . MomentuTexts.edit, has . Texts.replace])
                    holeWithChar
                    where
                        holeWithChar c =
                            (action <&> HoleWidgetIds.make <&> HoleWidgetIds.hidOpen
                                <&> SearchMenu.enterWithSearchTerm (Text.singleton c))
                            <$ guard (Char.isAlpha c)
                _ -> mempty
        newLiteralEvent <-
            if Text.null text
            then makeLiteralEventMap ?? pl ^. Sugar.plActions
            else pure mempty
        TextEdit.make ?? empty ?? text ?? innerId
            <&> Align.tValue . Widget.eventMapMaker . Lens.mapped %~
                -- Avoid taking keys that don't belong to us,
                -- so weakerEvents with them will work.
                E.filter (Lens.has Lens._Just . parseNum . fst)
            <&> Align.tValue . Widget.updates %~ event
            <&> Align.tValue %~ Widget.strongerEvents (negateEvent <> delEvent <> newLiteralEvent <> strollEvent)
            <&> Align.tValue %~ Widget.addPreEvent preEvent
        & withStyle Style.num
    where
        prevVal = prop ^. Property.pVal
        setPos newPos = TextEdit.encodeCursor innerId newPos & GuiState.updateCursor
        innerId = WidgetIds.literalEditOf myId
        curVal = prop ^. Property.pVal
        event (newText, update) =
            GuiState.updateWidgetState myId newText <> update <$
            traverse_ (prop ^. Property.pSet) (parseNum newText)
        empty =
            TextEdit.Modes
            { TextEdit._unfocused = "0"
            , TextEdit._focused = ""
            }
        myId = WidgetIds.fromExprPayload pl

make ::
    ( Monad i, Monad o
    , Has (Texts.Name Text) env
    , Has (Texts.Code Text) env
    , Has (Texts.CodeUI Text) env
    , Has (Texts.Definitions Text) env
    , Has (Texts.Navigation Text) env
    , TextEdit.HasTexts env
    , Grid.HasTexts env
    ) =>
    Annotated (Sugar.Payload (Sugar.EvaluationScopes Name i) Name i o ExprGui.Payload) #
        Const (Sugar.Literal (Property o)) ->
    GuiM env i o (Responsive o)
make (Ann (Const pl) (Const lit)) =
    case lit of
    Sugar.LiteralNum x -> numEdit x pl <&> Responsive.fromWithTextPos
    Sugar.LiteralBytes x -> genericEdit Style.bytes x pl
    Sugar.LiteralText x -> textEdit x pl <&> Responsive.fromWithTextPos
    & stdWrap pl
