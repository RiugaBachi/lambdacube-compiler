{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
module Core where

import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Data.Foldable (Foldable, toList)
import qualified Data.Foldable as F
import Data.Traversable
import Control.DeepSeq
import Control.Arrow
import Debug.Trace
import Data.Monoid
import Data.Maybe
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Applicative
import Text.Trifecta (Result(..))
import System.Directory
import System.FilePath
import Text.Show.Pretty

import Type hiding (ELet, EApp, ELam, EVar, ELit, ETuple, ECase, ERecord, EAlts, ENext, Exp, Pat, PAt, PVar, PLit, PTuple, PCon, Wildcard)
import qualified Type as AST
import Typecheck hiding (Exp(..))

--trace' = trace
trace' _ x = x

data Kind
  = Star
  deriving (Show,Eq,Ord)

data Var
  = VarE EName Ty
  | VarT EName -- Kind
  | VarC (Constraint Ty)               -- constraint var
  deriving (Show,Eq,Ord)

newtype Pat = Pat (Pat_ (EName, Ty) Var Pat)
  deriving (Show,Eq,Ord)

instance Substitute Var where
    subst s = \case
        VarE n t -> VarE n $ subst s t
        VarC c -> VarC $ subst s c
        VarT n -> VarT n

instance Substitute Pat where
    subst s = \case
        PVar v -> PVar $ subst s v
        PCon (n, ty) l -> PCon (n, subst s ty) $ subst s l
        Pat p -> Pat $ fmap (subst s) p

pattern PAt v l = Pat (PAt_ v l)
pattern PLit l = Pat (PLit_ l)
pattern PVar l = Pat (PVar_ l)
pattern PCon c l = Pat (PCon_ c l)
pattern PTuple l = Pat (PTuple_ l)
pattern Wildcard = Pat Wildcard_

newtype Exp = Exp (Exp_ Var Ty Pat Exp)
  deriving (Show,Eq,Ord)

dummyType = TVar ""

stripTypes :: Exp -> Exp
stripTypes e = case e of
    EVar (VarE n _) -> ELit $ LString n --EVar $ VarE n dummyType
    EVar (VarC _) -> ELit $ LNat 13
    EType t -> ELit $ LNat 29
    EConstraint c -> ELit $ LNat 27
    ELam p e -> ELam (stripPats p) (stripTypes e)
    ELet p e e' -> ELet (stripPats p) (stripTypes e) (stripTypes e')
    Exp e -> Exp $ stripTypes <$> e

stripPats :: Pat -> Pat
stripPats = \case
    PVar (VarE n _) -> PLit $ LString n --EVar $ VarE n dummyType
    PVar (VarC _) -> PLit $ LNat 17
    Pat e -> Pat $ stripPats <$> e

pattern ELit a = Exp (ELit_ a)
pattern EVar a = Exp (EVar_ a)
pattern EApp a b = Exp (EApp_ a b)
pattern ELam a b = Exp (ELam_ a b)
pattern ELet a b c = Exp (ELet_ a b c)
pattern ECase a b = Exp (ECase_ a b)
pattern ETuple a = Exp (ETuple_ a)
pattern ERecord a b = Exp (ERecord_ a b)
--pattern EFieldProj a c = Exp (EFieldProj_ a c)
pattern EType a = Exp (EType_ a)
pattern EConstraint a = Exp (EConstraint_ a)
pattern EAlts b = Exp (EAlts_ b)
pattern ENext = Exp ENext_

data Env = Env {envSubst :: Subst, envMap :: Map EName Thunk}
instance Monoid Env where
    mempty = Env mempty mempty
    Env x y `mappend` Env x' y' = Env (x <> x') (y <> y')
data Thunk = Thunk {thunkEnv :: Env, thunkExp :: Exp}

deleteEnvVars vs (Env s m) = Env s $ foldr Map.delete m vs
addEnv e (Thunk e' x) = Thunk (e' <> e) x

mkReduce :: Exp -> Exp
mkReduce = reduce . Thunk mempty

reduce :: Thunk -> Exp
reduce t@(Thunk env _) = case exp of
    ERecord mn fs -> ERecord mn $ map (id *** reduce') fs
    ETuple es -> ETuple $ map reduce' es
    ELit l -> ELit l
    EType t -> EType $ subst' t
    EConstraint c -> EConstraint $ subst' c
    ELam p e -> ELam (subst' p) $ reduceDel (fvars p) e
    EVar (VarE v t) -> EVar $ VarE v $ subst' t
    ELet p x e' -> ELet (subst' p) (reduceDel (fvars p) x) $ reduceDel (fvars p) e'
    EApp f x -> EApp (reduce' f) (reduce' x)
    x -> error $ "reduce: " ++ ppShow x
  where
    exp = reduceHNF' t
    reduce' = reduce . Thunk env
    reduceDel vs = reduce . Thunk (deleteEnvVars vs env)

    subst' :: Substitute a => a -> a
    subst' = subst (envSubst env)

reduceHNF' = reduceHNF $ error "impossible"

reduceHNF :: Exp -> Thunk -> Exp
reduceHNF cont (Thunk env@(Env _ ma) exp) = case exp of
    EAlts es -> foldr (\alt x -> reduceHNF x $ Thunk env alt) (error "pattern match failure") es
    ENext -> cont
    EVar v -> case v of
        VarE v t -> trace' ("evar " ++ v) $
            maybe (trace' (" no " ++ v) exp) (reduceHNF cont . addEnv env) $ Map.lookup v $ envMap env
    ELet p x e' -> trace' "elet" $ case defs (Thunk env x) p of
        Just m' -> reduceHNF cont $ Thunk (m' <> env) e'
        _ -> exp
    EApp f x -> trace' "eapp" $ case reduceHNF cont $ Thunk env f of

        ELam p e' -> case p of
            PVar (VarT v) -> trace' " ety" $ case x of
                EType x -> reduceHNF cont $ Thunk (Env (s `composeSubst` Map.singleton v (subst s x)) ma) e'
            PVar (VarC v) -> trace' " ectr" $ case x of
                EConstraint x -> case unifC (subst s v) (subst s x) of
                    Right s' -> reduceHNF cont $ Thunk (Env (s `composeSubst` s') ma) e'
                    Left e -> error $ "reduce: " ++ e
            _ -> case defs (Thunk env x) p of
                Just m' -> reduceHNF cont $ Thunk (m' <> env) e'
                _ -> exp

        EVar e' -> case e' of
            VarE v (Forall tv t) -> trace' (" forall " ++ tv) $ case x of
                EType t' -> EVar $ VarE v $ subst (s `composeSubst` Map.singleton tv (subst s t')) t
            VarE v (TConstraintArg t ty) -> trace' (" constr ") $ case x of
                EConstraint t' -> case unifC (subst s t) (subst s t') of
                    Right s' -> EVar $ VarE v $ subst (s `composeSubst` s') ty
                    Left e -> error $ "reduce (2): " ++ e
                e -> error $ "reduce constr: " ++ show e
            _ -> exp
        _ -> exp
    _ -> exp
  where
    s = envSubst env

    defs :: Thunk -> Pat -> Maybe Env
    defs e@(Thunk env _) = \case
        Wildcard -> mempty
        PVar (VarE v _) -> trace' (v ++ " = ...") $ Just $ Env mempty $ Map.singleton v e
        PCon (c, _) ps     -> case getApp {-(c, ps)-} (length ps) e of
            Just (EVar (VarE c' _), xs)
                | c == c' -> mconcat <$> sequence (zipWith defs' xs ps)
                | otherwise -> Nothing -- error $ "defs not eq: " ++ show (c, c')
            _ -> Nothing
        PTuple ps -> case reduceHNF cont e of
            ETuple xs -> mconcat <$> sequence (zipWith defs' xs ps)
            _ -> Nothing
        p -> error $ "defs: " ++ ppShow p
      where
        defs' a b = defs (Thunk env a) b

    getApp :: Int -> Thunk -> Maybe (Exp, [Exp])
    getApp n x@(Thunk env _) = trace' ("getApp " ++ show n) $ f [] n x where
        f acc 0 e = Just (thunkExp e, acc)
        f acc n e = case reduceHNF cont e of
            EApp a b -> f (b: acc) (n-1) $ Thunk env a
            e -> Nothing -- error $ "getApp: " ++ ppShow c ++ "\n" ++ ppShow e

--mconcat' = foldr (<>.) mempty
--m <>. n = Map.unionWithKey (\k a _ -> trace' ("redefined: " ++ k) a) m n

unifC (CEq t f) (CEq t' f') = runExcept $ unifyTypes_ throwError True $ [t, t']: zipWith (\x y->[x,y]) (toList f) (toList f')
unifC (CClass c t) (CClass c' t') | c == c' = runExcept $ unifyTypes_ throwError True $ [t, t']: []
unifC a b = error $ "unifC: " ++ ppShow a ++ "\n ~ \n" ++ ppShow b

fvars = \case
    Wildcard -> []
    PVar x -> case x of
        VarE v _ -> [v]
        _ -> []
    PCon (c, _) ps     -> concatMap fvars ps
    PTuple ps -> concatMap fvars ps
    p -> error $ "fvars: " ++ ppShow p


toCorePat :: Subst -> AST.Pat (Subst, Typing) -> Pat
toCorePat sub p = case p of
  AST.PLit _ l      -> PLit l
  AST.PVar t n    -> PVar $ VarE n $ typingToTy' t
  AST.PCon t n ps -> PCon (n, typingToTy' t) $ map toCorePat' ps
  AST.Wildcard _  -> Wildcard
  AST.PTuple t ps -> PTuple $ map toCorePat' ps
  AST.PAt t n p   -> PAt (VarE n $ typingToTy' t) $ toCorePat' p
  p -> error $ "toCorePat: " ++ ppShow p
 where
    toCorePat' = toCorePat sub'
    s = fst $ getTag p
    sub' = s `composeSubst` sub
    typingToTy' (_, t) = typingToTy $ subst sub' t

toCore :: Subst -> AST.Exp (Subst, Typing) -> Exp
toCore sub e = case e of
  AST.ELit _ a      -> ELit a
  AST.ETuple _ a    -> ETuple $ fmap toCore' a
  AST.EVar t n      -> foldl EApp (foldl EApp (EVar $ VarE n $ typingToTy $ subst sub' $ snd t) pv) cs
    where
      cs = map EConstraint $ subst sub' $ constraints $ snd t
      pv = map EType $ subst sub' $ map TVar $ Map.keys $ fst t
  AST.EApp t f a    -> EApp (toCore' f) (toCore' a)
  AST.ELet _ p a b  -> ELet (toCorePat' p) (pv --> ctr --> toCore' a) (toCore' b)
    where
      ctr = map VarC $ subst sub' $ constraints $ snd $ getTag a
      pv = map VarT $ Set.toList $ polyVars $ snd $ getTag a
  AST.ELam t p a -> ELam (toCorePat' p) $ toCore' a
  AST.ECase t e ps -> ECase (toCore' e) [(toCorePat' p, toCore' x) | (p, x) <- ps]
  AST.Exp t (ERecord_ mb rv) -> ERecord mb $ map (id *** toCore') $ rv
  AST.EAlts t xs -> EAlts $ map toCore' xs
  AST.ENext t -> ENext
  _ -> error $ "toCore: " ++ ppShow e
 where
    toCore' = toCore sub'
    toCorePat' = toCorePat sub'
    s = fst $ getTag e
    sub' = s `composeSubst` sub
    typingToTy' (_, t) = typingToTy $ subst sub' t
    infixr 9 -->
    pv --> x = foldr eLam x pv

eLam (VarT n) (EApp e (EType (TVar m))) | n == m = e  -- optimization
eLam (VarC c) (EApp e (EConstraint c')) | c == c' = e  -- optimization
eLam vt x = ELam (PVar vt) x

tyOf :: Exp -> Ty
tyOf = \case
    ETuple es -> TTuple $ map tyOf es
    EVar (VarE _ t) -> t
    EApp (tyOf -> TArr _ t) _ -> t
    ELam (tyOfPat -> a) (tyOf -> b) -> TArr a b
    e -> error $ "tyOf " ++ ppShow e

tyOfPat :: Pat -> Ty
tyOfPat = \case
    PCon (_, t) ps -> stripArgs (length ps) t
    e -> error $ "tyOfPat " ++ ppShow e
  where
    stripArgs 0 t = t
    stripArgs n (TArr _ t) = stripArgs (n-1) t

pattern Va x <- VarE x _
pattern A0 x <- EVar (Va x)
pattern A0t x t <- EVar (VarE x t)
pattern A1 f x <- EApp (A0 f) x
pattern A2 f x y <- EApp (A1 f x) y
pattern A3 f x y z <- EApp (A2 f x y) z
pattern A4 f x y z v <- EApp (A3 f x y z) v
pattern A5 f x y z v w <-  EApp (A4 f x y z v) w

buildLet :: [(AST.Pat (Subst, Typing), AST.Exp (Subst, Typing))] -> AST.Exp (Subst, Typing) -> AST.Exp (Subst, Typing)
buildLet es e = foldr (\(p, e) x -> AST.ELet (getTag e) p e x) e es

