%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[CoreUtils]{Utility functions on @Core@ syntax}

\begin{code}
#include "HsVersions.h"

module CoreUtils (
	coreExprType, coreAltsType, coreExprCc,

	substCoreExpr, substCoreBindings

	, mkCoreIfThenElse
	, argToExpr
	, unTagBinders, unTagBindersAlts

	, maybeErrorApp
	, nonErrorRHSs
	, squashableDictishCcExpr
    ) where

IMP_Ubiq()

import CoreSyn

import CostCentre	( isDictCC, CostCentre, noCostCentre )
import Id		( idType, mkSysLocal, isBottomingId,
			  toplevelishId, mkIdWithNewUniq, applyTypeEnvToId,
			  dataConRepType,
			  addOneToIdEnv, growIdEnvList, lookupIdEnv,
			  isNullIdEnv, SYN_IE(IdEnv),
			  GenId{-instances-}, SYN_IE(Id)
			)
import Literal		( literalType, isNoRepLit, Literal(..) )
import Maybes		( catMaybes, maybeToBool )
import PprCore
import Outputable	( PprStyle(..), Outputable(..) )
import PprType		( GenType{-instances-}, GenTyVar )
import Pretty		( vcat, text )
import PrimOp		( primOpType, PrimOp(..) )
import SrcLoc		( noSrcLoc )
import TyVar		( cloneTyVar,
			  isNullTyVarEnv, addOneToTyVarEnv, SYN_IE(TyVarEnv),
			  SYN_IE(TyVar), GenTyVar
			)
import Type		( mkFunTy, mkForAllTy, mkForAllUsageTy, mkTyVarTy,
			  getFunTyExpandingDicts_maybe, applyTy, isPrimType,
			  splitSigmaTy, splitFunTy, eqTy, applyTypeEnvToTy,
			  SYN_IE(Type)
			)
import TysWiredIn	( trueDataCon, falseDataCon )
import Unique		( Unique )
import UniqSupply	( initUs, returnUs, thenUs,
			  mapUs, mapAndUnzipUs, getUnique,
			  SYN_IE(UniqSM), UniqSupply
			)
import Usage		( SYN_IE(UVar) )
import Util		( zipEqual, panic, pprTrace, pprPanic, assertPanic )
import Pretty

type TypeEnv = TyVarEnv Type
applyUsage = panic "CoreUtils.applyUsage:ToDo"
\end{code}

%************************************************************************
%*									*
\subsection{Find the type of a Core atom/expression}
%*									*
%************************************************************************

\begin{code}
coreExprType :: CoreExpr -> Type

coreExprType (Var var) = idType   var
coreExprType (Lit lit) = literalType lit

coreExprType (Let _ body)	= coreExprType body
coreExprType (SCC _ expr)	= coreExprType expr
coreExprType (Case _ alts)	= coreAltsType alts

coreExprType (Coerce _ ty _)	= ty -- that's the whole point!

-- a Con is a fully-saturated application of a data constructor
-- a Prim is <ditto> of a PrimOp

coreExprType (Con con args) = 
--			      pprTrace "appTyArgs" (hsep [ppr PprDebug con, semi, 
--						 	   ppr PprDebug con_ty, semi,
--							   ppr PprDebug args]) $
    			      applyTypeToArgs con_ty args
			    where
				con_ty = dataConRepType con

coreExprType (Prim op args) = applyTypeToArgs (primOpType op) args

coreExprType (Lam (ValBinder binder) expr)
  = idType binder `mkFunTy` coreExprType expr

coreExprType (Lam (TyBinder tyvar) expr)
  = mkForAllTy tyvar (coreExprType expr)

coreExprType (Lam (UsageBinder uvar) expr)
  = mkForAllUsageTy uvar (panic "coreExprType:Lam UsageBinder") (coreExprType expr)

coreExprType (App expr (TyArg ty))
  = 
--  pprTrace "appTy1" (hsep [ppr PprDebug fun_ty, space, ppr PprDebug ty]) $
    applyTy fun_ty ty
  where
    fun_ty = coreExprType expr

coreExprType (App expr (UsageArg use))
  = applyUsage (coreExprType expr) use

coreExprType (App expr val_arg)
  = ASSERT(isValArg val_arg)
    let
	fun_ty = coreExprType expr
    in
    case (getFunTyExpandingDicts_maybe False{-no peeking-} fun_ty) of
	  Just (_, result_ty) -> result_ty
#ifdef DEBUG
	  Nothing -> pprPanic "coreExprType:\n"
		(vcat [ppr PprDebug fun_ty,
			   ppr PprShowAll (App expr val_arg)])
#endif
\end{code}

\begin{code}
coreAltsType :: CoreCaseAlts -> Type

coreAltsType (AlgAlts [] deflt)         = default_ty deflt
coreAltsType (AlgAlts ((_,_,rhs1):_) _) = coreExprType rhs1

coreAltsType (PrimAlts [] deflt)       = default_ty deflt
coreAltsType (PrimAlts ((_,rhs1):_) _) = coreExprType rhs1

default_ty NoDefault           = panic "coreExprType:Case:default_ty"
default_ty (BindDefault _ rhs) = coreExprType rhs
\end{code}

\begin{code}
applyTypeToArgs op_ty args	    = foldl applyTypeToArg op_ty args

applyTypeToArg op_ty (TyArg ty)     = applyTy op_ty ty
applyTypeToArg op_ty (UsageArg _)   = panic "applyTypeToArg: UsageArg"
applyTypeToArg op_ty val_or_lit_arg = case (getFunTyExpandingDicts_maybe False{-no peeking-} op_ty) of
					Just (_, res_ty) -> res_ty
\end{code}

coreExprCc gets the cost centre enclosing an expression, if any.
It looks inside lambdas because (scc "foo" \x.e) = \x.scc "foo" e

\begin{code}
coreExprCc :: GenCoreExpr val_bdr val_occ tyvar uvar -> CostCentre
coreExprCc (SCC cc e) = cc
coreExprCc (Lam _ e)  = coreExprCc e
coreExprCc other      = noCostCentre
\end{code}

%************************************************************************
%*									*
\subsection{Routines to manufacture bits of @CoreExpr@}
%*									*
%************************************************************************

\begin{code}
mkCoreIfThenElse (Var bool) then_expr else_expr
    | bool == trueDataCon   = then_expr
    | bool == falseDataCon  = else_expr

mkCoreIfThenElse guard then_expr else_expr
  = Case guard
      (AlgAlts [ (trueDataCon,  [], then_expr),
		 (falseDataCon, [], else_expr) ]
       NoDefault )
\end{code}

For making @Apps@ and @Lets@, we must take appropriate evasive
action if the thing being bound has unboxed type.  @mkCoApp@ requires
a name supply to do its work.

@mkCoApps@, @mkCoCon@ and @mkCoPrim@ also handle the
arguments-must-be-atoms constraint.

\begin{code}
data CoreArgOrExpr
  = AnArg   CoreArg
  | AnExpr  CoreExpr

mkCoApps :: CoreExpr -> [CoreArgOrExpr] -> UniqSM CoreExpr
mkCoCon  :: Id       -> [CoreArgOrExpr] -> UniqSM CoreExpr
mkCoPrim :: PrimOp   -> [CoreArgOrExpr] -> UniqSM CoreExpr

mkCoApps fun args = co_thing (mkGenApp fun) args
mkCoCon  con args = co_thing (Con  con)     args
mkCoPrim  op args = co_thing (Prim op)      args 

co_thing :: ([CoreArg] -> CoreExpr)
	 -> [CoreArgOrExpr]
	 -> UniqSM CoreExpr

co_thing thing arg_exprs
  = mapAndUnzipUs expr_to_arg arg_exprs `thenUs` \ (args, maybe_binds) ->
    returnUs (mkCoLetsUnboxedToCase (catMaybes maybe_binds) (thing args))
  where
    expr_to_arg :: CoreArgOrExpr
		-> UniqSM (CoreArg, Maybe CoreBinding)

    expr_to_arg (AnArg  arg)     = returnUs (arg,      Nothing)
    expr_to_arg (AnExpr (Var v)) = returnUs (VarArg v, Nothing)
    expr_to_arg (AnExpr (Lit l)) = returnUs (LitArg l, Nothing)
    expr_to_arg (AnExpr other_expr)
      = let
	    e_ty = coreExprType other_expr
	in
	getUnique `thenUs` \ uniq ->
	let
	    new_var  = mkSysLocal SLIT("a") uniq e_ty noSrcLoc
	in
	returnUs (VarArg new_var, Just (NonRec new_var other_expr))
\end{code}

\begin{code}
argToExpr ::
  GenCoreArg val_occ tyvar uvar -> GenCoreExpr val_bdr val_occ tyvar uvar

argToExpr (VarArg v)   = Var v
argToExpr (LitArg lit) = Lit lit
\end{code}

All the following functions operate on binders, perform a uniform
transformation on them; ie. the function @(\ x -> (x,False))@
annotates all binders with False.

\begin{code}
unTagBinders :: GenCoreExpr (Id,tag) bdee tv uv -> GenCoreExpr Id bdee tv uv
unTagBinders expr = bop_expr fst expr

unTagBindersAlts :: GenCoreCaseAlts (Id,tag) bdee tv uv -> GenCoreCaseAlts Id bdee tv uv
unTagBindersAlts alts = bop_alts fst alts
\end{code}

\begin{code}
bop_expr  :: (a -> b) -> GenCoreExpr a bdee tv uv -> GenCoreExpr b bdee tv uv

bop_expr f (Var b)	     = Var b
bop_expr f (Lit lit)	     = Lit lit
bop_expr f (Con con args)    = Con con args
bop_expr f (Prim op args)    = Prim op args
bop_expr f (Lam binder expr) = Lam  (bop_binder f binder) (bop_expr f expr)
bop_expr f (App expr arg)    = App  (bop_expr f expr) arg
bop_expr f (SCC label expr)  = SCC  label (bop_expr f expr)
bop_expr f (Coerce c ty e)   = Coerce c ty (bop_expr f e)
bop_expr f (Let bind expr)   = Let  (bop_bind f bind) (bop_expr f expr)
bop_expr f (Case expr alts)  = Case (bop_expr f expr) (bop_alts f alts)

bop_binder f (ValBinder   v) = ValBinder (f v)
bop_binder f (TyBinder    t) = TyBinder    t
bop_binder f (UsageBinder u) = UsageBinder u

bop_bind f (NonRec b e)	= NonRec (f b) (bop_expr f e)
bop_bind f (Rec pairs)	= Rec [(f b, bop_expr f e) | (b, e) <- pairs]

bop_alts f (AlgAlts alts deflt)
  = AlgAlts  [ (con, [f b | b <- binders], bop_expr f e)
	     | (con, binders, e) <- alts ]
	     (bop_deflt f deflt)

bop_alts f (PrimAlts alts deflt)
  = PrimAlts [ (lit, bop_expr f e) | (lit, e) <- alts ]
    	     (bop_deflt f deflt)

bop_deflt f (NoDefault)		 = NoDefault
bop_deflt f (BindDefault b expr) = BindDefault (f b) (bop_expr f expr)
\end{code}

OLD (but left here because of the nice example): @singleAlt@ checks
whether a bunch of case alternatives is actually just one alternative.
It specifically {\em ignores} alternatives which consist of just a
call to @error@, because they won't result in any code duplication.

Example:
\begin{verbatim}
	case (case <something> of
		True  -> <rhs>
		False -> error "Foo") of
	<alts>

===>

	case <something> of
	   True ->  case <rhs> of
		    <alts>
	   False -> case error "Foo" of
		    <alts>

===>

	case <something> of
	   True ->  case <rhs> of
		    <alts>
	   False -> error "Foo"
\end{verbatim}
Notice that the \tr{<alts>} don't get duplicated.

\begin{code}
nonErrorRHSs :: GenCoreCaseAlts a Id TyVar UVar -> [GenCoreExpr a Id TyVar UVar]

nonErrorRHSs alts
  = filter not_error_app (find_rhss alts)
  where
    find_rhss (AlgAlts  as deflt) = [rhs | (_,_,rhs) <- as] ++ deflt_rhs deflt
    find_rhss (PrimAlts as deflt) = [rhs | (_,rhs)   <- as] ++ deflt_rhs deflt

    deflt_rhs NoDefault           = []
    deflt_rhs (BindDefault _ rhs) = [rhs]

    not_error_app rhs
      = case (maybeErrorApp rhs Nothing) of
	  Just _  -> False
	  Nothing -> True
\end{code}

maybeErrorApp checks whether an expression is of the form

	error ty args

If so, it returns

	Just (error ty' args)

where ty' is supplied as an argument to maybeErrorApp.

Here's where it is useful:

		case (error ty "Foo" e1 e2) of <alts>
 ===>
		error ty' "Foo"

where ty' is the type of any of the alternatives.  You might think
this never occurs, but see the comments on the definition of
@singleAlt@.

Note: we *avoid* the case where ty' might end up as a primitive type:
this is very uncool (totally wrong).

NOTICE: in the example above we threw away e1 and e2, but not the
string "Foo".  How did we know to do that?

Answer: for now anyway, we only handle the case of a function whose
type is of form

	bottomingFn :: forall a. t1 -> ... -> tn -> a
	    	    	      ^---------------------^ NB!

Furthermore, we only count a bottomingApp if the function is applied
to more than n args.  If so, we transform:

	bottomingFn ty e1 ... en en+1 ... em
to
	bottomingFn ty' e1 ... en

That is, we discard en+1 .. em

\begin{code}
maybeErrorApp
	:: GenCoreExpr a Id TyVar UVar	-- Expr to look at
	-> Maybe Type			-- Just ty => a result type *already cloned*;
					-- Nothing => don't know result ty; we
					-- *pretend* that the result ty won't be
					-- primitive -- somebody later must
					-- ensure this.
	-> Maybe (GenCoreExpr b Id TyVar UVar)

maybeErrorApp expr result_ty_maybe
  = case (collectArgs expr) of
      (Var fun, [{-no usage???-}], [ty], other_args)
	| isBottomingId fun
	&& maybeToBool result_ty_maybe -- we *know* the result type
				       -- (otherwise: live a fairy-tale existence...)
	&& not (isPrimType result_ty) ->

	case (splitSigmaTy (idType fun)) of
	  ([tyvar], [], tau_ty) ->
	      case (splitFunTy tau_ty) of { (arg_tys, res_ty) ->
	      let
		  n_args_to_keep = length arg_tys
		  args_to_keep   = take n_args_to_keep other_args
	      in
	      if  (res_ty `eqTy` mkTyVarTy tyvar)
	       && n_args_to_keep <= length other_args
	      then
		    -- Phew!  We're in business
		  Just (mkGenApp (Var fun) (TyArg result_ty : args_to_keep))
	      else
		  Nothing
	      }

	  other -> Nothing  -- Function type wrong shape
      other -> Nothing
  where
    Just result_ty = result_ty_maybe
\end{code}

\begin{code}
squashableDictishCcExpr :: CostCentre -> GenCoreExpr a b c d -> Bool

squashableDictishCcExpr cc expr
  = if not (isDictCC cc) then
	False -- that was easy...
    else
	squashable expr -- note: quite like the "atomic_rhs" stuff in simplifier
  where
    squashable (Var _)      = True
    squashable (Con  _ _)   = True -- I think so... WDP 94/09
    squashable (Prim _ _)   = True -- ditto
    squashable (App f a)
      | notValArg a	    = squashable f
    squashable other	    = False
\end{code}

%************************************************************************
%*									*
\subsection{Core-renaming utils}
%*									*
%************************************************************************

\begin{code}
substCoreBindings :: ValEnv
		-> TypeEnv -- TyVar=>Type
		-> [CoreBinding]
		-> UniqSM [CoreBinding]

substCoreExpr	:: ValEnv
		-> TypeEnv -- TyVar=>Type
		-> CoreExpr
		-> UniqSM CoreExpr

substCoreBindings venv tenv binds
  -- if the envs are empty, then avoid doing anything
  = if (isNullIdEnv venv && isNullTyVarEnv tenv) then
       returnUs binds
    else
       do_CoreBindings venv tenv binds

substCoreExpr venv tenv expr
  = if (isNullIdEnv venv && isNullTyVarEnv tenv) then
       returnUs expr
    else
       do_CoreExpr venv tenv expr
\end{code}

The equiv code for @Types@ is in @TyUtils@.

Because binders aren't necessarily unique: we don't do @plusEnvs@
(which check for duplicates); rather, we use the shadowing version,
@growIdEnv@ (and shorthand @addOneToIdEnv@).

@do_CoreBindings@ takes into account the semantics of a list of
@CoreBindings@---things defined early in the list are visible later in
the list, but not vice versa.

\begin{code}
type ValEnv  = IdEnv CoreExpr

do_CoreBindings :: ValEnv
		-> TypeEnv
		-> [CoreBinding]
		-> UniqSM [CoreBinding]

do_CoreBinding :: ValEnv
	       -> TypeEnv
	       -> CoreBinding
	       -> UniqSM (CoreBinding, ValEnv)

do_CoreBindings venv tenv [] = returnUs []
do_CoreBindings venv tenv (b:bs)
  = do_CoreBinding  venv     tenv b	`thenUs` \ (new_b,  new_venv) ->
    do_CoreBindings new_venv tenv bs	`thenUs` \  new_bs ->
    returnUs (new_b : new_bs)

do_CoreBinding venv tenv (NonRec binder rhs)
  = do_CoreExpr venv tenv rhs	`thenUs` \ new_rhs ->

    dup_binder tenv binder	`thenUs` \ (new_binder, (old, new)) ->
    -- now plug new bindings into envs
    let  new_venv = addOneToIdEnv venv old new  in

    returnUs (NonRec new_binder new_rhs, new_venv)

do_CoreBinding venv tenv (Rec binds)
  = -- for letrec, we plug in new bindings BEFORE cloning rhss
    mapAndUnzipUs (dup_binder tenv) binders `thenUs` \ (new_binders, new_maps) ->
    let  new_venv = growIdEnvList venv new_maps in

    mapUs (do_CoreExpr new_venv tenv) rhss `thenUs` \ new_rhss ->
    returnUs (Rec (zipEqual "do_CoreBinding" new_binders new_rhss), new_venv)
  where
    (binders, rhss) = unzip binds
\end{code}

\begin{code}
do_CoreArg :: ValEnv
	    -> TypeEnv
	    -> CoreArg
	    -> UniqSM CoreArgOrExpr

do_CoreArg venv tenv a@(VarArg v)
  = returnUs (
      case (lookupIdEnv venv v) of
	Nothing   -> AnArg  a
	Just expr -> AnExpr expr
    )

do_CoreArg venv tenv (TyArg ty)
  = returnUs (AnArg (TyArg (applyTypeEnvToTy tenv ty)))

do_CoreArg venv tenv other_arg = returnUs (AnArg other_arg)
\end{code}

\begin{code}
do_CoreExpr :: ValEnv
	    -> TypeEnv
	    -> CoreExpr
	    -> UniqSM CoreExpr

do_CoreExpr venv tenv orig_expr@(Var var)
  = returnUs (
      case (lookupIdEnv venv var) of
	Nothing	    -> --false:ASSERT(toplevelishId var) (SIGH)
		       orig_expr
	Just expr   -> expr
    )

do_CoreExpr venv tenv e@(Lit _) = returnUs e

do_CoreExpr venv tenv (Con con as)
  = mapUs  (do_CoreArg venv tenv) as `thenUs`  \ new_as ->
    mkCoCon con new_as

do_CoreExpr venv tenv (Prim op as)
  = mapUs  (do_CoreArg venv tenv) as 	`thenUs`  \ new_as ->
    do_PrimOp op			`thenUs`  \ new_op ->
    mkCoPrim new_op new_as
  where
    do_PrimOp (CCallOp label is_asm may_gc arg_tys result_ty)
      = let
	    new_arg_tys   = map (applyTypeEnvToTy tenv) arg_tys
	    new_result_ty = applyTypeEnvToTy tenv result_ty
	in
	returnUs (CCallOp label is_asm may_gc new_arg_tys new_result_ty)

    do_PrimOp other_op = returnUs other_op

do_CoreExpr venv tenv (Lam (ValBinder binder) expr)
  = dup_binder tenv binder `thenUs` \(new_binder, (old,new)) ->
    let  new_venv = addOneToIdEnv venv old new  in
    do_CoreExpr new_venv tenv expr  `thenUs` \ new_expr ->
    returnUs (Lam (ValBinder new_binder) new_expr)

do_CoreExpr venv tenv (Lam (TyBinder tyvar) expr)
  = dup_tyvar tyvar	   `thenUs` \ (new_tyvar, (old, new)) ->
    let
	new_tenv = addOneToTyVarEnv tenv old new
    in
    do_CoreExpr venv new_tenv expr  `thenUs` \ new_expr ->
    returnUs (Lam (TyBinder new_tyvar) new_expr)

do_CoreExpr venv tenv (Lam _ expr) = panic "CoreUtils.do_CoreExpr:Lam UsageBinder"

do_CoreExpr venv tenv (App expr arg)
  = do_CoreExpr venv tenv expr	`thenUs` \ new_expr ->
    do_CoreArg  venv tenv arg   `thenUs` \ new_arg  ->
    mkCoApps new_expr [new_arg] -- ToDo: more efficiently?

do_CoreExpr venv tenv (Case expr alts)
  = do_CoreExpr venv tenv expr	    `thenUs` \ new_expr ->
    do_alts venv tenv alts	    `thenUs` \ new_alts ->
    returnUs (Case new_expr new_alts)
  where
    do_alts venv tenv (AlgAlts alts deflt)
      = mapUs (do_boxed_alt venv tenv) alts `thenUs` \ new_alts ->
    	do_default venv tenv deflt	    `thenUs` \ new_deflt ->
	returnUs (AlgAlts new_alts new_deflt)
      where
	do_boxed_alt venv tenv (con, binders, expr)
	  = mapAndUnzipUs (dup_binder tenv) binders `thenUs` \ (new_binders, new_vmaps) ->
	    let  new_venv = growIdEnvList venv new_vmaps  in
	    do_CoreExpr new_venv tenv expr  `thenUs` \ new_expr ->
	    returnUs (con, new_binders, new_expr)


    do_alts venv tenv (PrimAlts alts deflt)
      = mapUs (do_unboxed_alt venv tenv) alts `thenUs` \ new_alts ->
    	do_default venv tenv deflt	      `thenUs` \ new_deflt ->
	returnUs (PrimAlts new_alts new_deflt)
      where
	do_unboxed_alt venv tenv (lit, expr)
	  = do_CoreExpr venv tenv expr	`thenUs` \ new_expr ->
	    returnUs (lit, new_expr)

    do_default venv tenv NoDefault = returnUs NoDefault

    do_default venv tenv (BindDefault binder expr)
      =	dup_binder tenv binder		`thenUs` \ (new_binder, (old, new)) ->
	let  new_venv = addOneToIdEnv venv old new  in
	do_CoreExpr new_venv tenv expr	`thenUs` \ new_expr ->
	returnUs (BindDefault new_binder new_expr)

do_CoreExpr venv tenv (Let core_bind expr)
  = do_CoreBinding venv tenv core_bind	`thenUs` \ (new_bind, new_venv) ->
    -- and do the body of the let
    do_CoreExpr new_venv tenv expr  	`thenUs` \ new_expr ->
    returnUs (Let new_bind new_expr)

do_CoreExpr venv tenv (SCC label expr)
  = do_CoreExpr venv tenv expr	    	`thenUs` \ new_expr ->
    returnUs (SCC label new_expr)

do_CoreExpr venv tenv (Coerce c ty expr)
  = do_CoreExpr venv tenv expr	    	`thenUs` \ new_expr ->
    returnUs (Coerce c (applyTypeEnvToTy tenv ty) new_expr)
\end{code}

\begin{code}
dup_tyvar :: TyVar -> UniqSM (TyVar, (TyVar, Type))
dup_tyvar tyvar
  = getUnique			`thenUs` \ uniq ->
    let  new_tyvar = cloneTyVar tyvar uniq  in
    returnUs (new_tyvar, (tyvar, mkTyVarTy new_tyvar))

-- same thing all over again --------------------

dup_binder :: TypeEnv -> Id -> UniqSM (Id, (Id, CoreExpr))
dup_binder tenv b
  = if (toplevelishId b) then
	-- binder is "top-level-ish"; -- it should *NOT* be renamed
	-- ToDo: it's unsavoury that we return something to heave in env
	returnUs (b, (b, Var b))

    else -- otherwise, the full business
	getUnique			    `thenUs`  \ uniq ->
	let
	    new_b1 = mkIdWithNewUniq b uniq
	    new_b2 = applyTypeEnvToId tenv new_b1
	in
	returnUs (new_b2, (b, Var new_b2))
\end{code}
