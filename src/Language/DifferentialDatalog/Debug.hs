{-
Copyright (c) 2020 VMware, Inc.
SPDX-License-Identifier: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
-}

{-# LANGUAGE TupleSections, LambdaCase, RecordWildCards #-}

{- |
Module     : Debug
Description: Helper functions for adding debug hooks to a 'DatalogProgram'.
-}
module Language.DifferentialDatalog.Debug (
    debugUpdateFunctions,
    debugUpdateRHSRules,
)
where

import qualified Data.Map                          as M
import Data.List
import Data.Maybe
import Data.Char

import {-# SOURCE #-} qualified Language.DifferentialDatalog.Compile as Compile
import Language.DifferentialDatalog.Pos
import Language.DifferentialDatalog.Syntax

-- For RHSLiteral, a binding to the expression is inserted if it's not bound to a variable.
-- For example, R(a, b, z, _) gets transformed into __r0 in R(a, b, z, _),
addBindingToRHSLiteral :: (RuleRHS, Int) -> RuleRHS
addBindingToRHSLiteral (r@(RHSLiteral True _), index) =
  let
    bindingName = "__" ++ (map toLower $ atomRelation $ rhsAtom r) ++ (show index)
    expr = atomVal $ rhsAtom r
    exprNode = enode expr
    updatedAtomVal = case exprNode of
                     EBinding{} -> expr
                     _          -> eBinding bindingName expr
    updatedAtom = (rhsAtom r) { atomVal = updatedAtomVal }
  in r { rhsAtom = updatedAtom }
addBindingToRHSLiteral (rule, _) = rule

-- For RHSAggregate, the aggregate function is prepended with __debug_
-- The input to the aggregate function is transformed into a tuple of
-- input to the aggregate operator and the original value.
-- The return variable is also prepended with __inputs_, which will now be
-- a tuple.
-- The corrddesponding compiler-generated function also outputs the set of
-- inputs, so that it is visible to the inspect operator.
-- an RHSCondition is also appended that declares and sets the original
-- return variable of the pre-updated aggregate operator.
updateRHSAggregate :: DatalogProgram -> Rule -> Int -> [RuleRHS]
updateRHSAggregate d rule index =
  let
     r = (ruleRHS rule) !! index
     funcName = "__debug_" ++ (rhsAggFunc r)
     varRet = "__inputs_" ++ (rhsVar r)
     input = eTuple [head $ Compile.recordAfterPrefix d rule (index - 1), (rhsAggExpr r)]
     rAgg = RHSAggregate { rhsVar = varRet,
                           rhsGroupBy = rhsGroupBy r,
                           rhsAggFunc = funcName,
                           rhsAggExpr = input }
     rCond = RHSCondition { rhsExpr = eSet (eVarDecl $ rhsVar r) (eTupField (eVar varRet) 1) }
  in case r of
     RHSAggregate{} -> [rAgg, rCond]
     _ -> [r]

-- OperatorID is a tuple composed of rule index, rhs index and head index.
generateOperatorIdExpr :: Int -> Int -> Int -> Expr
generateOperatorIdExpr rlIdx rhsIdx headIdx =
  eTuple [eBit 32 $ toInteger rlIdx, eBit 32 $ toInteger rhsIdx, eBit 32 $ toInteger headIdx]

ddlogWeightExpr :: Expr
ddlogWeightExpr = eVar "ddlog_weight"

ddlogTimestampExpr :: Expr
ddlogTimestampExpr = eVar "ddlog_timestamp"

generateInspectDebugJoin :: DatalogProgram -> Int -> Rule -> Int -> [RuleRHS]
generateInspectDebugJoin d ruleIdx rule index =
  let
    input1 = head $ Compile.recordAfterPrefix d rule (index - 1)
    input2 = eVar $ exprVar $ enode $ atomVal $ rhsAtom (ruleRHS rule !! index)
    outputs = Compile.recordAfterPrefix d rule index
  in map (\i -> RHSInspect {rhsInspectExpr = eApply "debug.debug_event_join"
                                             [generateOperatorIdExpr ruleIdx index i,
                                              ddlogWeightExpr,
                                              ddlogTimestampExpr,
                                              input1,
                                              input2,
                                              outputs !! i]}) [0..length outputs -1]

generateInspectDebug :: DatalogProgram -> Int -> Rule -> Int -> [RuleRHS]
generateInspectDebug d ruleIdx rule index =
  let
    input1 = if index == 0
                then eVar $ exprVar $ enode $ atomVal $ rhsAtom $ head $ ruleRHS rule
                else head $ Compile.recordAfterPrefix d rule (index - 1)
    outputs = Compile.recordAfterPrefix d rule index
  in map (\i -> RHSInspect {rhsInspectExpr = eApply "debug.debug_event"
                                             [generateOperatorIdExpr ruleIdx index i,
                                              ddlogWeightExpr,
                                              ddlogTimestampExpr,
                                              input1,
                                              outputs !! i]}) [0..length outputs - 1]

generateInspectDebugAggregate :: DatalogProgram -> Int -> Rule -> Int -> [RuleRHS]
generateInspectDebugAggregate d ruleIdx rule index =
  let
    input1 = eTupField (eVar $ rhsVar $ (ruleRHS rule !! index)) 0
    outputs = Compile.recordAfterPrefix d rule index
  in map (\i -> RHSInspect {rhsInspectExpr = eApply "debug.debug_event"
                                             [generateOperatorIdExpr ruleIdx index i,
                                              ddlogWeightExpr,
                                              ddlogTimestampExpr,
                                              input1,
                                              outputs !! i]}) [0..length outputs -1]

mkInspect :: DatalogProgram -> Int -> Rule -> Int -> Maybe [RuleRHS]
mkInspect d ruleIdx rule index =
  let rhsRule = ruleRHS rule
  in if index == 0 && index < length rhsRule - 1
        then Nothing
        else if rhsIsCondition (rhsRule !! index) && index /= length rhsRule - 1 && rhsIsCondition (rhsRule !! (index + 1))
                then Nothing
                else if index == 0
                     then Just $ generateInspectDebug d ruleIdx rule index -- single term rule
                     else case rhsRule !! index of
                          RHSLiteral{rhsPolarity=True} -> Just $ generateInspectDebugJoin d ruleIdx rule index -- join
                          RHSAggregate{} -> Just $ generateInspectDebugAggregate d ruleIdx rule index -- aggregate
                          _ -> Just $ generateInspectDebug d ruleIdx rule index -- antijoin, flatmap, filter/assignment, inspect

-- Insert inspect debug hook after each RHS term, except for the following:
-- 1. If a group of conditions appear consecutively, inspect debug hook is only
-- inserted after the last condition in the group.
-- 2. Inspect debug hook is not inserted after the first term, unless the rule
-- only contains one literal.
-- 3. If a rule has multiple heads, then multiple inspect is inserted after the last
-- term corresponding to each head.
insertRHSInspectDebugHooks :: DatalogProgram -> Int -> Rule -> [RuleRHS]
insertRHSInspectDebugHooks d rlIdx rule =
  concatMap (\i -> let inspect = concat $ maybeToList $ mkInspect d rlIdx rule i in
                   (ruleRHS rule !! i) : inspect) [0..length (ruleRHS rule) - 1]

debugUpdateRHSRules :: DatalogProgram -> Int -> Rule -> [RuleRHS]
debugUpdateRHSRules d rlIdx rule =
  let
    -- First pass updates RHSLiteral without any binding with a binding.
    rhs =  map addBindingToRHSLiteral $ zip (ruleRHS rule) [0..]
    -- Second pass updates RHSAggregate to use the debug function (so that inputs are not dropped).
    rhs' = concatMap (updateRHSAggregate d rule {ruleRHS = rhs}) [0..length rhs - 1]
  in insertRHSInspectDebugHooks d rlIdx rule {ruleRHS = rhs'}

-- Insert an aggregate function that wraps the original function used in the aggregate term.
-- For example, if an aggregate operator uses std.group_max(), i.e., var c = Aggregate((a), group_max(b)).
-- The following aggregate function is generated:
-- function __debug_std.group_max (g: std.Group<'K,('I, 'V)>): (std.Set<'I>, 'V)
-- {
--    ((var inputs, var original_group) = debug.debug_split_group(g);
--     (inputs, std.group_max(original_group)))
-- }
-- In the above example, fname is the original function name prefixed with __debug_.
-- debug_split_group takes in a Group of tuple ('I, 'V) and splits it into a
-- Set of 'I and Group of 'V.
insertDebugAggregateFunction :: M.Map String Function -> String -> String -> M.Map String Function
insertDebugAggregateFunction functions fname origFname=
  let
    funcBody = eSeq (eSet (eTuple [eVarDecl "inputs", eVarDecl "original_group"])
                          (eApply "debug.debug_split_group" [eVar "g"]))
                    (eTuple [eVar "inputs", eApply origFname [eVar "original_group"]])
    function = Function {funcPos = nopos,
                         funcAttrs = [],
                         funcName = fname,
                         funcArgs = [FuncArg {argPos = nopos,
                                              argName = "g",
                                              argMut = False,
                                              argType = tOpaque "std.Group" [tVar "K", tTuple [tVar "I", tVar "V"]]}],
                         funcType = tTuple [tOpaque "std.Set" [tVar "I"], tVar "V"],
                         funcDef = Just funcBody}
  in M.insert fname function functions

-- Generate and insert into the map of functions a wrapper aggregate function for
-- each aggregate function used in the rule.
debugUpdateFunctions :: [Rule] -> M.Map String Function -> M.Map String Function
debugUpdateFunctions rules functions =
  let
    aggregates = filter rhsIsAggregate $ concatMap ruleRHS rules
  in foldl' (\acc aggregate -> insertDebugAggregateFunction acc ("__debug_" ++ (rhsAggFunc aggregate)) (rhsAggFunc aggregate)) functions aggregates
