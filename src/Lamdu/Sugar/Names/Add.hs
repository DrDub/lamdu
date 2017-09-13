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
import           Data.List (partition)
import qualified Data.Map as Map
import           Data.Map.Utils (unionWithM)
import           Data.Monoid.Generic (def_mempty, def_mappend)
import qualified Data.Set as Set
import           Data.Set.Ordered (OrderedSet)
import qualified Data.Set.Ordered as OrderedSet
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Data.Text as Text
import           Data.Tuple (swap)
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
    opWithParamName _ _ = p0cpsNameConvertor
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

type Disambiguator = Walk.FunctionSignature

-- | Info about a single instance of use of a name:
data NameInstance = NameInstance
    { _niUUID :: !UUID
    , -- | Is the name used in a function application context? We consider
      -- the application as a disambiguator
      niDisambiguator :: !(Maybe Disambiguator)
    , _niNameType :: !Walk.NameType
    } deriving (Eq, Ord, Show)
Lens.makeLenses ''NameInstance

-- Wrap the Map for a more sensible (recursive) Monoid instance
newtype NameUUIDMap = NameUUIDMap { _nameUUIDMap :: Map Text (OrderedSet NameInstance) }
    deriving Show
Lens.makeLenses ''NameUUIDMap

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
        NameUUIDMap $ Map.unionWith (flip mappend) x y

nameUUIDMapSingleton :: Text -> NameInstance -> NameUUIDMap
nameUUIDMapSingleton name nameInstance =
    OrderedSet.singleton nameInstance & Map.singleton name & NameUUIDMap

isGlobal :: NameInstance -> Bool
isGlobal = (/= Walk.ParamName) . (^. niNameType)

localNames :: NameUUIDMap -> NameUUIDMap
localNames = nameUUIDMap . Lens.mapped %~ OrderedSet.filter (not . isGlobal)

globalNames :: NameUUIDMap -> NameUUIDMap
globalNames = nameUUIDMap . Lens.mapped %~ OrderedSet.filter isGlobal


data P1Out = P1Out
    { _p1Names :: NameUUIDMap
    , _p1Collisions :: Set Text
    } deriving (Generic)
instance Monoid P1Out where
    mempty = def_mempty
    mappend = def_mappend

data P1Name = P1Name
    { p1StoredName :: Maybe StoredName
    , p1Instance :: NameInstance
    , -- | We keep the names below each node so we can check if an
      -- auto-generated name (in pass2) collides with any name in
      -- inner scopes (below)
      p1NamesBelow :: NameUUIDMap
    }
newtype Pass1PropagateUp (tm :: * -> *) a = Pass1PropagateUp (Writer P1Out a)
    deriving (Functor, Applicative, Monad)
p1Tell :: P1Out -> Pass1PropagateUp tm ()
p1Tell = Pass1PropagateUp . Writer.tell
p1Listen :: Pass1PropagateUp tm a -> Pass1PropagateUp tm (a, P1Out)
p1Listen (Pass1PropagateUp act) = Pass1PropagateUp $ Writer.listen act
runPass1PropagateUp :: Pass1PropagateUp tm a -> (a, P1Out)
runPass1PropagateUp (Pass1PropagateUp act) = runWriter act & _2 %~ p1PostProcess

type CollisionGroup = [Walk.NameType]

collisionGroups :: [CollisionGroup]
collisionGroups =
    [ [ Walk.DefName, Walk.ParamName, Walk.FieldParamName ]
    , [ Walk.TagName, Walk.FieldParamName ]
    , [ Walk.NominalName ]
    ]

data GroupNameContext = Ambiguous UUID | Disambiguated (Map Disambiguator UUID)

-- A valid (non-clashing) context for a single name where multiple
-- UUIDs may coexist
type NameContext = Map CollisionGroup GroupNameContext

groupNameContextCombine :: GroupNameContext -> GroupNameContext -> Maybe GroupNameContext
groupNameContextCombine a b =
    case (a, b) of
    (Ambiguous uuid, Disambiguated m) -> combineAD uuid m
    (Disambiguated m, Ambiguous uuid) -> combineAD uuid m
    (Ambiguous x, Ambiguous y)
        | x == y -> Just (Ambiguous x)
        | otherwise -> Nothing
    (Disambiguated x, Disambiguated y)
        | Map.intersectionWith (/=) x y & or -> Nothing
        | otherwise -> x <> y & Disambiguated & Just
    where
        combineAD uuid m
            | m ^.. Lens.folded & filter (/= uuid) & null = Just (Ambiguous uuid)
            | otherwise = Nothing

nameContextCombine :: NameContext -> NameContext -> Maybe NameContext
nameContextCombine = unionWithM groupNameContextCombine

groupNameContextOf :: NameInstance -> GroupNameContext
groupNameContextOf (NameInstance uuid Nothing _) = Ambiguous uuid
groupNameContextOf (NameInstance uuid (Just d) _) = Map.singleton d uuid & Disambiguated

nameContextOf :: NameInstance -> NameContext
nameContextOf inst =
    filter (inst ^. niNameType `elem`) collisionGroups
    <&> ((,) ?? ctx)
    & Map.fromList
    where
        ctx = groupNameContextOf inst

data IsClash = Clash | NoClash NameContext
isClash :: IsClash -> Bool
isClash Clash = True
isClash NoClash {} = False

isClashOf :: NameInstance -> IsClash
isClashOf = NoClash . nameContextOf

instance Monoid IsClash where
    mempty = NoClash mempty
    mappend (NoClash x) (NoClash y) =
        case nameContextCombine x y of
        Nothing -> Clash
        Just ctx -> NoClash ctx
    mappend _ _ = Clash

checkClash :: [NameInstance] -> IsClash
checkClash ns = ns <&> isClashOf & mconcat

globalCollisions :: NameUUIDMap -> Set Text
globalCollisions (NameUUIDMap names) =
    Map.filter (namesClash . (^.. Lens.folded)) names & Map.keysSet
    where
        namesClash ns =
            case checkClash globals of
            Clash -> True
            noClash -> any (isClash . (noClash <>) . isClashOf) locals
            where
                isLocal = (== Walk.ParamName) . (^. niNameType)
                (locals, globals) = partition isLocal ns


-- | Compute the global collisions to form ALL collisions and yield
-- the global names only
p1PostProcess :: P1Out -> P1Out
p1PostProcess (P1Out names localCollisions) =
    P1Out names (localCollisions <> globalCollisions names)

p1ListenNames :: Pass1PropagateUp tm a -> Pass1PropagateUp tm (a, NameUUIDMap)
p1ListenNames act = p1Listen act <&> _2 %~ _p1Names

data NameScope = Local | Global
    deriving Eq

nameTypeScope :: Walk.NameType -> NameScope
nameTypeScope Walk.ParamName = Local
nameTypeScope Walk.FieldParamName = Local
nameTypeScope Walk.TagName = Global
nameTypeScope Walk.NominalName = Global
nameTypeScope Walk.DefName = Global

instance Monad tm => MonadNaming (Pass1PropagateUp tm) where
    type OldName (Pass1PropagateUp tm) = P0Name
    type NewName (Pass1PropagateUp tm) = P1Name
    type TM (Pass1PropagateUp tm) = tm
    opRun = pure (return . fst . runPass1PropagateUp)
    opWithParamName GetFieldParameter _ = p1cpsNameConvertor Walk.FieldParamName
    opWithParamName GetParameter _ = p1cpsNameConvertor Walk.ParamName
    opWithLetName _ = p1cpsNameConvertor Walk.ParamName
    opWithTagName = p1cpsNameConvertor Walk.TagName
    opGetName = p1nameConvertor Nothing
    opGetAppliedFuncName = p1nameConvertor . Just

unnamedStr :: Text
unnamedStr = "Unnamed"

pass1Result ::
    Maybe Disambiguator -> Walk.NameType -> P0Name ->
    CPS (Pass1PropagateUp tm) P1Name
pass1Result mApplied nameType (P0Name mName uuid) =
    CPS $ \inner ->
    do
        (r, namesBelow) <- p1ListenNames inner
        let checkLocalCollision name =
                localNames namesBelow ^.. Lens.ix name . Lens.folded
                & checkClash & isClash
        let localCollisions =
                case (scope, mName) of
                (Local, Just name)
                    | checkLocalCollision name -> Set.singleton name
                _ -> mempty
        p1Tell P1Out { _p1Names = myNameUUIDMap, _p1Collisions = localCollisions }
        pure
            ( P1Name
                { p1StoredName = mName
                , p1Instance = nameInstance
                , p1NamesBelow = myNameUUIDMap `mappend` namesBelow
                }
            , r
            )
    where
        scope = nameTypeScope nameType
        myNameUUIDMap =
            case (scope, mName) of
            (_, Just name) -> Just name
            (Local, Nothing) -> mempty
            (Global, Nothing) -> Just unnamedStr
            & maybe mempty singleton
        nameInstance =
            NameInstance
            { _niUUID = uuid
            , niDisambiguator = mApplied
            , _niNameType = nameType
            }
        singleton nameText = nameUUIDMapSingleton nameText nameInstance

p1nameConvertor :: Maybe Disambiguator -> Walk.NameType -> Walk.NameConvertor (Pass1PropagateUp tm)
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
      -- generating an automatic name that collides with a name above
      -- and to generate "UnknownCollision" inside hole results
      _p2NamesAbove :: Map Text IsClash
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
-- * NominalIds
-- * Tags+FieldParams
-- * Defs+FieldParams+Vars
--
-- Defs+Params can also be disambiguated if used exclusively in
-- labeled apply contexts, and with differing signatures.

uuidSuffixes :: OrderedSet NameInstance -> Map UUID Int
uuidSuffixes nameInstances =
    nameInstances ^@.. Lens.folded <. niUUID <&> swap & Map.fromList

initialP2Env :: P1Out -> P2Env
initialP2Env (P1Out names collisions) =
    P2Env
    { _p2NameGen = NameGen.initial
    , _p2NamesAbove =
        globalNames names ^. nameUUIDMap <&> (^.. Lens.folded)
        <&> checkClash
    , _p2NameSuffixes = names ^@.. nameUUIDMap . Lens.ifolded <&> f & mconcat
    }
    where
        f (name, insts)
            | name `Set.member` collisions = uuidSuffixes insts
            | otherwise = mempty

newtype Pass2MakeNames (tm :: * -> *) a = Pass2MakeNames (Reader P2Env a)
    deriving (Functor, Applicative, Monad)
runPass2MakeNames :: P2Env -> Pass2MakeNames tm a -> a
runPass2MakeNames initial (Pass2MakeNames act) = runReader act initial
p2GetEnv :: Pass2MakeNames tm P2Env
p2GetEnv = Pass2MakeNames Reader.ask
p2WithEnv :: (P2Env -> P2Env) -> Pass2MakeNames tm a -> Pass2MakeNames tm a
p2WithEnv f (Pass2MakeNames act) = Pass2MakeNames $ Reader.local f act

runPass2MakeNamesInitial :: P1Out -> Pass2MakeNames tm a -> a
runPass2MakeNamesInitial = runPass2MakeNames . initialP2Env

setUuidName :: Monad tm => UUID -> StoredName -> T tm ()
setUuidName = Transaction.setP . assocNameRef

getCollision :: Text -> NameInstance -> P2Env -> Collision
getCollision name inst env =
    case env ^. p2NameSuffixes . Lens.at (inst ^. niUUID) of
    Just suffix -> Collision suffix
    Nothing ->
        case env ^. p2NamesAbove . Lens.at name of
        Nothing -> NoCollision
        Just Clash -> UnknownCollision
        Just noClash ->
            case noClash <> isClashOf inst of
            NoClash _ -> NoCollision
            Clash -> UnknownCollision -- Alternatively "Collision 1"?

getCollisionEnv :: Text -> NameInstance -> P2Env -> (Collision, P2Env)
getCollisionEnv name inst env =
    ( getCollision name inst env
    , env & p2NamesAbove %~ Map.insertWith mappend name (isClashOf inst)
    )

-- makeFinalForm ::
--     Monad tm => Form -> Text -> NameUUIDMap -> UUID -> P2Env -> Name tm
-- makeFinalForm form storedName namesWithin uuid env =
--     fst $ makeFinalFormEnv src storedName namesWithin uuid env

instance Monad tm => MonadNaming (Pass2MakeNames tm) where
    type OldName (Pass2MakeNames tm) = P1Name
    type NewName (Pass2MakeNames tm) = Name tm
    type TM (Pass2MakeNames tm) = tm
    opRun = p2GetEnv <&> runPass2MakeNames <&> (return .)
    opWithTagName = p2cpsNameConvertorGlobal
    opWithParamName _ = p2cpsNameConvertorLocal
    opWithLetName = p2cpsNameConvertorLocal
    opGetName nameType =
        case nameTypeScope nameType of
        Local -> p2nameConvertorLocal
        Global -> p2nameConvertorGlobal

p2nameConvertorLocal :: Monad m => P1Name -> Pass2MakeNames tm (Name m)
p2nameConvertorLocal (P1Name mStoredName inst _) =
    case mStoredName of
        Just storedName ->
            do
                env <- p2GetEnv
                Stored storedName (getCollision storedName inst env) & pure
        Nothing ->
            do
                nameGen <- p2GetEnv <&> (^. p2NameGen)
                let name = evalState (NameGen.existingName uuid) nameGen
                AutoGenerated name & pure
    <&> (`Name` setUuidName uuid)
    where
        uuid = inst ^. niUUID

p2cpsNameConvertor ::
    Monad tm =>
    P1Name ->
    (P2Env -> (Form, P2Env)) ->
    CPS (Pass2MakeNames tm) (Name tm)
p2cpsNameConvertor (P1Name mStoredName inst _) nameMaker =
    CPS $ \k ->
    do
        oldEnv <- p2GetEnv
        let (newName, newEnv) =
                case mStoredName of
                Just storedName ->
                    getCollisionEnv storedName inst oldEnv
                    & _1 %~ Stored storedName
                Nothing -> nameMaker oldEnv
                & _1 %~ (`Name` setUuidName (inst ^. niUUID))
        res <- p2WithEnv (const newEnv) k
        return (newName, res)

p2cpsNameConvertorGlobal :: Monad tm => Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorGlobal p1name =
    p2cpsNameConvertor p1name $
    \env ->
    getCollisionEnv unnamedStr (p1Instance p1name) env
    & _1 %~ Unnamed

p2cpsNameConvertorLocal ::
    Monad tm => NameGen.VarInfo -> Walk.CPSNameConvertor (Pass2MakeNames tm)
p2cpsNameConvertorLocal isFunction p1name =
    p2cpsNameConvertor p1name $ \p2env ->
    let accept name =
            Lens.hasn't (Lens.ix name) (localNames namesWithin)
            && Lens.hasn't (p2NamesAbove . Lens.ix name) p2env
    in  NameGen.newName accept isFunction (inst ^. niUUID)
        <&> AutoGenerated
        & Lens.zoom p2NameGen
        & (`runState` p2env)
    where
        P1Name _ inst namesWithin = p1name

p2nameConvertorGlobal :: Monad tm => Walk.NameConvertor (Pass2MakeNames tm)
p2nameConvertorGlobal (P1Name mStoredName inst _) =
    p2GetEnv
    <&> getCollision (fromMaybe unnamedStr mStoredName) inst
    <&> mk
    <&> (`Name` setUuidName (inst ^. niUUID))
    where
        mk = maybe Unnamed Stored mStoredName

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
