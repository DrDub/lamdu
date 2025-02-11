-- | Widget to edit the settings
{-# LANGUAGE TemplateHaskell, RankNTypes #-}
module Lamdu.GUI.Settings
    ( StatusWidgets(..), annotationWidget, themeWidget, languageWidget, helpWidget
    , TitledSelection(..), title, selection
    , makeStatusWidgets
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property, composeLens)
import           GUI.Momentu.Align (WithTextPos(..))
import qualified GUI.Momentu.Animation.Id as AnimId
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.I18N as Texts
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widget.Id as WidgetId
import           GUI.Momentu.Widgets.EventMapHelp (IsHelpShown(..))
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Annotations as Ann
import qualified Lamdu.Config as Config
import           Lamdu.Config.Folder (Selection)
import qualified Lamdu.Config.Folder as Folder
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.Sprites as Sprites
import           Lamdu.GUI.StatusBar.Common (StatusWidget)
import qualified Lamdu.GUI.StatusBar.Common as StatusBar
import           Lamdu.GUI.Styled (OneOfT(..))
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.StatusBar as Texts
import           Lamdu.Settings (Settings)
import qualified Lamdu.Settings as Settings

import           Lamdu.Prelude

data StatusWidgets a = StatusWidgets
    { _annotationWidget :: a
    , _themeWidget      :: a
    , _languageWidget   :: a
    , _helpWidget       :: a
    } deriving (Functor, Foldable, Traversable)
Lens.makeLenses ''StatusWidgets

data TitledSelection a = TitledSelection
    { _title :: !Text
    , _selection :: !(Selection a)
    }
Lens.makeLenses ''TitledSelection

makeAnnotationsSwitcher :: _ => Property f Ann.Mode -> m (StatusBar.StatusWidget f)
makeAnnotationsSwitcher annotationModeProp =
    do
        mk0 <- Styled.mkFocusableLabel
        mk1 <- Styled.mkFocusableLabel
        [ (Ann.Evaluation, mk0 (OneOf Texts.evaluation))
            , (Ann.Types, mk1 (OneOf Texts.sbTypes))
            , (Ann.None, mk1 (OneOf Texts.sbNone))
            ]
            & StatusBar.makeSwitchStatusWidget
                (Styled.sprite Sprites.pencilLine <&> WithTextPos 0)
                Texts.sbAnnotations Texts.sbSwitchAnnotations
            Config.nextAnnotationModeKeys annotationModeProp

makeStatusWidgets ::
    (MonadReader env m, _) =>
    [TitledSelection Folder.Theme] -> [TitledSelection Folder.Language] ->
    Property f Settings -> m (StatusWidgets (StatusWidget f))
makeStatusWidgets themeNames langNames prop =
    sequenceA
    StatusWidgets
    { _annotationWidget =
        makeAnnotationsSwitcher (composeLens Settings.sAnnotationMode prop)
        & local (Element.animIdPrefix <>~ ["Annotations Mode"])
    , _themeWidget =
        traverse opt themeNames
        >>= StatusBar.makeSwitchStatusWidget
        (Styled.sprite Sprites.theme <&> WithTextPos 0)
        Texts.sbTheme Texts.sbSwitchTheme
        Config.changeThemeKeys themeProp
        & local (Element.animIdPrefix <>~ ["Theme Select"])
    , _languageWidget =
       traverse opt langNames
        >>= StatusBar.makeSwitchStatusWidget
        (Styled.sprite Sprites.earthGlobe <&> WithTextPos 0)
        Texts.language Texts.sbSwitchLanguage
        Config.changeLanguageKeys langProp
        & local (Element.animIdPrefix <>~ ["Language Select"])
    , _helpWidget =
        helpVals
        >>= StatusBar.makeSwitchStatusWidget
        (pure Element.empty)
        Texts.sbHelp Texts.sbSwitchHelp
        Config.helpKeys helpProp
        & local (Element.animIdPrefix <>~ ["Help Select"])
    }
    where
        helpHiddenSprite = Styled.sprite Sprites.help
        helpShownSprite =
            do
                iconTint <- Lens.view (has . Theme.help . Theme.helpShownIconTint)
                Styled.sprite Sprites.help <&> Element.tint iconTint
        makeFocusable animId mkView =
            (Widget.makeFocusableView ?? Widget.Id animId) <*> mkView
            <&> WithTextPos 0
            & local (Element.animIdPrefix .~ animId)

        opt sel =
            (TextView.makeFocusable ?? sel ^. title)
            <*> (Lens.view Element.animIdPrefix
                    <&> AnimId.augmentId (sel ^. selection)
                    <&> WidgetId.Id)
            <&> (,) (sel ^. selection)
        helpVals =
            Lens.sequenceOf (Lens.traverse . _2)
            [ (HelpNotShown, makeFocusable ["Help hidden"] helpHiddenSprite)
            , (HelpShown, makeFocusable ["Help shown"] helpShownSprite)
            ]
        themeProp = composeLens Settings.sSelectedTheme prop
        langProp = composeLens Settings.sSelectedLanguage prop
        helpProp = composeLens Settings.sHelpShown prop
