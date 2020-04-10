-- | Build sugar expressions easily

{-# LANGUAGE TypeOperators #-}

module Test.Lamdu.SugarStubs where

import           Control.Monad.Unit (Unit(Unit))
import           Data.CurAndPrev (CurAndPrev(CurAndPrev))
import           Data.Property (Property(..))
import           Data.String (IsString(..))
import           Data.UUID.Types (UUID)
import           Hyper.Combinator.Ann (Annotated)
import           Hyper.Type.AST.FuncType (FuncType(..))
import           Hyper.Type.AST.Scheme (QVars(..))
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import           Lamdu.Data.Tag (TextsInLang(..), IsOperator(..))
import           Lamdu.I18N.Language (Language)
import           Lamdu.Name (Name)
import           Lamdu.Sugar.Internal (nameWithoutContext)
import           Lamdu.Sugar.Names.Add (InternalName(..))
import qualified Lamdu.Sugar.Names.Add as AddNames
import qualified Lamdu.Sugar.Names.Walk as NameWalk
import qualified Lamdu.Sugar.Types as Sugar

import           Test.Lamdu.Prelude

infixr 1 ~>
(~>) ::
    Annotated Sugar.EntityId # Sugar.Type name ->
    Annotated Sugar.EntityId # Sugar.Type name ->
    Annotated Sugar.EntityId # Sugar.Type name
param ~> res = FuncType param res & Sugar.TFun & Ann (Const "dummy")

nameRef :: name -> Sugar.NameRef name Unit
nameRef = (`Sugar.NameRef` Unit)

prop :: a -> Property Unit a
prop x = Property x (const Unit)

type Expr =
    Sugar.Expr (Sugar.Term (Sugar.EvaluationScopes InternalName Identity))
    InternalName Identity Unit ()

litNum :: Double -> Expr
litNum x = prop x & Sugar.LiteralNum & Sugar.BodyLiteral & expr

defRef :: String -> T.Tag -> Sugar.BinderVarRef InternalName Unit
defRef var tag =
    Sugar.BinderVarRef
    { Sugar._bvNameRef = nameRef (taggedEntityName (fromString var) tag)
    , Sugar._bvForm = Sugar.GetDefinition Sugar.DefUpToDate
    , Sugar._bvVar = fromString var
    , Sugar._bvInline = Sugar.CannotInline
    }

node ::
    h # Annotated (Sugar.Payload InternalName Identity Unit ()) ->
    Annotated (Sugar.Payload InternalName Identity Unit ()) # h
node = Const payload & Ann

labeledApplyFunc ::
    Sugar.BinderVarRef InternalName Unit ->
    Annotated (Sugar.Payload InternalName Identity Unit ()) #
    Const (Sugar.BinderVarRef InternalName Unit)
labeledApplyFunc = node . Const

type Infix2 = Expr -> Expr -> Expr

infix2Apply ::
    Sugar.BinderVarRef InternalName Unit ->
    Infix2
infix2Apply varRef l r =
    Sugar.LabeledApply (labeledApplyFunc varRef) (Sugar.Operator l r) [] []
    & Sugar.BodyLabeledApply
    & expr

arithmeticInfix2 :: String -> Infix2
arithmeticInfix2 op = infix2Apply (defRef (fromString op) (fromString op))

hole :: Expr
hole =
    Sugar.BodyHole Sugar.Hole
    { Sugar._holeOptions = mempty
    , Sugar._holeMDelete = Nothing
    } & expr

($$) :: Expr -> Expr -> Expr
func $$ arg =
    V.App func arg
    & Sugar.BodySimpleApply
    & expr

($.) :: Expr -> T.Tag -> Expr
r $. tag =
    Sugar.GetField
    { Sugar._gfRecord = r
    , Sugar._gfTag = mkTag Nothing tag
    }
    & Sugar.BodyGetField
    & expr

identity :: Expr
identity =
    defRef "id" "id"
    & Sugar.GetBinder
    & Sugar.BodyGetVar
    & expr

plus :: Infix2
plus = arithmeticInfix2 "+"

mul :: Infix2
mul = arithmeticInfix2 "*"

pane :: Sugar.Definition (Sugar.EvaluationScopes name i) name i Unit a -> Sugar.Pane name i Unit a
pane body =
    Sugar.Pane
    { Sugar._paneBody = Sugar.PaneDefinition body
    , Sugar._paneClose = Unit
    , Sugar._paneMoveDown = Nothing
    , Sugar._paneMoveUp = Nothing
    }

tagRefTag :: Maybe UUID -> T.Tag -> Sugar.Tag InternalName
tagRefTag var tag =
    Sugar.Tag
    { Sugar._tagName = maybe nameWithoutContext taggedEntityName var tag
    , Sugar._tagInstance = "dummy"
    , Sugar._tagVal = tag
    }

mkTag :: Maybe UUID -> T.Tag -> Sugar.TagRef InternalName Identity Unit
mkTag var tag =
    Sugar.TagRef
    { Sugar._tagRefReplace = tagRefReplace
    , Sugar._tagRefTag = tagRefTag var tag
    , Sugar._tagRefJumpTo = Nothing
    }

def ::
    Annotated Sugar.EntityId # Sugar.Type InternalName ->
    UUID -> T.Tag ->
    Annotated expr #
        Sugar.Assignment (Sugar.EvaluationScopes InternalName Identity)
        InternalName Identity Unit ->
    Sugar.Definition (Sugar.EvaluationScopes InternalName Identity) InternalName Identity Unit expr
def typ var tag body =
    Sugar.Definition
    { Sugar._drName = mkTag (Just var) tag
    , Sugar._drDefI = "def"
    , Sugar._drDefinitionState = prop Sugar.LiveDefinition
    , Sugar._drEntityId = "dummy"
    , Sugar._drBody =
        Sugar.DefinitionBodyExpression Sugar.DefinitionExpression
        { Sugar._deType =
            Sugar.Scheme
            { Sugar._schemeForAll = emptyForalls
            , Sugar._schemeType = typ
            }
        , Sugar._dePresentationMode = Nothing
        , Sugar._deContent = body
        }
    }
    where
        emptyForalls = T.Types (QVars mempty) (QVars mempty)

repl ::
    Annotated a # Sugar.Term (Sugar.EvaluationScopes name i) name i o ->
    Sugar.Repl name i o a
repl (Ann (Const pl) x) =
    Sugar.Repl
    { Sugar._replExpr = Ann (Const pl) (Sugar.BinderTerm x)
    , Sugar._replVarInfo = Sugar.VarGeneric
    , Sugar._replResult = CurAndPrev Nothing Nothing
    }

mkFuncParam ::
    (UUID, T.Tag) -> (Sugar.FuncParam v name, Sugar.ParamInfo InternalName Identity Unit)
mkFuncParam (paramVar, paramTag) =
    ( Sugar.FuncParam
        { Sugar._fpAnnotation = Sugar.AnnotationNone
        , Sugar._fpVarInfo = Sugar.VarGeneric
        }
    , Sugar.ParamInfo
        { Sugar._piTag = mkTag (Just paramVar) paramTag
        , Sugar._piActions =
            Sugar.FuncParamActions
            { Sugar._fpAddNext = Sugar.AddNext tagRefReplace
            , Sugar._fpDelete = Unit
            , Sugar._fpMOrderBefore = Nothing
            , Sugar._fpMOrderAfter = Nothing
            }
        }
    )

funcExpr ::
    [(UUID, T.Tag)] -> Expr ->
    Sugar.Function (Sugar.EvaluationScopes InternalName Identity) InternalName Identity Unit #
    Ann (Const (Sugar.Payload InternalName Identity Unit ()))
funcExpr params (Ann (Const ba) bx) =
    Sugar.Function
    { Sugar._fChosenScopeProp = prop Nothing & pure
    , Sugar._fBodyScopes = CurAndPrev mempty mempty
    , Sugar._fAddFirstParam = Sugar.PrependParam tagRefReplace
    , Sugar._fParams = params <&> mkFuncParam & Sugar.Params
    , Sugar._fBody = Ann (Const ba) (Sugar.BinderTerm bx)
    }

binderExpr ::
    [(UUID, T.Tag)] -> Expr ->
    Sugar.Expr (Sugar.Assignment (Sugar.EvaluationScopes InternalName Identity))
    InternalName Identity Unit ()
binderExpr params body = funcExpr params body & Sugar.BodyFunction & node

expr ::
    Sugar.Body (Sugar.Term v) InternalName Identity Unit () ->
    Sugar.Expr (Sugar.Term v) InternalName Identity Unit ()
expr = node

numType :: Annotated Sugar.EntityId # Sugar.Type InternalName
numType =
    Sugar.TInst (Sugar.TId (taggedEntityName "numTid" "num") "num") mempty
    & Ann (Const "dummy")

payload :: Sugar.Payload InternalName Identity Unit ()
payload =
    Sugar.Payload
    { Sugar._plAnnotation = Sugar.AnnotationNone
    , Sugar._plNeverShrinkTypeAnnotations = False
    , Sugar._plEntityId = "dummy"
    , Sugar._plActions = nodeActions
    , Sugar._plData = ()
    }

nodeActions :: Sugar.NodeActions InternalName Identity Unit
nodeActions =
    Sugar.NodeActions
    { Sugar._detach = Sugar.DetachAction Unit
    , Sugar._mSetToHole = Nothing
    , Sugar._setToLiteral = pure Unit
    , Sugar._setToEmptyRecord = Unit
    , Sugar._extract = Unit
    , Sugar._mReplaceParent = Nothing
    , Sugar._wrapInRecord = tagRefReplace
    , Sugar._mNewLet = Nothing
    }

taggedEntityName :: UUID -> T.Tag -> InternalName
taggedEntityName ctx tag =
    InternalName
    { _inContext = Just ctx
    , _inTag = tag
    }

tagRefReplace :: Sugar.TagReplace InternalName Identity Unit ()
tagRefReplace =
    Sugar.TagReplace
    { Sugar._tsOptions = pure []
    , Sugar._tsNewTag =
        pure Sugar.TagOption
        { Sugar._toInfo = Sugar.Tag
            { Sugar._tagName = taggedEntityName "newTag" "newTag"
            , Sugar._tagInstance = "newTag"
            , Sugar._tagVal = "newTag"
            }
        , Sugar._toPick = Unit
        }
    , Sugar._tsAnon = Nothing
    }

addNamesToExpr ::
    Language ->
    Sugar.Expr (Sugar.Term (Sugar.EvaluationScopes InternalName Identity)) InternalName Identity Unit a ->
    Sugar.Expr (Sugar.Term (Sugar.EvaluationScopes Name Identity)) Name Identity Unit a
addNamesToExpr lang x =
    AddNames.runPasses lang
    getName NameWalk.toExpression NameWalk.toExpression NameWalk.toExpression NameWalk.toExpression x
    & runIdentity

getName :: T.Tag -> Identity (IsOperator, TextsInLang)
getName =
    pure . (\x -> (NotAnOperator, TextsInLang x Nothing Nothing)) .
    fromString . show
