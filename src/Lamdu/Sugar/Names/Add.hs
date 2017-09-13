{-# LANGUAGE LambdaCase, NoImplicitPrelude, GeneralizedNewtypeDeriving, RecordWildCards, TypeFamilies, TemplateHaskell, DeriveGeneric, KindSignatures, NoMonomorphismRestriction, OverloadedStrings #-}
module Lamdu.Sugar.Names.Add
    ( addToWorkArea
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Trans.FastWriter (Writer, runWriter)
import qualified Control.Monad.Trans.FastWriter as Writer
import           Control.Monad.Trans.Reader (Reader, runReader)
import qualified Control.Monad.Trans.Reader as Reader
import           Control.Monad.Trans.State (runState, evalState)
import           Data.List (nub)
import qualified Data.List.Utils as ListUtils
import qualified Data.Map as Map
import qualified Data.Map.Utils as MapUtils
import           Data.Monoid.Generic (def_mempty, def_mappend)
import qualified Data.Set as Set
import           Data.Set.Ordered (OrderedSet)
import qualified Data.Set.Ordered as OrderedSet
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Data.Text as Text
import           Data.UUID.Types (UUID)
import           GHC.Generics (Generic)
import           Lamdu.Data.Anchors (assocNameRef)
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.Names.CPS (CPS(..))
import           Lamdu.Sugar.Names.NameGen (NameGen)
import qualified Lamdu.Sugar.Names.NameGen as NameGen
import           Lamdu.Sugar.Names.Types
import           Lamdu.Sugar.Names.Walk (MonadNaming)
import qualified Lamdu.Sugar.Names.Walk as Walk
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

type T = Transaction
type StoredName = Text

------------------------------
---------- Pass 0 ------------
------------------------------
data P0Name = P0Name
    { _mStoredName :: Maybe StoredName
    , _mStoredUUID :: UUID
    }

newtype Pass0LoadNames tm a = Pass0LoadNames { runPass0LoadNames :: T tm a }
    deriving (Functor, Applicative, Monad)

instance Monad tm => MonadNaming (Pass0LoadNames tm) where
    type OldName (Pass0LoadNames tm) = UUID
    type NewName (Pass0LoadNames tm) = P0Name
    type TM (Pass0LoadNames tm) = tm
    opRun = pure runPass0LoadNames
    opWithParamName _ = p0cpsNameConvertor
    opWithLetName _ = p0cpsNameConvertor
    opWithTagName = p0cpsNameConvertor
    opGetName _ = p0nameConvertor

getP0Name :: Monad tm => UUID -> Pass0LoadNames tm P0Name
getP0Name uuid =
    Pass0LoadNames $ do
        nameStr <- Transaction.getP $ assocNameRef uuid
        pure P0Name
            { _mStoredName = if Text.null nameStr then Nothing else Just nameStr
            , _mStoredUUID = uuid
            }

p0nameConvertor :: Monad tm => Walk.NameConvertor (Pass0LoadNames tm)
p0nameConvertor = getP0Name

p0cpsNameConvertor :: Monad tm => Walk.CPSNameConvertor (Pass0LoadNames tm)
p0cpsNameConvertor uuid =
    CPS $ \k -> (,) <$> getP0Name uuid <*> k

------------------------------
---------- Pass 1 ------------
------------------------------

-- | Info about a single instance of use of a name:
data NameInstance = NameInstance
    { _niUUID :: !UUID
    , -- | Is the name used in a function application context? We consider
      -- the application as a disambiguator
      _niMApplied :: !(Maybe Walk.FunctionSignature)
    , _niNameType :: !Walk.NameType
    } deriving (Eq, Ord, Show)
Lens.makeLenses ''NameInstance

-- Wrap the Map for a more sensible (recursive) Monoid instance
newtype NameUUIDMap = NameUUIDMap (Map Text (OrderedSet NameInstance))
    deriving Show

type instance Lens.Index NameUUIDMap = Text
type instance Lens.IxValue NameUUIDMap = OrderedSet NameInstance

instance Lens.Ixed NameUUIDMap where
    ix k f (NameUUIDMap m) = NameUUIDMap <$> Lens.ix k f m
    {-# INLINE ix #-}
instance Lens.At NameUUIDMap where
    at k f (NameUUIDMap m) = NameUUIDMap <$> Lens.at k f m
    {-# INLINE at #-}

instance Monoid NameUUIDMap where
    mempty = NameUUIDMap Map.empty
    NameUUIDMap x `mappend` NameUUIDMap y =
        NameUUIDMap $ Map.unionWith mappend x y

nameUUIDMapSingleton :: Text -> NameInstance -> NameUUIDMap
nameUUIDMapSingleton name nameInstance =
    OrderedSet.singleton nameInstance & Map.singleton name & NameUUIDMap

data NamesWithin = NamesWithin
    { _localNames :: NameUUIDMap
    , _allNames :: NameUUIDMap
    } deriving (Generic)
Lens.makeLenses ''NamesWithin
instance Monoid NamesWithin where
    mempty = def_mempty
    mappend = def_mappend

newtype P1Out = P1Out { _p1Names :: NamesWithin }
    deriving (Monoid)

data P1Name = P1Name
    { p1StoredName :: Maybe StoredName
    , p1StoredUUID :: UUID
    , -- | We keep the names underneath each node so we can check if
      -- an auto-generated name (in pass2) conflicts with any name in
      -- inner scopes (below)
      p1NamesWithin :: NamesWithin
    }
newtype Pass1PropagateUp (tm :: * -> *) a = Pass1PropagateUp (Writer P1Out a)
    deriving (Functor, Applicative, Monad)
p1Tell :: P1Out -> Pass1PropagateUp tm ()
p1Tell = Pass1PropagateUp . Writer.tell
p1Listen :: Pass1PropagateUp tm a -> Pass1PropagateUp tm (a, P1Out)
p1Listen (Pass1PropagateUp act) = Pass1PropagateUp $ Writer.listen act
runPass1PropagateUp :: Pass1PropagateUp tm a -> (a, P1Out)
runPass1PropagateUp (Pass1PropagateUp act) = runWriter act

p1TellNames :: NamesWithin -> Pass1PropagateUp tm ()
p1TellNames names = p1Tell mempty { _p1Names = names }

p1ListenNames :: Pass1PropagateUp tm a -> Pass1PropagateUp tm (a, NamesWithin)
p1ListenNames act = p1Listen act <&> _2 %~ _p1Names

data NameScope = Local | Global

nameTypeScope :: Walk.NameType -> NameScope
nameTypeScope Walk.ParamName = Local
nameTypeScope Walk.TagName = Global
nameTypeScope Walk.NominalName = Global
nameTypeScope Walk.DefName = Global

instance Monad tm => MonadNaming (Pass1PropagateUp tm) where
    type OldName (Pass1PropagateUp tm) = P0Name
    type NewName (Pass1PropagateUp tm) = P1Name
    type TM (Pass1PropagateUp tm) = tm
    opRun = pure (return . fst . runPass1PropagateUp)
    opWithParamName _ = p1cpsNameConvertor Walk.ParamName
    opWithLetName _ = p1cpsNameConvertor Walk.ParamName
    opWithTagName = p1cpsNameConvertor Walk.TagName
    opGetName = p1nameConvertor Nothing
    opGetAppliedFuncName = p1nameConvertor . Just

unnamedStr :: Text
unnamedStr = "Unnamed"

pass1Result ::
    Maybe Walk.FunctionSignature -> Walk.NameType -> P0Name ->
    CPS (Pass1PropagateUp tm) P1Name
pass1Result mApplied nameType (P0Name mName uuid) =
    CPS $ \inner ->
    do
        p1TellNames myNamesWithin
        (r, namesUnder) <- p1ListenNames inner
        pure
            ( P1Name
                { p1StoredName = mName
                , p1StoredUUID = uuid
                , p1NamesWithin = myNamesWithin `mappend` namesUnder
                }
            , r
            )
    where
        scope = nameTypeScope nameType
        myNamesWithin =
            case (scope, mName) of
            (_, Just name) -> Just name
            (Local, Nothing) -> mempty
            (Global, Nothing) -> Just unnamedStr
            & maybe mempty singleton
            & createNamesWithin
        singleton nameText =
            nameUUIDMapSingleton nameText
            NameInstance
            { _niUUID = uuid
            , _niMApplied = mApplied
            , _niNameType = nameType
            }
        createNamesWithin m =
            mempty
            & case scope of
            Local ->  (allNames .~ m) . (localNames .~ m)
            Global ->  allNames .~ m

p1nameConvertor :: Maybe Walk.FunctionSignature -> Walk.NameType -> Walk.NameConvertor (Pass1PropagateUp tm)
p1nameConvertor mApplied nameType mStoredName =
    runCPS (pass1Result mApplied nameType mStoredName) (pure ()) <&> fst

p1cpsNameConvertor :: Walk.NameType -> Walk.CPSNameConvertor (Pass1PropagateUp tm)
p1cpsNameConvertor = pass1Result Nothing

------------------------------
---------- Pass 2 ------------
------------------------------

data P2Env = P2Env
    { _p2NameGen :: NameGen UUID
    , _p2NameSuffixes :: Map UUID Int
    , -- | Names used in containing scopes (above) -- used to avoid
      -- generating an automatic name that conflicts with a name above
      _p2Names :: Set Text
    }
Lens.makeLenses ''P2Env

-- | Textual Name ambiguity
--
-- In the visible grammar, there are different types of names (see
-- Walk.NameType):
-- DefName, TagName, NominalName, ParamName
--
-- Each type can collide with itself. Nominals can only collide with
-- themselves (due to their grammatic context being unique).
--
-- Definitions and tags cannot collide with each other but both
-- can collide with param names.
--
-- Hence, we check collisions in three groups:
-- * Nominals
-- * Tags+Params
-- * Defs+Params
--
-- Defs+Params can also be disambiguated if used exclusively in
-- labeled apply contexts, and with differing signatures.

uuidSuffixes :: OrderedSet NameInstance -> Map UUID Int
uuidSuffixes nameInstances
    | namesClash (getNames Walk.NominalName)
    || namesClash (getNames Walk.TagName ++ getNames Walk.ParamName)
    || namesClash (getNames Walk.DefName ++ getNames Walk.ParamName)
    = zip uuids [0..] & Map.fromList
    | otherwise = mempty
    where
        getNames nameType = byType ^. Lens.ix nameType
        byType =
            nameInstances ^.. Lens.folded & MapUtils.partition (^. niNameType)
        uuids = nameInstances ^.. Lens.folded . niUUID & nub

-- | Given a list of UUIDs that are being referred to via the same
-- textual name, generate a suffix map
namesClash :: [NameInstance] -> Bool
namesClash nameInstances =
    Set.size uuids >= 2
    &&
    ( ListUtils.isLengthAtLeast 2 nameRefs
      || hasBothTypes
      || hasSameCallType
    )
    where
        uuids = nameInstances ^.. Lens.folded . niUUID & Set.fromList
        nameRefs = nameInstances ^.. Lens.folded . niMApplied . Lens._Nothing
        nameApps = nameInstances ^.. Lens.folded . niMApplied . Lens._Just
        -- | Same textual name used both as an application and as a
        -- normal name:
        hasBothTypes = not (null nameRefs) && not (null nameApps)
        -- | Multiple applications have same signature for differing
        -- UUIDs, still ambiguous:
        hasSameCallType = uniqueCount nameApps < length nameApps
        uniqueCount = Set.size . Set.fromList

initialP2Env :: NameUUIDMap -> P2Env
initialP2Env (NameUUIDMap allNamesMap) =
    P2Env
    { _p2NameGen = NameGen.initial
    , _p2Names = mempty
    , _p2NameSuffixes = allNamesMap ^.. traverse <&> uuidSuffixes & mconcat
    }

newtype Pass2MakeNames (tm :: * -> *) a = Pass2MakeNames (Reader P2Env a)
    deriving (Functor, Applicative, Monad)
runPass2MakeNames :: P2Env -> Pass2MakeNames tm a -> a
runPass2MakeNames initial (Pass2MakeNames act) = runReader act initial
p2GetEnv :: Pass2MakeNames tm P2Env
p2GetEnv = Pass2MakeNames Reader.ask
p2WithEnv :: (P2Env -> P2Env) -> Pass2MakeNames tm a -> Pass2MakeNames tm a
p2WithEnv f (Pass2MakeNames act) = Pass2MakeNames $ Reader.local f act

runPass2MakeNamesInitial :: P1Out -> Pass2MakeNames tm a -> a
runPass2MakeNamesInitial (P1Out namesWithin) =
    runPass2MakeNames (initialP2Env (namesWithin ^. allNames))

setUuidName :: Monad tm => UUID -> StoredName -> T tm ()
setUuidName = Transaction.setP . assocNameRef

getCollision :: Text -> NamesWithin -> UUID -> P2Env -> (Collision, P2Env)
getCollision name namesWithin uuid env =
    (collision, newEnv)
    where
        (collision, newEnv) =
            case (mSuffixFromAbove, collidingUUIDs) of
                (Just suffix, _) -> (Collision suffix, env)
                (Nothing, []) -> (NoCollision, envWithName [])
                (Nothing, otherUUIDs) -> (Collision 0, envWithName (uuid:otherUUIDs))
        envWithName uuids =
            env
            & p2Names %~ Set.insert name
            -- This name is first occurence, so we get suffix 0
            & p2NameSuffixes <>~ Map.fromList (uuids & Lens.itraversed %@~ flip (,))
        mSuffixFromAbove =
            Map.lookup uuid $ env ^. p2NameSuffixes
        collidingUUIDs =
            namesWithin
            ^.. localNames . Lens.at name . Lens._Just .
                Lens.folded . niUUID . Lens.filtered (/= uuid)
            & nub

-- makeFinalForm ::
--     Monad tm => Form -> Text -> NamesWithin -> UUID -> P2Env -> Name tm
-- makeFinalForm form storedName namesWithin uuid env =
--     fst $ makeFinalFormEnv src storedName namesWithin uuid env

instance Monad tm => MonadNaming (Pass2MakeNames tm) where
    type OldName (Pass2MakeNames tm) = P1Name
    type NewName (Pass2MakeNames tm) = Name tm
    type TM (Pass2MakeNames tm) = tm
    opRun = p2GetEnv <&> runPass2MakeNames <&> (return .)
    opWithTagName = p2cpsNameConvertorGlobal
    opWithParamName = p2cpsNameConvertorLocal
    opWithLetName = p2cpsNameConvertorLocal
    opGetName Walk.ParamName (P1Name mStoredName uuid namesUnder) =
        case mStoredName of
            Just storedName ->
                do
                    env <- p2GetEnv
                    let collision = getCollision storedName namesUnder uuid env & fst
                    Stored storedName collision & pure
            Nothing ->
                do
                    nameGen <- p2GetEnv <&> (^. p2NameGen)
                    let name = evalState (NameGen.existingName uuid) nameGen
                    AutoGenerated name & pure
        <&> (`Name` setUuidName uuid)
    opGetName Walk.TagName x = p2nameConvertorGlobal x
    opGetName Walk.NominalName x = p2nameConvertorGlobal x
    opGetName Walk.DefName x = p2nameConvertorGlobal x

p2cpsNameConvertor ::
    Monad tm =>
    P1Name ->
    (P2Env -> (Form, P2Env)) ->
    CPS (Pass2MakeNames tm) (Name tm)
p2cpsNameConvertor (P1Name mStoredName uuid namesWithin) nameMaker =
    CPS $ \k ->
    do
        oldEnv <- p2GetEnv
        let (newName, newEnv) =
                case mStoredName of
                Just storedName ->
                    getCollision storedName namesWithin uuid oldEnv
                    & _1 %~ Stored storedName
                Nothing -> nameMaker oldEnv
                & _1 %~ (`Name` setUuidName uuid)
        res <- p2WithEnv (const newEnv) k
        return (newName, res)

p2cpsNameConvertorGlobal :: Monad tm => Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorGlobal p1out =
    p2cpsNameConvertor p1out $
    \env ->
        let (collision, newEnv) =
                getCollision unnamedStr
                (p1NamesWithin p1out) (p1StoredUUID p1out) env
        in  (Unnamed collision, newEnv)

p2cpsNameConvertorLocal ::
    Monad tm => NameGen.VarInfo -> Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorLocal isFunction p1out =
    p2cpsNameConvertor p1out $ \p2env ->
    let accept name =
            Lens.hasn't (localNames . Lens.at name . Lens._Just) namesWithin
            && not (p2env ^. p2Names . Lens.contains name)
    in  NameGen.newName accept isFunction uuid
        <&> AutoGenerated
        & Lens.zoom p2NameGen
        & (`runState` p2env)
    where
        P1Name _ uuid namesWithin = p1out

p2nameConvertorGlobal :: Monad tm => Walk.NameConvertor (Pass2MakeNames tm)
p2nameConvertorGlobal (P1Name mStoredName uuid namesWithin) =
    p2GetEnv
    <&> getCollision name namesWithin uuid
    <&> fst
    <&> mk
    <&> (`Name` setUuidName uuid)
    where
        (mk, name) =
            case mStoredName of
            Nothing -> (Unnamed, unnamedStr)
            Just storedName -> (Stored storedName, storedName)

fixVarToTags :: Monad m => VarToTags -> T m ()
fixVarToTags VarToTags {..} =
    Transaction.getP (assocNameRef vttReplacedVar)
    >>= Transaction.setP (assocNameRef (vttReplacedByTag ^. tagVal))

fixParamAddResult :: Monad m => ParamAddResult -> T m ()
fixParamAddResult (ParamAddResultVarToTags v) = fixVarToTags v
fixParamAddResult _ = return ()

fixParamDelResult :: Monad m => ParamDelResult -> T m ()
fixParamDelResult (ParamDelResultTagsToVar TagsToVar {..}) =
    Transaction.getP (assocNameRef (ttvReplacedTag ^. tagVal))
    >>= Transaction.setP (assocNameRef ttvReplacedByVar)
fixParamDelResult _ = return ()

fixLetFloatResult :: Monad m => LetFloatResult -> T m ()
fixLetFloatResult = traverse_ fixVarToTags . lfrMVarToTags

-- mutual recursion fixBinder<->fixExpr

fixBinder ::
    Monad m =>
    Binder name m (Expression name m a) ->
    Binder name m (Expression name m a)
fixBinder binder =
    binder
    & SugarLens.binderFuncParamAdds %~ postProcess fixParamAddResult
    & SugarLens.binderFuncParamDeletes %~ postProcess fixParamDelResult
    & bBody . bbContent %~ fixBinderContent
    where
        fixBinderContent x =
            x
            & _BinderExpr %~ fixExpr
            & _BinderLet . lValue %~ fixBinder
            & _BinderLet . lBody . bbContent %~ fixBinderContent
            & _BinderLet . lActions . laFloat %~ postProcess fixLetFloatResult
        postProcess f action =
            do
                res <- action
                () <- f res
                return res

fixExpr :: Monad m => Expression name m a -> Expression name m a
fixExpr expr =
    expr & rBody %~ \case
    BodyLam lam -> lam & lamBinder %~ fixBinder & BodyLam
    body -> body <&> fixExpr

runPasses ::
    Functor tm =>
    (a -> Pass0LoadNames tm b) -> (b -> Pass1PropagateUp tm c) -> (c -> Pass2MakeNames tm d) ->
    a -> T tm d
runPasses f0 f1 f2 =
    fmap (pass2 . pass1) . pass0
    where
        pass0 = runPass0LoadNames . f0
        pass1 = runPass1PropagateUp . f1
        pass2 (x, p1out) =
            f2 x & runPass2MakeNamesInitial p1out

fixDef ::
    Monad tm =>
    Definition name tm (Expression name tm a) ->
    Definition name tm (Expression name tm a)
fixDef = drBody . _DefinitionBodyExpression . deContent %~ fixBinder

addToWorkArea :: Monad tm => WorkArea UUID tm a -> T tm (WorkArea (Name tm) tm a)
addToWorkArea workArea =
    workArea
    & waPanes . traverse . paneDefinition %~ fixDef
    & waRepl %~ fixExpr
    & runPasses f f f
    where
        f = Walk.toWorkArea
