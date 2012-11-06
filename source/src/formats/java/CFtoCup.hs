{-
    BNF Converter: Java Cup Generator
    Copyright (C) 2004  Author:  Markus Forsberg, Michael Pellauer

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- 
   **************************************************************
    BNF Converter Module

    Description   : This module generates the CUP input file. It
                    follows the same basic structure of CFtoHappy.

    Author        : Michael Pellauer (pellauer@cs.chalmers.se)

    License       : GPL (GNU General Public License)

    Created       : 26 April, 2003                           

    Modified      : 2 September, 2003                          

   
   ************************************************************** 
-}
module CFtoCup ( cf2Cup ) where

import CF
import Data.List (intersperse, isPrefixOf)
import Data.Char (isUpper)
import NamedVariables
import TypeChecker  -- We need to (re-)typecheck to figure out list instances in
		    -- defined rules.
import ErrM
import Utils ( (+++) )

-- Type declarations
type Rules       = [(NonTerminal,[(Pattern,Action)])]
type NonTerminal = String
type Pattern     = String
type Action      = String
type MetaVar     = String

--The environment comes from the CFtoJLex
cf2Cup :: String -> String -> CF -> SymEnv -> String
cf2Cup packageBase packageAbsyn cf env = unlines 
    [
     header,
     declarations packageAbsyn (allCats cf),
     tokens env,
     specialToks cf,
     specialRules cf,
     prEntryPoint cf,
     prRules (rulesForCup packageAbsyn cf env)
    ]
    where
      header :: String
      header = unlines 
         ["// -*- Java -*- This Cup file was machine-generated by BNFC",
	  "package" +++ packageBase ++ ";",
	  "",
	  "import java_cup.runtime.*;",
	  "import" +++ packageAbsyn ++ ".*;",
	  "",
	  "parser code {:",
	  parseMethod packageAbsyn (firstEntry cf),
	  definedRules packageAbsyn cf,
	  -- unlines $ map (parseMethod packageAbsyn) (allEntryPoints cf),
	  "public void syntax_error(Symbol cur_token)",
  	  "{",
    	  "\treport_error(\"Syntax Error, trying to recover and continue parse...\", cur_token);",
	  "}",
	  "",
 	  "public void unrecovered_syntax_error(Symbol cur_token) throws java.lang.Exception",
 	  "{",
          "\tthrow new Exception(\"Unrecoverable Syntax Error\");",
          "}",
	  "",
	  ":}"
	  ]

definedRules :: String -> CF -> String
definedRules packageAbsyn cf =
	unlines [ rule f xs e | FunDef f xs e <- pragmasOfCF cf ]
    where
	ctx = buildContext cf

	list = LC (const "null") (\t -> "List" ++ unBase t)
	    where
		unBase (ListT t) = unBase t
		unBase (BaseT x) = normCat x

	rule f xs e =
	    case checkDefinition' list ctx f xs e of
		Bad err	-> error $ "Panic! This should have been caught already:\n" ++ err
		Ok (args,(e',t)) -> unlines
		    [ "public " ++ javaType t ++ " " ++ f ++ "_ (" ++
			concat (intersperse ", " $ map javaArg args) ++ ") {"
		    , "  return " ++ javaExp e' ++ ";"
		    , "}"
		    ]
	    where

		javaType :: Base -> String
		javaType (ListT (BaseT x)) = packageAbsyn ++ ".List" ++ normCat x
		javaType (ListT t)	   = javaType t
		javaType (BaseT x)
		    | isToken x ctx = "String"
		    | otherwise	    = packageAbsyn ++ "." ++ normCat x

		javaArg :: (String, Base) -> String
		javaArg (x,t) = javaType t ++ " " ++ x ++ "_"

		javaExp :: Exp -> String
		javaExp (Const "null") = "null"
		javaExp (Const x)
		    | elem x xs		= x ++ "_"	-- argument
		javaExp (App (Const t) [e])
		    | isToken t ctx	= call ("new String") [e]
		javaExp (App (Const x) es)
		    | isUpper (head x)	= call ("new " ++ packageAbsyn ++ "." ++ x) es
		    | otherwise		= call (x ++ "_") es
		javaExp (LitInt n)	= "new Integer(" ++ show n ++ ")"
		javaExp (LitDouble x)	= "new Double(" ++ show x ++ ")"
		javaExp (LitChar c)	= "new Character(" ++ show c ++ ")"
		javaExp (LitString s)	= "new String(" ++ show s ++ ")"

		call x es = x ++ "(" ++ concat (intersperse ", " $ map javaExp es) ++ ")"

-- peteg: FIXME JavaCUP can only cope with one entry point AFAIK.
prEntryPoint :: CF -> String
prEntryPoint cf = unlines ["", "start with " ++ firstEntry cf ++ ";", ""]
--		    [ep]  -> unlines ["", "start with " ++ ep ++ ";", ""]
--		    eps   -> error $ "FIXME multiple entry points." ++ show eps

--This generates a parser method for each entry point.
parseMethod :: String -> Cat -> String
parseMethod packageAbsyn cat = 
  if normCat cat /= cat
    then ""
    else unlines
	     [
	      "  public" +++ packageAbsyn ++ "." ++ cat' +++ "p" ++ cat' ++ "()"
	        ++ " throws Exception",
	      "  {",
	      "\tSymbol res = parse();",
	      "\treturn (" ++ packageAbsyn ++ "." ++ cat' ++ ") res.value;", 
	      "  }"
	     ]
    where cat' = identCat (normCat cat)

--non-terminal types
declarations :: String -> [NonTerminal] -> String
declarations packageAbsyn ns = unlines (map (typeNT packageAbsyn) ns)
 where
   typeNT _nm nt = "nonterminal" +++ packageAbsyn ++ "."
		    ++ identCat (normCat nt) +++ identCat nt ++ ";"

--terminal types
tokens :: SymEnv -> String
tokens ts = unlines (map declTok ts)
 where
  declTok (s,r) = "terminal" +++ r ++ ";    //   " ++ s

specialToks :: CF -> String
specialToks cf = unlines [ 
  ifC "String" "terminal String _STRING_;",
  ifC "Char" "terminal Character _CHAR_;",
  ifC "Integer" "terminal Integer _INTEGER_;",
  ifC "Double" "terminal Double _DOUBLE_;",
  ifC "Ident" "terminal String _IDENT_;"
  ]
   where
    ifC cat s = if isUsedCat cf cat then s else ""

-- This handles user defined tokens
-- FIXME
specialRules:: CF -> String
specialRules cf =
    unlines ["terminal String " ++ name ++ ";" | (name, _) <- tokenPragmas cf]

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForCup :: String -> CF -> SymEnv -> Rules
rulesForCup packageAbsyn cf env = map mkOne $ ruleGroups cf where
  mkOne (cat,rules) = constructRule packageAbsyn cf env rules cat

-- For every non-terminal, we construct a set of rules. A rule is a sequence of
-- terminals and non-terminals, and an action to be performed.
constructRule :: String -> CF -> SymEnv -> [Rule] -> NonTerminal -> (NonTerminal,[(Pattern,Action)])
constructRule packageAbsyn cf env rules nt =
    (nt, [(p,generateAction packageAbsyn nt (funRule r) (revM b m))
	  | r0 <- rules,
	    let (b,r) = if isConsFun (funRule r0) && elem (valCat r0) revs 
                          then (True, revSepListRule r0) 
                          else (False, r0)
                (p,m) = generatePatterns cf env r])
 where
   --this basically reverses revSepListRule for the parameters
   revM False m = m
   revM True (h:c:t) = (t ++ [c] ++ [h])
   revs = reversibleCats cf

-- Generates a string containing the semantic action.
generateAction :: String -> NonTerminal -> Fun -> [MetaVar] -> Action
generateAction packageAbsyn nt f ms =
 if isNilFun f
 then "RESULT = null;"
 else if isOneFun f
 then "RESULT = new " ++ packageAbsyn ++ "." ++ identCat (normCat nt) ++
 (concat $ ["("] ++ ms ++ [",null);"])
 else
 (unwords $
    (if isCoercion f then [unwords revLists, "RESULT = "] 
     else if isDefinedRule f then [unwords revLists, "RESULT = parser." ++ f ++ "_"]
     else [unwords revLists, "RESULT = new " ++ packageAbsyn ++ "." ++ f']
    )) 
	++ (concat $ ["("] ++ ms'' ++ [");"])
   where
     f' = if isConsFun f then identCat (normCat nt)
	    else f
     (revLists, ms') = revMs [] [] ms
     ms'' = reverse ms'
     revMs ls ns [] = (ls,ns)
     revMs ls ns (m:ms) = if "list_" `isPrefixOf` m
       then revMs (("if (" ++ m' ++ " != null) " ++ m' ++ " = " ++ m' ++ ".reverse(); ") : ls)
         (m' : ns) ms
       else revMs ls (m:ns) ms
      where m' = drop 5 m --remove the list marker

-- Generate patterns and a set of metavariables indicating 
-- where in the pattern the non-terminal
generatePatterns :: CF -> SymEnv -> Rule -> (Pattern,[MetaVar])
generatePatterns cf env r = case rhsRule r of
  []  -> (" /* empty */ ",[])
  its -> (mkIt env 1 its, metas its) 
 where
   mkIt _env _n [] = []
   mkIt env n (i:is) = case i of
     Left c -> c' ++ ":p_" ++ (show (n :: Int)) +++ (mkIt env (n+1) is)
                  where 
		   c' = case c of
      			 "Ident"   -> "_IDENT_"
      			 "Integer" -> "_INTEGER_"
     			 "Char"    -> "_CHAR_"
  			 "Double"  -> "_DOUBLE_"
    			 "String"  -> "_STRING_"
		         _         -> identCat c
     Right s -> case (lookup s env) of
     		(Just x) -> x +++ (mkIt env (n+1) is)
		(Nothing) -> (mkIt env n is)
   metas its = intersperse "," [revIf c ("p_" ++ (show i)) | (i,Left c) <- zip [1 :: Int ..] its]
   --This is slightly messy, but it marks lists for reversal.
   revIf c m = if (not (isConsFun (funRule r)) && elem c revs) 
                 then "list_" ++ m -- ("(reverse " ++ m ++ ")") --not yet!
               else m  -- no reversal in the left-recursive Cons rule itself
   revs = reversibleCats cf

-- We have now constructed the patterns and actions, 
-- so the only thing left is to merge them into one string.
prRules :: Rules -> String
prRules [] = []
prRules ((nt, []):rs) = prRules rs --internal rule
prRules ((nt,((p,a):ls)):rs) = 
  (unwords [nt', "::=", p, "{:", a, ":}", "\n" ++ pr ls]) ++ ";\n" ++ prRules rs
 where 
  nt' = identCat nt
  pr []           = []
  pr ((p,a):ls)   = (unlines [(concat $ intersperse " " ["  |", p, "{:", a , ":}"])]) ++ pr ls
	 
