module Simplify exposing
    ( Simplifier, simplify
    , simplest, bool, int, float, string, order, atLeastInt, atLeastFloat, char, atLeastChar, character
    , maybe, result, list, array, pair, triple
    , keepIf, dropIf, merge
    , fromFunction, convert
    )

{-| This library contains a collection of basic simplifiers, and helper functions to
make your own.

Simplifying is part of fuzzing, and the provided fuzzers have simplifiers already
built into them. You only have to write your own simplifiers if you use `Fuzz.custom`.

The simplifier's job is to take a randomly-generated input that caused a fuzz test to
fail and find a simpler input that also fails, to better illustrate the bug.


## Quick Reference

  - [Simplifying Basics](#simplifying-basics)
  - [Readymade Simplifiers](#readymade-simplifiers)
  - [Simplifiers of data structures](#simplifiers-of-data-structures)
  - [Functions on Simplifiers](#functions-on-simplifiers)
  - [What are Simplifiers and why do we need them?](#what-are-simplifiers-and-why-do-we-need-them)


## Simplifying Basics

@docs Simplifier, simplify


## Readymade Simplifiers

@docs simplest, bool, int, float, string, order, atLeastInt, atLeastFloat, char, atLeastChar, character


## Simplifiers of data structures

@docs maybe, result, list, array, pair, triple


## Functions on Simplifiers

@docs keepIf, dropIf, merge


## What are Simplifiers and why do we need them?

Fuzzers consist of two parts: a Generator and a Simplifier.

The Generator takes a random Seed as input and returns a random value of
the desired type, based on the Seed. When a test fails on one of those random
values, the simplifier takes the failing value and makes it simpler for
you so you can more easily guess what property of that value caused the test
to fail.

Simplifying is a way to try and find the simplest example that
fails, in order to give the tester better feedback on what went wrong.

Simplifiers are functions that, given a failing value, offer simpler
values to test against. What qualifies as simple is kind of arbitrary,
and depends on what type of values you're fuzzing.


### Simplification in Action

Let us say I'm writing a Fuzzer for binary trees:

    type Tree a
        = Node (Tree a) (Tree a)
        | Leaf a

Now a random Generator produces the following tree and this makes the
test fail:

    Node
        (Node
            (Node
                (Node
                    (Leaf 888)
                    (Leaf 9090)
                )
                (Node
                    (Leaf -1)
                    (Node
                        (Leaf 731)
                        (Node
                            (Leaf 9621)
                            (Leaf -12)
                        )
                    )
                )
            )
            (Node
                (Leaf -350)
                (Leaf 124)
            )
        )
        (Node
            (Leaf 45)
            (Node
                (Leaf 123)
                (Node
                    (Leaf 999111)
                    (Leaf -148148)
                )
            )
        )

This is a pretty big tree, with many nodes and leaves, and it is difficult
to tell which part is responsible for failing the test. If we don't attempt
to simplify it, the developer will have a hard time fixing their code so the
test can pass.

A simplifier can convert that overgrown tree into a tiny sprout:

    Leaf -1

Nice, it looks like a negative number in a `Leaf` could be the issue.


### How does simplifying work?

A simplifier takes a value and returns a short list of simpler values.

Once elm-test finds a failing fuzz test, it tries to simplify the input using
the simplifier. If one of the simpler values generated by the simplifier also
cause tests to fail, we continue simplifying from there instead.
Once the simplifier cannot produce any simpler values, or none of the simpler values
fail the fuzz test, we stop simplifying.


### How do I make my own Simplifiers?

Simplifiers are deterministic, since they do not have access to a random number
generator. It's the generator part of the fuzzer that's meant to find the rare
edge cases; it's the simplifier's job to make the failures as understandable as
possible.

Simplifiers must never simplify values in a circle, like this:

    badBooleanSimplifier bool = [not bool]

    badBooleanSimplifier True --> [ False ]
    badBooleanSimplifier False --> [ True ]

`False` is simpler that `True`, which is in turn simpler than `False`. Doing this
will result in tests looping indefinitely, testing and re-testing the same values
in a circle.

With those caveats, here's how you actually do it:

@docs fromFunction, convert

-}

import Array exposing (Array)
import Char
import Lazy exposing (Lazy, force, lazy)
import Lazy.List exposing (LazyList, append, cons, empty)
import List
import Simplify.Internal exposing (Simplifier(..))
import String


{-| The simplifier type is opaque.
-}
type alias Simplifier a =
    Simplify.Internal.Simplifier a


{-| Perform simplifying. Takes a predicate that returns `True` if you want
simplifying to continue (most likely the failing test for which we are attempting
to simplify the value). Also takes the simplifier and the value to simplify.

It returns the simplified value, or the input value if no simplified values that
satisfy the predicate are found.

-}
simplify : (a -> Bool) -> Simplifier a -> a -> a
simplify keepSimplifying (Simp simplifier) originalVal =
    let
        helper lazyList val =
            case force lazyList of
                Lazy.List.Nil ->
                    val

                Lazy.List.Cons head tail ->
                    if keepSimplifying head then
                        helper (simplifier head) head

                    else
                        helper tail val
    in
    helper (simplifier originalVal) originalVal


{-| A simplifier that performs no simplifying. Whatever value it's given,
it claims that it's the simplest. This allows you to opt-out of simplification.
-}
simplest : Simplifier a
simplest =
    Simp <|
        \_ ->
            empty


{-| Simplifier of bools.
-}
bool : Simplifier Bool
bool =
    Simp <|
        \b ->
            case b of
                True ->
                    cons False empty

                False ->
                    empty


{-| Simplifier of `Order` values.
-}
order : Simplifier Order
order =
    Simp <|
        \o ->
            case o of
                GT ->
                    cons EQ (cons LT empty)

                LT ->
                    cons EQ empty

                EQ ->
                    empty


{-| Simplifier of integers.
-}
int : Simplifier Int
int =
    Simp <|
        \n ->
            if n < 0 then
                cons -n (Lazy.List.map ((*) -1) (seriesInt 0 -n))

            else
                seriesInt 0 n


{-| Construct a simplifier of ints which considers the given int to
be most minimal.
-}
atLeastInt : Int -> Simplifier Int
atLeastInt min =
    Simp <|
        \n ->
            if n < 0 && n >= min then
                cons -n (Lazy.List.map ((*) -1) (seriesInt 0 -n))

            else
                seriesInt (max 0 min) n


{-| Simplifier of floats.
-}
float : Simplifier Float
float =
    Simp <|
        \n ->
            if n < 0 then
                cons -n (Lazy.List.map ((*) -1) (seriesFloat 0 -n))

            else
                seriesFloat 0 n


{-| Construct a simplifier of floats which considers the given float to
be most minimal.
-}
atLeastFloat : Float -> Simplifier Float
atLeastFloat min =
    Simp <|
        \n ->
            if n < 0 && n >= min then
                cons -n (Lazy.List.map ((*) -1) (seriesFloat 0 -n))

            else
                seriesFloat (max 0 min) n


{-| Simplifier of chars.
-}
char : Simplifier Char
char =
    convert Char.fromCode Char.toCode int


{-| Construct a simplifier of chars which considers the given char to
be most minimal.
-}
atLeastChar : Char -> Simplifier Char
atLeastChar ch =
    convert Char.fromCode Char.toCode (atLeastInt (Char.toCode ch))


{-| Simplifier of chars which considers the empty space as the most
minimal char and omits the control key codes.

Equivalent to:

    atLeastChar (Char.fromCode 32)

-}
character : Simplifier Char
character =
    atLeastChar (Char.fromCode 32)


{-| Simplifier of strings. Considers the empty string to be the most
minimal string and the space to be the most minimal char.

Equivalent to:

    convert String.fromList String.toList (list character)

-}
string : Simplifier String
string =
    convert String.fromList String.toList (list character)


{-| Maybe simplifier constructor.
Takes a simplifier of values and returns a simplifier of Maybes.
-}
maybe : Simplifier a -> Simplifier (Maybe a)
maybe (Simp simplifier) =
    Simp <|
        \m ->
            case m of
                Just a ->
                    cons Nothing (Lazy.List.map Just (simplifier a))

                Nothing ->
                    empty


{-| Result simplifier constructor. Takes a simplifier of errors and a simplifier of
values and returns a simplifier of Results.
-}
result : Simplifier error -> Simplifier value -> Simplifier (Result error value)
result (Simp simplifyError) (Simp simplifyValue) =
    Simp <|
        \r ->
            case r of
                Ok value ->
                    Lazy.List.map Ok (simplifyValue value)

                Err error ->
                    Lazy.List.map Err (simplifyError error)



{- Lazy List simplifier constructor. Takes a simplifier of values and returns a
   simplifier of Lazy Lists. The lazy list being simplified must be finite. (I mean
   really, how do you make an infinite list simpler?)

   This function is no longer exposed, but is used to implement the list and array simplifiers.
-}


lazylist : Simplifier a -> Simplifier (LazyList a)
lazylist (Simp simplifier) =
    Simp <|
        \l ->
            lazy <|
                \() ->
                    let
                        n : Int
                        n =
                            Lazy.List.length l

                        simplifyOneHelp : LazyList a -> LazyList (LazyList a)
                        simplifyOneHelp lst =
                            lazy <|
                                \() ->
                                    case force lst of
                                        Lazy.List.Nil ->
                                            force empty

                                        Lazy.List.Cons x xs ->
                                            force
                                                (append (Lazy.List.map (\val -> cons val xs) (simplifier x))
                                                    (Lazy.List.map (cons x) (simplifyOneHelp xs))
                                                )

                        removes : Int -> Int -> LazyList a -> LazyList (LazyList a)
                        removes k_ n_ l_ =
                            lazy <|
                                \() ->
                                    if k_ > n_ then
                                        force empty

                                    else if Lazy.List.isEmpty l_ then
                                        force (cons empty empty)

                                    else
                                        let
                                            first =
                                                Lazy.List.take k_ l_

                                            rest =
                                                Lazy.List.drop k_ l_
                                        in
                                        force <|
                                            cons rest (Lazy.List.map (append first) (removes k_ (n_ - k_) rest))
                    in
                    force <|
                        append
                            (Lazy.List.andThen (\k -> removes k n l)
                                (Lazy.List.takeWhile (\x -> x > 0) (Lazy.List.iterate (\num -> num // 2) n))
                            )
                            (simplifyOneHelp l)


{-| List simplifier constructor.
Takes a simplifier of values and returns a simplifier of Lists.
-}
list : Simplifier a -> Simplifier (List a)
list simplifier =
    convert Lazy.List.toList Lazy.List.fromList (lazylist simplifier)


{-| Array simplifier constructor.
Takes a simplifier of values and returns a simplifier of Arrays.
-}
array : Simplifier a -> Simplifier (Array a)
array simplifier =
    convert Lazy.List.toArray Lazy.List.fromArray (lazylist simplifier)


{-| Pair simplifier constructor.
Takes a pair of simplifiers and returns a simplifier of pairs.
-}
pair : ( Simplifier a, Simplifier b ) -> Simplifier ( a, b )
pair ( Simp simplifyA, Simp simplifyB ) =
    Simp <|
        \( a, b ) ->
            append (Lazy.List.map (Tuple.pair a) (simplifyB b))
                (append (Lazy.List.map (\first -> ( first, b )) (simplifyA a))
                    (Lazy.List.map2 Tuple.pair (simplifyA a) (simplifyB b))
                )


{-| Triple simplifier constructor.
Takes a triple of simplifiers and returns a simplifier of triples.
-}
triple : ( Simplifier a, Simplifier b, Simplifier c ) -> Simplifier ( a, b, c )
triple ( Simp simplifyA, Simp simplifyB, Simp simplifyC ) =
    Simp <|
        \( a, b, c ) ->
            append (Lazy.List.map (\c1 -> ( a, b, c1 )) (simplifyC c))
                (append (Lazy.List.map (\b2 -> ( a, b2, c )) (simplifyB b))
                    (append (Lazy.List.map (\a2 -> ( a2, b, c )) (simplifyA a))
                        (append (Lazy.List.map2 (\b2 c2 -> ( a, b2, c2 )) (simplifyB b) (simplifyC c))
                            (append (Lazy.List.map2 (\a2 c2 -> ( a2, b, c2 )) (simplifyA a) (simplifyC c))
                                (append (Lazy.List.map2 (\a2 b2 -> ( a2, b2, c )) (simplifyA a) (simplifyB b))
                                    (Lazy.List.map3 (\a2 b2 c2 -> ( a2, b2, c2 )) (simplifyA a) (simplifyB b) (simplifyC c))
                                )
                            )
                        )
                    )
                )



----------------------
-- HELPER FUNCTIONS --
----------------------


{-| Create a simplifier by specifiying how to simplify any value.
-}
fromFunction : (a -> List a) -> Simplifier a
fromFunction f =
    Simp (f >> Lazy.List.fromList)


{-| Convert a Simplifier of a's into a Simplifier of b's using two inverse functions.
This allows you to reuse the simplifcation logic of one type for another. This library
uses it to simplify arrays by simplifying lists.

This function works by converting the `b` to simplify into an `a`, getting simpler
`a` values, and then turning them all into `b` values again.

If you use this function as follows:

    simplifierB =
        convert f g simplifierA

Make sure that:

    f (g x) == x -- for all x

Putting something into `g` then feeding the output into `f` must give back that
original something. Otherwise this process will generate garbage.

-}
convert : (a -> b) -> (b -> a) -> Simplifier a -> Simplifier b
convert f g (Simp simplifier) =
    Simp <|
        \b ->
            Lazy.List.map f (simplifier (g b))


{-| Filter out the results of a simplifier. The resulting simplifier
will only produce simplifiers which satisfy the given predicate.
-}
keepIf : (a -> Bool) -> Simplifier a -> Simplifier a
keepIf predicate (Simp simplifier) =
    Simp <|
        \a ->
            Lazy.List.keepIf predicate (simplifier a)


{-| Filter out the results of a simplifier. The resulting simplifier
will only throw away simplifiers which satisfy the given predicate.
-}
dropIf : (a -> Bool) -> Simplifier a -> Simplifier a
dropIf predicate =
    keepIf (not << predicate)


{-| Merge two simplifiers. Generates all the values in the first
simplifier, and then all the non-duplicated values in the second
simplifier.
-}
merge : Simplifier a -> Simplifier a -> Simplifier a
merge (Simp simplify1) (Simp simplify2) =
    Simp <|
        \a ->
            Lazy.List.unique (append (simplify1 a) (simplify2 a))



-----------------------
-- PRIVATE FUNCTIONS --
-----------------------


seriesInt : Int -> Int -> LazyList Int
seriesInt low high =
    if low >= high then
        empty

    else if low == high - 1 then
        cons low empty

    else
        let
            low_ =
                low + ((high - low) // 2)
        in
        cons low (seriesInt low_ high)


seriesFloat : Float -> Float -> LazyList Float
seriesFloat low high =
    if low >= high - 0.0001 then
        if high /= 0.000001 then
            Lazy.List.singleton (low + 0.000001)

        else
            empty

    else
        let
            low_ =
                low + ((high - low) / 2)
        in
        cons low (seriesFloat low_ high)
