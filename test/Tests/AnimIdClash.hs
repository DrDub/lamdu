module Tests.AnimIdClash (test) where

import qualified Control.Lens as Lens
import           Control.Monad.Unit (Unit(..))
import           Data.Property (MkProperty(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.State (HasCursor(..))
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import           Hyper
import qualified Lamdu.GUI.Expr as ExpressionEdit
import qualified Lamdu.GUI.Expr.BinderEdit as BinderEdit
import qualified Lamdu.GUI.ExpressionGui.Monad as GuiM
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar
import qualified Test.Lamdu.Env as Env
import           Test.Lamdu.Gui (verifyLayers)
import           Test.Lamdu.Instances ()
import qualified Test.Lamdu.SugarStubs as Stub

import           Test.Lamdu.Prelude

test :: Test
test =
    testGroup "animid-clash"
    [ testTypeView
    , testFragment
    ]

testTypeView :: Test
testTypeView =
    do
        env <- Env.make
        TypeView.make typ env ^. Align.tValue . View.vAnimLayers
            & verifyLayers & either fail pure
    & testCase "typeview"
    where
        typ =
            recType "typ"
            [ (Sugar.Tag (Name.AutoGenerated "tag0") "tag0" "tag0", nullType "field0")
            , (Sugar.Tag (Name.AutoGenerated "tag1") "tag1" "tag1", nullType "field1")
            , (Sugar.Tag (Name.AutoGenerated "tag2") "tag2" "tag2", nullType "field2")
            ]
        nullType entityId = recType entityId []
        recType ::
            Sugar.EntityId ->
            [(Sugar.Tag Name.Name, Annotated Sugar.EntityId (Sugar.Type Name.Name))] ->
            Annotated Sugar.EntityId (Sugar.Type Name.Name)
        recType entityId fields =
            Sugar.CompositeFields
            { Sugar._compositeFields = fields
            , Sugar._compositeExtension = Nothing
            }
            & Sugar.TRecord
            & Ann (Const entityId)

adhocPayload :: ExprGui.Payload
adhocPayload =
    ExprGui.Payload
    { ExprGui._plHiddenEntityIds = []
    , ExprGui._plNeedParens = False
    , ExprGui._plMinOpPrec = 13
    }

testFragment :: Test
testFragment =
    do
        env <-
            Env.make
            <&> cursor .~ WidgetIds.fromEntityId fragEntityId
        let expr =
                ( Sugar.BodyFragment Sugar.Fragment
                    { Sugar._fExpr = Stub.litNum 5
                    , Sugar._fHeal = error "Not Implemented" -- not necessary for test!
                    , Sugar._fTypeMismatch = Nothing
                    , Sugar._fOptions = pure []
                    } & Stub.expr
                )
                & annotation . Sugar.plEntityId .~ fragEntityId
                & Stub.addNamesToExpr (env ^. has)
                & hflipped %~ hmap (const (Lens._Wrapped . Sugar.plData .~ adhocPayload))
        let assocTagName _ = MkProperty Unit
        let gui =
                ExpressionEdit.make expr
                & GuiM.run assocTagName ExpressionEdit.make BinderEdit.make
                Env.dummyAnchors env (const Unit)
                & runIdentity
        let widget = gui ^. Responsive.rWide . Align.tValue
        case widget ^. Widget.wState of
            Widget.StateUnfocused{} -> fail "Expected focused widget"
            Widget.StateFocused mk ->
                mk (Widget.Surrounding 0 0 0 0) ^. Widget.fLayers & verifyLayers & either fail pure
        pure ()
    & testCase "fragment"
    where
        fragEntityId = "frag"
