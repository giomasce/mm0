module Elaborator(elabAST) where

import Control.Monad.Trans.State
import Control.Monad.Except
import Data.Maybe
import Data.List
import Debug.Trace
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Sequence as Q
import AST
import Environment
import ParserEnv
import LocalContext
import MathParser
import qualified SpecCheck
import Util

data TCState = TCState {
  env :: Environment,
  eParser :: ParserEnv }

type SpecM = StateT (Environment, ParserEnv) (Either String)

modifyEnv :: (Environment -> Either String Environment) -> SpecM ()
modifyEnv f = do
  (e, p) <- get
  e' <- lift $ f e
  put (e', p)

modifyParser :: (Environment -> ParserEnv -> Either String ParserEnv) -> SpecM ()
modifyParser f = do
  (e, p) <- get
  p' <- lift $ f e p
  put (e, p')

insertSpec :: Spec -> SpecM ()
insertSpec = modifyEnv . SpecCheck.insertSpec

insertSort :: Ident -> SortData -> SpecM ()
insertSort v sd = insertSpec (SSort v sd) >> modifyParser recalcCoeProv

insertDecl :: Ident -> Decl -> SpecM ()
insertDecl v d = insertSpec (SDecl v d)

withContext :: MonadError String m => String -> m a -> m a
withContext s m = catchError m (\e -> throwError ("at " ++ s ++ ": " ++ e))

evalSpecM :: SpecM a -> Either String (a, Environment)
evalSpecM m = do
  (a, (e, _)) <- runStateT m (newEnv, newParserEnv)
  return (a, e)

elabAST :: AST -> Either String Environment
elabAST ast = snd <$> evalSpecM (elabDecls ast)

elabDecls :: [Stmt] -> SpecM ()
elabDecls [] = return ()
elabDecls (Sort v sd : ds) = insertSort v sd >> elabDecls ds
elabDecls (Term x vs ty : ds) =
  elabTerm x vs ty DTerm >>= insertDecl x >> elabDecls ds
elabDecls (Axiom x vs ty : ds) =
  elabAssert x vs ty DAxiom >>= insertDecl x >> elabDecls ds
elabDecls (Theorem x vs ty : ds) = do
  elabAssert x vs ty (SThm x) >>= insertSpec
  elabDecls ds
elabDecls (Def x vs ty def : ds) =
  elabDef x vs ty def >>= insertDecl x >> elabDecls ds
elabDecls (Notation n : ds) = do
  (e, pe) <- get
  modifyParser (addNotation n)
  elabDecls ds
elabDecls (Inout (Input k s) : ds) = elabInout False k s >> elabDecls ds
elabDecls (Inout (Output k s) : ds) = elabInout True k s >> elabDecls ds

elabTerm :: Ident -> [Binder] -> DepType -> ([PBinder] -> DepType -> a) -> SpecM a
elabTerm x vs ty mk = do
  (bis, dummies, hyps) <- runLocalCtxM' $
    processBinders vs $ \vs' ds hs -> checkType ty >> return (vs', ds, hs)
  lift $ do
    guardError (x ++ ": dummy variables not permitted in terms") (null dummies)
    guardError (x ++ ": hypotheses not permitted in terms") (null hyps)
    return (mk bis ty)

elabAssert :: Ident -> [Binder] -> Formula -> ([PBinder] -> [SExpr] -> SExpr -> a) -> SpecM a
elabAssert x vs fmla mk = do
  (bis, dummies, hyps, ret) <- withContext x $ runLocalCtxM' $
    processBinders vs $ \vs' ds hs -> do
      sexp <- parseFormulaProv fmla
      return (vs', ds, hs, sexp)
  lift $ do
    guardError (x ++ ": dummy variables not permitted in axiom/theorem") (null dummies)
    return (mk bis hyps ret)

elabDef :: Ident -> [Binder] -> DepType -> Maybe Formula -> SpecM Decl
elabDef x vs ty Nothing = elabTerm x vs ty (\bs r -> DDef bs r Nothing)
elabDef x vs ty (Just defn) = do
  (bis, dummies, hyps, defn') <- withContext x $ runLocalCtxM' $
    processBinders vs $ \vs' ds hs -> do
      checkType ty
      defn' <- parseFormula (dSort ty) defn
      return (vs', ds, hs, defn')
  lift $ do
    guardError (x ++ ": hypotheses not permitted in terms") (null hyps)
    return (DDef bis ty $ Just (dummies, defn'))

elabInout out "string" [x] = do
  e <- runLocalCtxM' $ parseTermFmla "string" x
  insertSpec (SInout (IOKString out e))
elabInout _ "string" _ = throwError ("input/output-kind string takes one argument")
elabInout False k _ = throwError ("input-kind " ++ show k ++ " not supported")
elabInout True k _ = throwError ("output-kind " ++ show k ++ " not supported")

parseTermFmla :: Ident -> Either Ident Formula -> LocalCtxM SExpr
parseTermFmla _ (Left x) = do
  env <- readEnv
  case getTerm env x of
    Just ([], _) -> return (App x [])
    _ -> throwError ("input argument " ++ x ++ " is not a nullary term constructor")
parseTermFmla s (Right f) = parseFormula s f

runLocalCtxM' :: LocalCtxM a -> SpecM a
runLocalCtxM' m = StateT $ \e -> (\r -> (r, e)) <$> runLocalCtxM m e

processBinders :: [Binder] -> ([PBinder] -> M.Map Ident Ident -> [SExpr] -> LocalCtxM a) -> LocalCtxM a
processBinders = go M.empty where
  go m [] f = f [] m []
  go m (b:bs) f = processBinder b
    (\b' -> go m bs (f . (b':)))
    (\d t -> go (M.insert d t m) bs f)
    (\h -> go m bs (\bs' ds' hs -> case bs' of
      [] -> f [] ds' (h : hs)
      _ -> throwError "hypotheses must come after variable bindings"))

  processBinder :: Binder -> (PBinder -> LocalCtxM a) ->
    (Ident -> Ident -> LocalCtxM a) -> (SExpr -> LocalCtxM a) -> LocalCtxM a
  processBinder (Binder (LBound v) (TType (DepType t ts))) f _ _ = do
    guardError "bound variable has dependent type" (null ts)
    let bi = PBound v t
    lcmLocal (lcRegCons bi) (f bi)
  processBinder (Binder (LDummy v) (TType (DepType t ts))) _ g _ = do
    guardError "dummy variable has dependent type" (null ts)
    lcmLocal (lcDummyCons v t) (g v t)
  processBinder (Binder (LDummy _) (TFormula _)) _ _ _ =
    throwError "dummy hypothesis not permitted (use '_' instead)"
  processBinder (Binder v (TType ty)) f _ _ = do
    checkType ty
    let bi = PReg (fromMaybe "_" (localName v)) ty
    lcmLocal (lcRegCons bi) (f bi)
  processBinder (Binder _ (TFormula s)) _ _ h = parseFormulaProv s >>= h

checkType :: DepType -> LocalCtxM ()
checkType (DepType v vs) = mapM_ ensureBound vs
