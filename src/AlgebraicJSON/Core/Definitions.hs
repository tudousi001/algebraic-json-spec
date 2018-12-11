-- Copyright 2018 LuoChen (luochen1990@gmail.com). Apache License 2.0

{-# language TupleSections #-}
{-# language FlexibleInstances #-}

module AlgebraicJSON.Core.Definitions where

import Prelude hiding (otherwise)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Semigroup
import Data.Foldable (fold, foldMap)
import Data.List
import Data.Maybe
import Data.Fix
import Data.Char (isAlphaNum)
import Text.MultilingualShow
import Control.Monad.State
import AlgebraicJSON.Core.Tools

---------------------------------------------------------------------
--------------------------- JsonData --------------------------------
---------------------------------------------------------------------

-- | JSON Data in ADT
data JsonData =
      JsonNumber Double
    | JsonText String
    | JsonBoolean Bool
    | JsonNull
    | JsonArray [JsonData]
    | JsonObject [(String, JsonData)]
    deriving (Eq, Ord)

-- | literal JSON
instance Show JsonData where
    show dat = case dat of
        JsonNumber x -> show x
        JsonText s -> show s
        JsonBoolean b -> show b
        JsonNull -> "null"
        JsonArray xs -> "[" ++ intercalate ", " (map show xs) ++ "]"
        JsonObject ps -> "{" ++ intercalate ", " [showIdentifier k ++ ": " ++ show v | (k, v) <- ps] ++ "}"

extendObj :: JsonData -> JsonData -> JsonData
extendObj (JsonObject ps1) (JsonObject ps2) = JsonObject (ps1 ++ ps2)
extendObj _ _ = error "extendObj must be used on two JsonObject"

lookupObj :: String -> JsonData -> Maybe JsonData
lookupObj k (JsonObject kvs) = (M.lookup k (M.fromList kvs))
lookupObj _ _ = error "lookupObj must be used on JsonObject"

lookupObj' :: String -> JsonData -> JsonData
lookupObj' k (JsonObject kvs) = (fromMaybe JsonNull (M.lookup k (M.fromList kvs)))
lookupObj' _ _ = error "lookupObj' must be used on JsonObject"

---------------------------------------------------------------------
------------------- Spec & CSpec & Shape & TyRep --------------------
---------------------------------------------------------------------

-- | the Spec parsed from user input
type Spec = Fix (TyRep Name DecProp ())

-- | the checked Spec, attached with choice maker
type CSpec = Fix (TyRep Name DecProp ChoiceMaker)

-- | the Shape of a Spec, ignore Ref, Refined information of Spec
type Shape = Fix (TyRep () () ())

-- | TyRep r p c tr' is a generic representation of Spec & CSpec & Shape,
-- | with Ref indexed by r, Refined with p, Alternative attached with c,
-- | and recursively defined on tr'.
data TyRep r p c tr' =
      Anything
    | Number
    | Text
    | Boolean
    | Null
    | ConstNumber Double
    | ConstText String
    | ConstBoolean Bool
    | Tuple Strictness [tr']
    | Array tr'
    | NamedTuple Strictness [(String, tr')]
    | TextMap tr'
    | Ref r
    | Refined tr' p
    | Alternative tr' tr' c

-- | a tool function to filter out prim TyRep nodes,
-- | we can use it to simplify pattern matching logic.
isPrimTyRepNode :: TyRep r p c tr' -> Bool
isPrimTyRepNode tr = case tr of
    Anything -> True
    Number -> True
    Text -> True
    Boolean -> True
    Null -> True
    ConstNumber n -> True
    ConstText s -> True
    ConstBoolean b -> True
    _ -> False

------------------- useful instances about TyRep --------------------

instance (Eq r, Eq p, Eq c, Eq tr') => Eq (TyRep r p c tr') where
    tr1 == tr2 = case (tr1, tr2) of
        (Anything, Anything) -> True
        (Number, Number) -> True
        (Text, Text) -> True
        (Boolean, Boolean) -> True
        (Null, Null) -> True
        (ConstNumber n1, ConstNumber n2) -> n1 == n2
        (ConstText s1, ConstText s2) -> s1 == s2
        (ConstBoolean b1, ConstBoolean b2) -> b1 == b2
        (Tuple s1 ts1, Tuple s2 ts2) -> s1 == s2 && ts1 == ts2
        (Array t1, Array t2) -> t1 == t2
        (NamedTuple s1 ps1, NamedTuple s2 ps2) -> s1 == s2 && ps1 == ps2
        (TextMap t1, TextMap t2) -> t1 == t2
        (Ref r1, Ref r2) -> r1 == r2
        (Refined t1 p1, Refined t2 p2) -> t1 == t2 && p1 == p2
        (Alternative a1 b1 c1, Alternative a2 b2 c2) -> a1 == a2 && b1 == b2 && c1 == c2
        _ -> False

class QuadFunctor f where
    quadmap :: (a -> a') -> (b -> b') -> (c -> c') -> (d -> d') -> f a b c d -> f a' b' c' d'
    quadmap1 :: (a -> a') -> f a b c d -> f a' b c d
    quadmap2 :: (b -> b') -> f a b c d -> f a b' c d
    quadmap3 :: (c -> c') -> f a b c d -> f a b c' d
    quadmap4 :: (d -> d') -> f a b c d -> f a b c d'

    quadmap1 f = quadmap f id id id
    quadmap2 f = quadmap id f id id
    quadmap3 f = quadmap id id f id
    quadmap4 f = quadmap id id id f

instance QuadFunctor TyRep where
    quadmap f1 f2 f3 f4 tr = case tr of
        Anything -> Anything
        Number -> Number
        Text -> Text
        Boolean -> Boolean
        Null -> Null
        ConstNumber n -> ConstNumber n
        ConstText s -> ConstText s
        ConstBoolean b -> ConstBoolean b
        Tuple s ts -> Tuple s (map f4 ts)
        Array t -> Array (f4 t)
        NamedTuple s ps -> NamedTuple s [(k, f4 v) | (k, v) <- ps]
        TextMap t -> TextMap (f4 t)
        Ref name -> Ref (f1 name)
        Refined t p -> Refined (f4 t) (f2 p)
        Alternative t1 t2 c -> Alternative (f4 t1) (f4 t2) (f3 c)

instance Functor (TyRep r p c) where
    fmap = quadmap4

instance Foldable (TyRep r p c) where
    foldMap f tr = case tr of
        Tuple s ts -> foldMap f ts
        Array t -> f t
        NamedTuple s ps -> foldMap (f . snd) ps
        TextMap t -> f t
        Refined t _ -> f t
        Alternative t1 t2 _ -> f t1 `mappend` f t2
        _ -> mempty

instance Traversable (TyRep r p c) where
    traverse f tr = case tr of
        Anything -> pure Anything
        Number -> pure Number
        Text -> pure Text
        Boolean -> pure Boolean
        Null -> pure Null
        ConstNumber n -> pure $ ConstNumber n
        ConstText s -> pure $ ConstText s
        ConstBoolean b -> pure $ ConstBoolean b
        Ref name -> pure $ Ref name
        Tuple s ts -> Tuple s <$> (traverse f ts)
        Array t -> Array <$> f t
        NamedTuple s ps -> NamedTuple s <$> sequenceA [(k,) <$> f v | (k, v) <- ps]
        TextMap t -> TextMap <$> f t
        Refined t p -> Refined <$> f t <*> pure p
        Alternative t1 t2 c -> Alternative <$> (f t1) <*> (f t2) <*> pure c

---------------------- useful tools about TyRep ---------------------

toSpec :: CSpec -> Spec
toSpec (Fix tr) = Fix $ quadmap id id (const ()) toSpec tr

toShape :: Env (Fix (TyRep Name p c)) -> (Fix (TyRep Name p' c')) -> Shape
toShape env sp = evalState (cataM g sp) S.empty where
    g :: TyRep Name p'' c'' Shape -> State (S.Set Name) Shape
    g tr = case tr of
        Ref name -> do
            --traceM ("name: " ++ name)
            visd <- get
            if name `S.member` visd
            then pure (Fix Anything)
            else do
                modify (S.insert name)
                r <- cataM g (env M.! name)
                modify (S.delete name)
                return r
        Refined t _ -> pure t
        Alternative t1 t2 _ -> pure (Fix $ Alternative t1 t2 ())
        t -> pure (Fix $ quadmap (const ()) (const ()) (const ()) id t)

acceptNull :: Shape -> Bool
acceptNull (Fix tr) = case tr of
    Null -> True
    Anything -> True
    Alternative t1 t2 _ -> acceptNull t1 || acceptNull t2
    _ -> False

-- | shadow matching, only process trivial cases, no recursion
matchOutline :: TyRep r p c tr' -> JsonData -> Bool
matchOutline tr d = case (tr, d) of
    (Anything, _) -> True
    (Number, (JsonNumber _)) -> True
    (Text, (JsonText _)) -> True
    (Boolean, (JsonBoolean _)) -> True
    (Null, JsonNull) -> True
    (ConstNumber n, d@(JsonNumber n')) -> if (n == n') then True else False
    (ConstText s, d@(JsonText s')) -> if (s == s') then True else False
    (ConstBoolean b, d@(JsonBoolean b')) -> if (b == b') then True else False
    (Tuple _ _, (JsonArray _)) -> True
    (Array _, (JsonArray _)) -> True
    (NamedTuple _ _, (JsonObject _)) -> True
    (TextMap _, (JsonObject _)) -> True
    (Refined t _, d) -> True
    (Ref _, _) -> True
    (Alternative _ _ _, _) -> True
    _ -> False

-- | generate example JsonData along a specific Shape
example :: Shape -> JsonData
example (Fix tr) = case tr of
    Anything -> JsonNull
    Number -> JsonNumber 0
    Text -> JsonText ""
    Boolean -> JsonBoolean True
    Null -> JsonNull
    ConstNumber n -> JsonNumber n
    ConstText s -> JsonText s
    ConstBoolean b -> JsonBoolean b
    Tuple _ ts -> JsonArray (map example ts)
    Array t -> JsonArray [(example t)]
    NamedTuple _ ps -> JsonObject [(k, example t) | (k, t) <- ps]
    TextMap t -> JsonObject [("k", example t)]
    Ref _ -> error "example cannot be used on Ref"
    Refined t _ -> error "examplecannot be used on Refined"
    Alternative a b _ -> example a

toJsonSpec :: Spec -> JsonData
toJsonSpec (Fix tr) = case tr of
    Anything -> tag "Anything"
    Number -> tag "Number"
    Text -> tag "Text"
    Boolean -> tag "Boolean"
    Null -> JsonNull
    ConstNumber n -> JsonNumber n
    ConstText s -> JsonText (escape s)
    ConstBoolean b -> JsonBoolean b
    Tuple Strict ts -> JsonArray (map toJsonSpec ts)
    Tuple Tolerant ts -> JsonArray (tag "Tuple*" : map toJsonSpec ts)
    Array t -> JsonArray [tag "Array", (toJsonSpec t)]
    NamedTuple Strict ps -> JsonObject [(k, toJsonSpec t) | (k, t) <- ps]
    NamedTuple Tolerant ps -> JsonArray [tag "NamedTuple*", JsonObject [(k, toJsonSpec t) | (k, t) <- ps]]
    TextMap t -> JsonArray [tag "TextMap", (toJsonSpec t)]
    Ref name -> JsonText ('$':name)
    Refined t p -> JsonArray [tag "Refined", (toJsonSpec t)]
    Alternative a b _ -> JsonArray [tag "Alternative", (toJsonSpec a), (toJsonSpec b)]
    where
        tag s = JsonText ('#':s)
        escape s = case s of (c:s') -> if c `elem` ['#', '$', '\\'] then '\\':s else s; _ -> s

fromJsonSpec :: JsonData -> Spec
fromJsonSpec d = Fix $ case d of
    JsonNull -> Null
    JsonNumber n -> ConstNumber n
    JsonText s -> case s of
        ('#':s') -> case s' of
            "Anything" -> Anything
            "Number" -> Number
            "Text" -> Text
            "Boolean" -> Boolean
        ('$':s') -> Ref s'
        _ -> ConstText (unescape s)
    JsonBoolean b -> ConstBoolean b
    JsonArray xs -> case xs of
        (JsonText "#Tuple" : xs') -> Tuple Strict (map fromJsonSpec xs')
        (JsonText "#Tuple*" : xs') -> Tuple Tolerant (map fromJsonSpec xs')
        (JsonText "#NamedTuple" : xs') -> case (head xs') of JsonObject ps -> NamedTuple Strict [(k, fromJsonSpec v) | (k, v) <- ps]
        (JsonText "#NamedTuple*" : xs') -> case (head xs') of JsonObject ps -> NamedTuple Tolerant [(k, fromJsonSpec v) | (k, v) <- ps]
        (JsonText "#Array" : xs') -> Array (fromJsonSpec (head xs'))
        (JsonText "#TextMap" : xs') -> TextMap (fromJsonSpec (head xs'))
        (JsonText "#Refined" : xs') -> Refined (fromJsonSpec (head xs')) undefined
        (JsonText "#Alternative" : xs') -> Alternative (fromJsonSpec (head xs')) (fromJsonSpec (head (tail xs'))) ()
        _ -> Tuple Strict (map fromJsonSpec xs)
    JsonObject ps -> NamedTuple Strict [(k, fromJsonSpec v) | (k, v) <- ps]
    where
        unescape s = case s of ('\\':s') -> s'; _ -> s

--------------------- trivial things about TyRep --------------------

-- | the name of a user defined Spec
type Name = String

-- | the environment which contains information a
type Env a = M.Map Name a

-- | a decidable proposition about JsonData
data DecProp = DecProp {testProp :: JsonData -> Bool}

-- | a choice maker helps to make choice on Alternative node
type ChoiceMaker = JsonData -> MatchChoice

-- | a matching choice maked by choice maker
data MatchChoice = MatchLeft | MatchRight | MatchNothing deriving (Show, Eq, Ord)

-- | strictness label for Tuple & NamedTuple
data Strictness = Strict | Tolerant deriving (Show, Eq, Ord)


instance (ShowRef r, ShowAlternative c, Show tr') => Show (TyRep r p c tr') where
    show tr = case tr of
        Anything -> "Anything"
        Number -> "Number"
        Text -> "Text"
        Boolean -> "Boolean"
        Null -> "Null"
        ConstNumber n -> show n
        ConstText s -> show s
        ConstBoolean b -> show b
        Tuple Strict ts -> "(" ++ intercalate ", " (map show ts) ++ ")"
        Tuple Tolerant ts -> "(" ++ intercalate ", " (map show ts ++ ["*"]) ++ ")"
        Array t -> "Array<" ++ show t ++ ">"
        NamedTuple Strict ps -> "{" ++ intercalate ", " [showIdentifier k ++ ": " ++ show t | (k, t) <- ps] ++ "}"
        NamedTuple Tolerant ps -> "{" ++ intercalate ", " ([showIdentifier k ++ ": " ++ show t | (k, t) <- ps] ++ ["*"]) ++ "}"
        TextMap t -> "Map<" ++ show t ++ ">"
        Ref name -> showRef name
        Refined t _ -> "Refined<" ++ show t ++ ">"
        Alternative a b c -> "(" ++ show a ++ bar ++ show b ++ ")" where
            bar = " " ++ showAlternative c ++ " "

instance {-# Overlapping #-} (ShowRef r, ShowAlternative c) => Show (Fix (TyRep r p c)) where
    show (Fix tr) = show tr

class ShowRef a where
    showRef :: a -> String

instance ShowRef [Char] where
    showRef s = s

instance ShowRef () where
    showRef () = "$"

class ShowAlternative a where
    showAlternative :: a -> String

instance ShowAlternative ChoiceMaker where
    showAlternative _ = "|"

instance ShowAlternative () where
    showAlternative _ = "|?"

---------------------------------------------------------------------
---------------------------- MatchResult ----------------------------
---------------------------------------------------------------------

-- | matching result when we try to match a specific JsonData to a specific Spec
data MatchResult = Matched | UnMatched UnMatchedReason deriving (Show)

-- | a convenient infix constructor of MatchResult
otherwise :: Bool -> UnMatchedReason -> MatchResult
b `otherwise` reason = if b then Matched else UnMatched reason

-- | a convenient prefix constructor of MatchResult
wrap :: StepUMR -> MatchResult -> MatchResult
wrap step rst = case rst of Matched -> Matched; UnMatched reason -> UnMatched (StepCause step reason)

-- | Eq instance of MatchResult only compare the tag of the result
instance Eq MatchResult where
    a == b = case (a, b) of (Matched, Matched) -> True; (UnMatched _, UnMatched _) -> True; _ -> False

-- | mappend means if both components are Matched, then entireness is Matched
-- | mempty = Matched means when no component is considered, then we think it is Matched
instance Monoid MatchResult where
    mempty = Matched
    mappend = (<>)

instance Semigroup MatchResult where
    (<>) Matched Matched = Matched
    (<>) Matched r2 = r2
    (<>) r1 _ = r1

---------------- trivial things about MatchResult -------------------

-- | representation of the reason why they are not matched
data UnMatchedReason = DirectCause DirectUMR CSpec JsonData | StepCause StepUMR UnMatchedReason deriving (Show)

-- | direct unmatch reason, a part of UnMatchedReason
data DirectUMR =
      OutlineNotMatch
    | TupleLengthNotEqual
    | NamedTupleKeySetNotEqual
    | RefinedPropNotMatch --TODO: add prop description sentence
    | OrMatchNothing
    deriving (Show, Eq, Ord)

-- | step unmatch reason, a part of UnMatchedReason
data StepUMR =
      TupleFieldNotMatch Int
    | ArrayElementNotMatch Int
    | NamedTupleFieldNotMatch String
    | TextMapElementNotMatch String
    | RefinedShapeNotMatch
    | OrNotMatchLeft
    | OrNotMatchRight
    | RefNotMatch Name
    deriving (Show, Eq, Ord)

instance MultilingualShow MatchResult where
    showEnWith f mr = case mr of Matched -> "Matched"; (UnMatched r) -> "UnMatched !\n" ++ f r

instance MultilingualShow UnMatchedReason where
    showEnWith _ r =
        let (direct, sp, d, specPath, dataPath) = explain r
        in "  Abstract: it" ++ dataPath ++ " should be a " ++ show sp ++ ", but got " ++ show d ++
            "\n  Direct Cause: " ++ show direct ++
            "\n    Spec: " ++ show sp ++
            "\n    Data: " ++ show d ++
            "\n  Spec Path: " ++ specPath ++
            "\n  Data Path: " ++ dataPath
    showZhWith _ r =
        let (direct, sp, d, specPath, dataPath) = explain r
        in "  摘要: it" ++ dataPath ++ " 应该是一个 " ++ show sp ++ ", 但这里是 " ++ show d ++
            "\n  直接原因: " ++ show direct ++
            "\n    规格: " ++ show sp ++
            "\n    数据: " ++ show d ++
            "\n  规格路径: " ++ specPath ++
            "\n  数据路径: " ++ dataPath

explain :: UnMatchedReason -> (DirectUMR, CSpec, JsonData, String, String)
explain reason = iter reason undefined [] where
    iter reason dc path = case reason of
        DirectCause dr sp d -> (dr, sp, d, concatMap specAccessor path, concatMap dataAccessor path)
        StepCause sr r -> iter r dc (path ++ [sr])

    specAccessor r = case r of
        TupleFieldNotMatch i -> "(" ++ show i ++ ")"
        ArrayElementNotMatch i -> "[" ++ show i ++ "]"
        NamedTupleFieldNotMatch k -> "(" ++ show k ++ ")"
        TextMapElementNotMatch k -> "[" ++ show k ++ "]"
        RefinedShapeNotMatch -> "<refined>"
        OrNotMatchLeft -> "<left>"
        OrNotMatchRight -> "<right>"
        RefNotMatch name -> "{" ++ name ++ "}"

    dataAccessor r = case r of
        TupleFieldNotMatch i -> "[" ++ show i ++ "]"
        ArrayElementNotMatch i -> "[" ++ show i ++ "]"
        NamedTupleFieldNotMatch k -> (if isIdentifier k then "." ++ k else "[" ++ show k ++ "]")
        TextMapElementNotMatch k -> "[" ++ show k ++ "]"
        _ -> ""

