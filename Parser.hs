{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
module Parser
    ( parseLC
    , application
    , appP'
    ) where

import Data.Function
import Data.Char
import Data.List
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Monoid
import Control.Applicative (some,liftA2,Alternative())
import Control.Arrow
import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Trans
import qualified Text.Parsec.Indentation.Char as I
import Text.Parsec.Indentation
import Text.Parsec hiding (optional)

import qualified Pretty as P
import Type
import ParserUtil

-------------------------------------------------------------------------------- parser combinators

type P = P_ ()      -- no state for the parser

-- see http://blog.ezyang.com/2014/05/parsec-try-a-or-b-considered-harmful/comment-page-1/#comment-6602
try' s m = try m <?> s

qualified_ id = do
    q <- try' "qualification" $ {-Unspaced-} upperCase <* dot
    (N t qs n i) <- qualified_ id
    return $ N t (q:qs) n i
  <|>
    id

backquoted id = try' "backquoted" ({-runUnspaced-} ({-Unspaced-} (operator "`") *> {-Unspaced-} id <* {-Unspaced-} (operator "`")))

-------------------------------------------------------------------------------- position handling

-- compose ranges through getTag
infixl 9 <->
a <-> b = getTag a `mappend` getTag b

addPos :: (Range -> a -> b) -> P a -> P b
addPos f m = do
    p1 <- position
    a <- m
    p2 <- positionBeforeSpace
    return $ f (Range p1 p2) a

addDPos = addPos (,)
addPPos = addPos PatR
addEPos = addPos ExpR

-------------------------------------------------------------------------------- identifiers

check msg p m = try' msg $ do
    x <- m
    if p x then return x else fail $ msg ++ " expected"

upperCase, lowerCase, symbols, colonSymbols :: P String
upperCase = check "uppercase ident" (isUpper . head) $ ident lcIdents
lowerCase = check "lowercase ident" (isLower . head) $ ident lcIdents
symbols   = check "symbols" ((/=':') . head) $ ident lcOps
colonSymbols = "Cons" <$ operator ":" <|> check "symbols" ((==':') . head) (ident lcOps)

--------------------------------------------------------------------------------

typeConstructor, upperCaseIdent, typeVar, var, varId, qIdent, operator', conOperator, moduleName :: P Name
typeConstructor = upperCase <&> \i -> TypeN' i (P.text i)
upperCaseIdent  = upperCase <&> ExpN
typeVar         = (\p i -> TypeN' i $ P.text $ i ++ show p) <$> position <*> lowerCase
var             = (\p i -> ExpN' i $ P.text $ i ++ show p) <$> position <*> lowerCase
qIdent          = qualified_ (var <|> upperCaseIdent)
conOperator     = (\p i -> ExpN' i $ P.text $ i ++ show p) <$> position <*> colonSymbols
varId           = var <|> parens operator'
operator'       = (\p i -> ExpN' i $ P.text $ i ++ show p) <$> position <*> symbols
              <|> conOperator
              <|> backquoted (var <|> upperCaseIdent)
moduleName      = qualified_ upperCaseIdent

-------------------------------------------------------------------------------- literals

literal :: P Lit
literal
    =   LFloat <$> try double
    <|> LInt <$> try natural
    <|> LChar <$> charLiteral
    <|> LString <$> stringLiteral

-------------------------------------------------------------------------------- patterns

getP (PatR _ x) = x
appP' (PCon' r n []) ps = PCon' r n ps
appP' p ps = error $ "appP' " ++ P.ppShow (p, ps)

---------------------

pattern', patternAtom :: P PatR
pattern'
    = addPPos $ PPrec_ <$> pat <*> ((op >>= pat') <|> return [])
  where
    pat' o = do
            (e, o') <- try $ (,) <$> pat <*> op
            es <- pat' o'
            return $ (o, e): es
        <|> do
            e <- pattern'
            return [(o, e)]

    pat = addPPos (PCon_ () <$> upperCaseIdent <*> many patternAtom) <|> patternAtom

    op = addPPos $ PCon_ () <$> conOperator <*> pure []

patternAtom = addPPos $
        Wildcard_ () <$ operator "_"
    <|> PLit_ <$> literal
    <|> PAt_ <$> try' "at pattern'" (var <* operator "@") <*> patternAtom
    <|> PVar_ () <$> var
    <|> PCon_ () <$> upperCaseIdent <*> pure []
    <|> pTuple <$> parens (sepBy1 pattern' comma)
    <|> PRecord_ <$> braces (commaSep $ (,) <$> var <* colon <*> pattern')
    <|> getP . mkList <$> brackets (commaSep pattern')
  where
    mkList = foldr cons nil
      where
        nil = PCon' mempty (ExpN "Nil") []
        cons a b = PCon' mempty (ExpN "Cons") [a, b]

    pTuple [PatR _ x] = x
    pTuple xs = PTuple_ xs

-------------------------------------------------------------------------------- expressions

eTuple p [ExpR _ x] = ExpR p x
eTuple p xs = ExpR p $ ETuple_ xs
eRecord p xs = ERecordR' p xs
eNamedRecord p n xs = ENamedRecordR' p n xs
eVar p n = EVarR' p n
eLam p e = ELamR' (p <-> e) p e
eApp :: ExpR -> ExpR -> ExpR
eApp a b = EAppR' (a <-> b) a b
eTyping :: ExpR -> ExpR -> ExpR
eTyping a b = ETypeSigR' (a <-> b) a b
eTyApp a b = ETyAppR (a <-> b) a b

application :: [ExpR] -> ExpR
application = foldl1 eApp

eLets :: [DefinitionR] -> ExpR -> ExpR
eLets l a = foldr ($) a $ map eLet $ groupDefinitions l
  where
    eLet (r, DValueDef (ValueDef a b)) = \x -> ELetR' (r `mappend` getTag x) a b x

desugarSwizzling :: [Char] -> ExpR -> ExpR
desugarSwizzling cs e = eTuple mempty [eApp (EFieldProjR' mempty $ ExpN [c]) e | c <- cs]

---------------------

withTypeSig p = do
    e <- p 
    t <- optional $ operator "::" *> polytype
    return $ maybe e (eTyping e) t

expression :: P ExpR
expression = withTypeSig $
        ifthenelse
    <|> caseof
    <|> letin
    <|> lambda
    <|> eApp <$> addPos eVar (const (ExpN "negate") <$> operator "-") <*> expressionOpAtom -- TODO: precedence
    <|> expressionOpAtom
 where
    lambda :: P ExpR
    lambda = (\(ps, e) -> foldr eLam e ps) <$> (operator "\\" *> ((,) <$> many patternAtom <* operator "->" <*> expression))

    ifthenelse :: P ExpR
    ifthenelse = addPos (\r (a, b, c) -> eApp (eApp (eApp (eVar r (ExpN "ifThenElse")) a) b) c) $
        (,,) <$ keyword "if" <*> expression <* keyword "then" <*> expression <* keyword "else" <*> expression

    caseof :: P ExpR
    caseof = addPos (uncurry . compileCases) $ (,)
        <$ keyword "case" <*> expression <* keyword "of"
        <*> localIndentation Ge (localAbsoluteIndentation $ some $ (,) <$> pattern' <*> localIndentation Gt (whereRHS $ operator "->"))

    letin :: P ExpR
    letin = eLets
        <$ keyword "let" <*> localIndentation Ge (localAbsoluteIndentation $ some valueDef)
        <* keyword "in" <*> expression

    expressionOpAtom = addEPos $ EPrec_ <$> exp <*> ((op >>= expression') <|> return [])
      where
        expression' o = do
                (e, o') <- try $ (,) <$> exp <*> op
                es <- expression' o'
                return $ (o, e): es
            <|> (:[]) . (,) o <$> expression

        exp = application <$> some expressionAtom

        op = addPos eVar operator'

expressionAtom :: P ExpR
expressionAtom = do
    e <- expressionAtom_
    sw <- optional $ do
        operator "%"
        ident lcIdents
    ts <- many $ do
        operator "@"
        typeAtom
    return $ foldl eTyApp (maybe id desugarSwizzling sw e) ts
  where
    expressionAtom_ :: P ExpR
    expressionAtom_ =
            listExp
        <|> addPos eLit literal
        <|> recordExp
        <|> recordExp'
        <|> recordFieldProjection
        <|> addPos eVar qIdent
        <|> addPos eTuple (parens $ commaSep expression)
     where
      recordExp :: P ExpR
      recordExp = addPos eRecord $ braces $ commaSep $ (,) <$> var <* colon <*> expression

      recordExp' :: P ExpR
      recordExp' = try $ addPos (uncurry . eNamedRecord) $ (,) <$> upperCaseIdent <*> braces (commaSep $ (,) <$> var <* keyword "=" <*> expression)

      recordFieldProjection :: P ExpR
      recordFieldProjection = try $ flip eApp <$> addPos eVar var <*>
            addPos EFieldProjR' ({-runUnspaced $-} dot *> {-Unspaced-} var)

      eLit p l@LInt{} = EAppR' p (eVar mempty (ExpN "fromInt")) $ ELitR' mempty l
      eLit p l = ELitR' p l

      listExp :: P ExpR
      listExp = addPos (\p -> foldr cons (nil p)) $ brackets $ commaSep expression
        where
          nil r = eVar (r{-TODO-}) $ ExpN "Nil"
          cons a b = eApp (eApp (eVar mempty{-TODO-} (ExpN "Cons")) a) b

-------------------------------------------------------------------------------- types

typeVarKind =
      parens ((,) <$> typeVar <* operator "::" <*> monotype)
  <|> (,) <$> typeVar <*> addEPos (pure Star_)

typeContext :: P (ExpR -> ExpR)   -- TODO
typeContext = try' "type context" $ (tyC <|> parens (foldr (.) id <$> commaSep tyC)) <* operator "=>"
  where
    tyC = addPos addC $
            CEq <$> try (monotype <* operator "~") <*> (mkTypeFun <$> monotype)
        <|> CClass <$> typeConstructor <*> typeAtom
    addC :: Range -> ConstraintR -> ExpR -> ExpR
    addC r c = ExpR r . Forall_ Nothing (ExpR r $ ConstraintKind_ c)

    mkTypeFun e = case getArgs e of (n, reverse -> ts) -> TypeFun n ts
      where
        getArgs = \case
            ExpR _ (TCon_ () n) -> (n, [])
            ExpR _ (EApp_ () x y) -> id *** (y:) $ getArgs x
            x -> error $ "mkTypeFun: " ++ P.ppShow x

polytype :: P ExpR
polytype =
    do  keyword "forall"
        vs <- some $ addDPos typeVarKind
        dot
        t <- polytype
        return $ foldr (\(p, (v, k)) t -> ExpR (p <> getTag t) $ Forall_ (Just v) k t) t vs
  <|> typeContext <*> polytype
  <|> monotype

monotype :: P ExpR
monotype = do
    t <- foldl1 eApp <$> some typeAtom
    maybe t (tArr t) <$> optional (operator "->" *> polytype)
  where
    tArr t a = ExpR (t <-> a) $ Forall_ Nothing t a

typeAtom :: P ExpR
typeAtom = addEPos $
        typeRecord
    <|> Star_ <$ operator "*"
    <|> EVar_ () <$> typeVar
    <|> ELit_ <$> (LNat . fromIntegral <$> natural <|> literal)
    <|> TCon_ () <$> typeConstructor
    <|> tTuple <$> parens (commaSep monotype)
    <|> EApp_ () (ExpR mempty $ TCon_ () (TypeN' "List" "List")) <$> brackets monotype
  where
    tTuple [ExpR _ t] = t
    tTuple ts = TTuple_ ts

    typeRecord = undef "trec" $ do
        braces (commaSep1 typeSignature >> optional (operator "|" >> void typeVar))
      where
        undef msg = (const (error $ "not implemented: " ++ msg) <$>)

-------------------------------------------------------------------------------- function and value definitions

alts :: Int -> [ExpR] -> ExpR
alts _ [e] = e
alts i es = EAltsR' (foldMap getTag es) i es

compileWhereRHS :: WhereRHS -> ExpR
compileWhereRHS (WhereRHS r md) = maybe x (flip eLets x) md where
    x = case r of
        NoGuards e -> e
        Guards p gs -> foldr addGuard (ExpR p{-TODO-} (ENext_ ())) gs
          where
            addGuard (b, x) y = eApp (eApp (eApp (eVar p{-TODO-} (ExpN "ifThenElse")) b) x) y

compileCases :: Range -> ExpR -> [(PatR, WhereRHS)] -> ExpR
compileCases r e rs = eApp (alts 1 [eLam p $ compileWhereRHS r | (p, r) <- rs]) e

groupDefinitions :: [DefinitionR] -> [DefinitionR]
groupDefinitions defs = concatMap mkDef . map compileRHS . groupBy (f `on` snd) $ defs
  where
    f (h -> Just x) (h -> Just y) = x == y
    f _ _ = False

    h ( (PreValueDef (_, n) _ _)) = Just n
    h ( (DValueDef (ValueDef p _))) = name p        -- TODO
    h ( (DTypeSig (TypeSig n _))) = Just n
    h _ = Nothing

    name (PVar' _ n) = Just n
    name _ = Nothing

    mkDef = \case
         (r, PreInstanceDef c t ds) -> [(r, InstanceDef c t [v | (r, DValueDef v) <- groupDefinitions ds])]
         x -> [x]

    compileRHS :: [DefinitionR] -> DefinitionR
    compileRHS ds = case ds of
        ((r1, DTypeSig (TypeSig _ t)): ds@((r2, PreValueDef{}): _)) -> (r1 `mappend` r2, mkAlts (`eTyping` t) ds)
        ds@((r, PreValueDef{}): _) -> (r, mkAlts id ds)
        [x] -> x
      where
        mkAlts f ds@( (_, PreValueDef (r, n) _ _): _)
            = DValueDef $ ValueDef (PVar' r n) $ f $ alts i als
          where
            i = allSame is
            allSame (n:ns) | all (==n) ns = n
            (als, is) = unzip [(foldr eLam (compileWhereRHS rhs) pats, length pats) |  (_, PreValueDef _ pats rhs) <- ds]

---------------------

valueDef :: P DefinitionR
valueDef = addDPos $
   (do
    try' "function definition" $ do
      n <- addDPos varId
      localIndentation Gt $ do
        pats <- many patternAtom
        lookAhead $ operator "=" <|> operator "|"
        return $ PreValueDef n pats
   <|> do
    try' "value definition" $ do
      n <- pattern'
      n2 <- optional $ do
          op <- addDPos operator'
          n2 <- pattern'
          return (op, n2)
      localIndentation Gt $ do
        lookAhead $ operator "=" <|> operator "|"
        return $ case n2 of
            Nothing -> \e -> DValueDef $ ValueDef n $ alts 0 [compileWhereRHS e]
            Just (op, n2) -> PreValueDef op [n, n2]
    )
 <*> localIndentation Gt (whereRHS $ operator "=")

whereRHS :: P () -> P WhereRHS
whereRHS delim =
    WhereRHS <$>
    (   NoGuards <$ delim <*> expression
    <|> addPos Guards (many $ (,) <$ operator "|" <*> expression <* delim <*> expression)
    ) <*>
    (   Just . concat <$> (keyword "where" *> localIndentation Ge (localAbsoluteIndentation $ some $ (:[]) <$> valueDef <|> typeSignature))
    <|> return Nothing
    )

-------------------------------------------------------------------------------- class and instance definitions

classDef :: P DefinitionR
classDef = addDPos $ do
  keyword "class"
  localIndentation Gt $ do
    optional typeContext
    c <- typeConstructor
    tvs <- many typeVarKind
    ds <- optional $ do
      keyword "where"
      localIndentation Ge $ localAbsoluteIndentation $ many typeSignature
    return $ ClassDef c tvs [d | (_, DTypeSig d) <- maybe [] concat ds]

instanceDef :: P DefinitionR
instanceDef = addDPos $ do
  keyword "instance"
  localIndentation Gt $ do
    optional typeContext
    c <- typeConstructor
    t <- typeAtom
    ds <- optional $ do
      keyword "where"
      localIndentation Ge $ localAbsoluteIndentation $ many valueDef
    return $ PreInstanceDef c t $ fromMaybe [] ds

-------------------------------------------------------------------------------- data definition

dataDef :: P DefinitionR
dataDef = addDPos $ do
 keyword "data"
 localIndentation Gt $ do
  tc <- typeConstructor
  tvs <- many typeVarKind
  do
    do
      keyword "where"
      ds <- localIndentation Ge $ localAbsoluteIndentation $ many $ do
        cs <- sepBy1 upperCaseIdent comma
        localIndentation Gt $ do
            t <- operator "::" *> polytype
            return [(c, t) | c <- cs]
      return $ GADT tc tvs $ concat ds
   <|>
    do
      let dataConDef = addDPos $ do
            tc <- upperCaseIdent
            tys <-   braces (commaSep $ FieldTy <$> (Just <$> varId) <* keyword "::" <* optional (operator "!") <*> polytype)
                <|>  many (FieldTy Nothing <$ optional (operator "!") <*> typeAtom)
            return $ ConDef tc tys
      operator "="
      ds <- sepBy dataConDef $ operator "|"
      derivingStm
      return $ DDataDef tc tvs ds
  where
    derivingStm = optional $ keyword "deriving" <* (void typeConstructor <|> void (parens $ commaSep typeConstructor))

-------------------------------------------------------------------------------- type synonym

typeSynonym :: P ()
typeSynonym = void $ do
  keyword "type"
  localIndentation Gt $ do
    typeConstructor
    many typeVar
    operator "="
    void polytype

-------------------------------------------------------------------------------- type family

typeFamily :: P DefinitionR
typeFamily = addDPos $ do
    try $ keyword "type" >> keyword "family"
    tc <- typeConstructor
    tvs <- many typeVarKind
    res <- optional $ do
        operator "::"
        monotype
    return $ TypeFamilyDef tc tvs $ fromMaybe (ExpR mempty Star_) res

-------------------------------------------------------------------------------- type signature

typeSignature :: P [DefinitionR]
typeSignature = do
  ns <- try' "type signature" $ do
    ns <- sepBy1 varId comma
    localIndentation Gt $ operator "::"
    return ns
  t <- localIndentation Gt $ do
    optional (operator "!") *> polytype
  return [(mempty, DTypeSig $ TypeSig n t) | n <- ns]

axiom :: P [DefinitionR]
axiom = do
  ns <- try' "axiom" $ do
    ns <- sepBy1 (varId <|> upperCaseIdent) comma
    localIndentation Gt $ operator "::"
    return ns
  t <- localIndentation Gt $ do
    optional (operator "!") *> polytype
  return [(mempty, DAxiom $ TypeSig n t) | n <- ns]

-------------------------------------------------------------------------------- fixity declarations

fixityDef :: P [DefinitionR]
fixityDef = do
  dir <-    Nothing      <$ keyword "infix" 
        <|> Just FDLeft  <$ keyword "infixl"
        <|> Just FDRight <$ keyword "infixr"
  localIndentation Gt $ do
    i <- natural
    ns <- sepBy1 (addDPos operator') comma
    return [(p, PrecDef n (dir, fromIntegral i)) | (p, n) <- ns]

-------------------------------------------------------------------------------- modules

importDef :: P Name
importDef = do
  keyword "import"
  optional $ keyword "qualified"
  n <- moduleName
  let importlist = parens (commaSep (varId <|> upperCaseIdent))
  optional $
        (keyword "hiding" >> importlist)
    <|> importlist
  optional $ do
    keyword "as"
    moduleName
  return n

moduleDef :: FilePath -> P ModuleR
moduleDef fname = do
  modn <- optional $ do
    modn <- keyword "module" *> moduleName
    optional $ parens (commaSep varId)
    keyword "where"
    return modn
  localAbsoluteIndentation $ do
    idefs <- many importDef
    -- TODO: unordered definitions
    defs <- groupDefinitions . concat <$> many
        (   (:[]) <$> dataDef
        <|> concat <$ keyword "axioms" <*> localIndentation Gt (localAbsoluteIndentation $ many axiom)
        <|> typeSignature
        <|> (:[]) <$> typeFamily
        <|> const [] <$> typeSynonym
        <|> (:[]) <$> classDef
        <|> (:[]) <$> valueDef
        <|> fixityDef
        <|> (:[]) <$> instanceDef
        )
    return $ Module
      { moduleImports = (if modn == Just (ExpN "Prelude") then id else (ExpN "Prelude":)) idefs
      , moduleExports = mempty
      , definitions   = defs
      }

--------------------------------------------------------------------------------

parseLC :: MonadError ErrorMsg m => FilePath -> String -> m ModuleR
parseLC fname src = either throwParseError return . runParser' fname (moduleDef fname) $ src

