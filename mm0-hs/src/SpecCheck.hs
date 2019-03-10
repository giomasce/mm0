module SpecCheck(checkAST) where

import Control.Monad.Trans.Reader
import Control.Monad.Trans.State (StateT(..), evalStateT)
import Control.Monad.State.Class
import Control.Monad.Except
import Data.Maybe
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import AST
import Environment
import ParserEnv
import LocalContext
import MathParser
import Util

data TCState = TCState {
  env :: Environment,
  eParser :: ParserEnv }

data ProofObligation = ProofObligation {
  tEnv :: Environment,
  tBound :: [(Ident, Ident)],
  tArgs :: [(Ident, DepType)],
  tHyps :: [SExpr],
  tReturn :: SExpr }
  deriving (Show)

type SpecM = ReaderT Stack (StateT (Environment, ParserEnv) (Either String))

modifyEnv :: (Environment -> Either String Environment) -> SpecM ()
modifyEnv f = do
  (e, p) <- get
  e' <- lift $ lift $ f e
  put (e', p)

modifyParser :: (Environment -> ParserEnv -> Either String ParserEnv) -> SpecM ()
modifyParser f = do
  (e, p) <- get
  p' <- lift $ lift $ f e p
  put (e, p')

modifyStack :: (Stack -> Stack) -> SpecM a -> SpecM a
modifyStack = local

insertSort :: Ident -> SortData -> SpecM ()
insertSort v sd = modifyEnv $ \e -> do
  s' <- insertNew ("sort " ++ v ++ " already declared") v sd (eSorts e)
  return (e {eSorts = s'})

insertDecl :: Ident -> Decl -> SpecM ()
insertDecl v d = modifyEnv $ \e -> do
  d' <- insertNew ("decl " ++ v ++ " already declared") v d (eDecls e)
  return (e {eDecls = d'})

insertVars :: [Ident] -> VarType -> SpecM a -> SpecM a
insertVars vs ty = modifyStack (\s -> s {sVars = f vs (sVars s)}) where
  f :: [Ident] -> Vars -> Vars
  f [] = id
  f (v:vs) = f vs . M.insert v ty

getVar' :: MonadError String m => Ident -> Stack -> m VarType
getVar' v s = fromJustError "type depends on unknown variable" (sVars s M.!? v)

getVar :: Ident -> SpecM VarType
getVar v = do s <- ask; getVar' v s

pushStack :: Stack -> Stack
pushStack s = Stack (sVars s) (Just s)

evalSpecM :: SpecM a -> Either String a
evalSpecM m = evalStateT (runReaderT m (Stack M.empty Nothing)) (Environment M.empty M.empty, newParserEnv)

checkAST :: AST -> Either String [ProofObligation]
checkAST ast = evalSpecM (checkDecls ast)

checkDecls :: [Stmt] -> SpecM [ProofObligation]
checkDecls [] = return []
checkDecls (Sort v sd : ds) = insertSort v sd >> checkDecls ds
checkDecls (Var ids ty : ds) = insertVars ids ty (checkDecls ds)
checkDecls (Term x vs ty : ds) = do
  checkTerm vs ty (\bs as -> DTerm bs (snd <$> as)) >>= insertDecl x
  checkDecls ds
checkDecls (Axiom x vs ty : ds) =
  checkAssert vs ty DAxiom >>= insertDecl x >> checkDecls ds
checkDecls (Theorem x vs ty : ds) = do
  env <- fst <$> get
  thm <- checkAssert vs ty (ProofObligation env)
  (thm :) <$> checkDecls ds
checkDecls (Def x vs ty def : ds) =
  checkDef vs ty def >>= insertDecl x >> checkDecls ds
checkDecls (Notation n : ds) = do
  (e, pe) <- get
  modifyParser (addNotation n)
  checkDecls ds
checkDecls (Output k v bi : ds) =
  throwError ("output-kind " ++ show k ++ " not supported")
checkDecls (Block ss : ds) =
  (++) <$> modifyStack pushStack (checkDecls ss) <*> checkDecls ds

checkTerm :: [Binder] -> Type ->
  ([(Ident, Ident)] -> [(Ident, DepType)] -> DepType -> a) -> SpecM a
checkTerm vs ty mk = do
  ((bis, ret), Locals sbd nv) <- runLocalCtxM' $
    processBinders vs $ \vs' -> (,) vs' <$> processType ty
  ReaderT $ \stk -> lift $ do
    (_, dummies) <- collectDummies bis
    guardError "dummy variables not permitted in terms" (null dummies)
    (bis, bound) <- collectBound sbd bis
    (bis, args) <- collectArgs sbd bis
    guardError "invalid term binder" (null bis)
    guardError "terms are not permitted to use var declarations" (S.null nv)
    ret' <- case ret of
      PType t ts -> return (DepType t ts)
      _ -> throwError "invalid term return type"
    return (mk bound args ret')

checkAssert :: [Binder] -> Type ->
  ([(Ident, Ident)] -> [(Ident, DepType)] -> [SExpr] -> SExpr -> a) -> SpecM a
checkAssert vs ty mk = do
  ((bis, ret), Locals sbd nv) <- runLocalCtxM' $
    processBinders vs $ \vs' -> (,) vs' <$> processType ty
  ReaderT $ \stk -> lift $ do
    (_, dummies) <- collectDummies bis
    guardError "dummy variables not permitted in axiom/theorem" (null dummies)
    (bis, bound) <- collectBound sbd bis
    (bis, args) <- collectArgs sbd bis
    hyps <- collectHyps bis
    (bound2, os) <- partitionVars stk sbd nv
    let bound' = bound ++ bound2
    let bd' = fst <$> bound'
    let args' = args ++ ((\(v, ty) -> (v, varTypeToDep bd' ty)) <$> os)
    ret' <- case ret of
      PFormula sexpr -> return sexpr
      _ -> throwError "invalid axiom/theorem return type"
    return (mk bound' args' hyps ret')

checkDef :: [Binder] -> Type -> Maybe Formula -> SpecM Decl
checkDef vs ty Nothing = checkTerm vs ty (\bs as r -> DDef bs as r Nothing)
checkDef vs ty (Just defn) = do
  ((bis, ret, defn'), Locals sbd nv) <- runLocalCtxM' $
    processBinders vs $ \vs' -> do
      ty' <- processType ty
      defn' <- parseFormula defn
      return (vs', ty', defn')
  ReaderT $ \stk -> lift $ do
    (bis, dummies) <- collectDummies bis
    (bis, bound) <- collectBound sbd bis
    (bis, args) <- collectArgs sbd bis
    guardError "invalid def binder" (null bis)
    let dummies2 = (\v -> (v, varTypeSort $ sVars stk M.! v)) <$> S.toList nv
    let dummies' = dummies ++ dummies2
    ret' <- case ret of
      PType t ts -> return (DepType t ts)
      _ -> throwError "invalid def return type"
    return (DDef bound args ret' $ Just (dummies', defn'))

runLocalCtxM' :: LocalCtxM a -> SpecM (a, Locals)
runLocalCtxM' m = ReaderT $ \stk -> StateT $ \e ->
  (\r -> (r, e)) <$> runLocalCtxM m stk e

processBinders :: [Binder] -> ([PBinder] -> LocalCtxM a) -> LocalCtxM a
processBinders [] f = f []
processBinders (b:bs) f =
  processBinder b (\b' -> processBinders bs (f . (b':)))

processBinder :: Binder -> (PBinder -> LocalCtxM a) -> LocalCtxM a
processBinder (Binder l ty) f = do
  b <- PBinder l <$> processType ty
  local (b:) (f b)

processType :: Type -> LocalCtxM PType
processType (TType v vs) = do
  Locals _ nv <- get
  mapM_ (\v' -> ensureLocal v' >> makeBound v') vs
  return (PType v vs)
processType (TFormula s) = do
  fmla <- parseFormula s
  return (PFormula fmla)

type DList a = [a] -> [a]
data BinderData = BinderData {
  bdBound :: DList (Ident, Ident),
  bdArgs :: DList (Ident, DepType),
  bdDummies :: DList (Ident, DepType),
  bdHyps :: DList SExpr,
  bdRet :: PType }

collectDummies :: [PBinder] -> Either String ([PBinder], [(Ident, Ident)])
collectDummies (PBinder (LDummy v) ty : bis) = case ty of
  PType t [] -> (\(bis', ds') -> (bis', (v, t) : ds')) <$> collectDummies bis
  PType _ _ -> throwError "dummy variable has dependent type"
  _ -> throwError "dummy hypothesis not permitted (use '_' instead)"
collectDummies (bi : bis) = (\(bis', ds') -> (bi : bis', ds')) <$> collectDummies bis
collectDummies [] = return ([], [])

collectBound :: S.Set Ident -> [PBinder] -> Either String ([PBinder], [(Ident, Ident)])
collectBound sbd = go where
  go (PBinder (LReg v) ty : bis) | S.member v sbd = case ty of
    PType t [] -> (\(bis', bs') -> (bis', (v, t) : bs')) <$> go bis
    _ -> throwError "bound variable has dependent type"
  go bis = return (bis, [])

collectArgs :: S.Set Ident -> [PBinder] -> Either String ([PBinder], [(Ident, DepType)])
collectArgs sbd = go where
  go (PBinder (LReg v) (PType t ts) : bis) | not (S.member v sbd) =
    (\(bis', as') -> (bis', (v, DepType t ts) : as')) <$> go bis
  go bis = return (bis, [])

collectHyps :: [PBinder] -> Either String [SExpr]
collectHyps (PBinder _ (PFormula sexp) : bis) = (sexp :) <$> collectHyps bis
collectHyps _ = throwError "incorrect binders"

partitionVars :: Stack -> S.Set Ident -> S.Set Ident ->
  Either String ([(Ident, Ident)], [(Ident, VarType)])
partitionVars stk sbd nv = go (S.toList nv) where
  go :: [Ident] -> Either String ([(Ident, Ident)], [(Ident, VarType)])
  go [] = return ([], [])
  go (v : vs) = do
    let ty = sVars stk M.! v
    (vs', os') <- go vs
    return $ if S.member v sbd
      then ((v, varTypeSort ty) : vs', os')
      else (vs', (v, ty) : os')
