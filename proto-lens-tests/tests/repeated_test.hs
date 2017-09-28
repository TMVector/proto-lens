-- Copyright 2016 Google Inc. All Rights Reserved.
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
module Main where

import Proto.Repeated
import Test.Framework (testGroup)
import Data.ProtoLens
import Lens.Family2 ((&), (.~))
import Data.ByteString.Builder (byteString)
import Data.Monoid ((<>))
import qualified Data.Vector as V

import Data.ProtoLens.TestUtil

defFoo :: Foo
defFoo = def

defBar :: Bar
defBar = def

main :: IO ()
main = testMain
    [ serializeTo "default" defFoo mempty mempty
    , serializeTo "int32"
          (defFoo & a .~ V.fromList [1..3])
          (vcat $ map (keyedInt "a") [1..3])
          $ mconcat [tagged 1 $ VarInt x | x <- [1..3]]
    , serializeTo "string"
          (defFoo & b .~ V.fromList ["one", "two", "three"])
          (vcat $ map (keyedStr "b") ["one", "two", "three"])
          $ mconcat [ tagged 2 $ Lengthy $ byteString x
                    | x <- ["one", "two", "three"]
                    ]
    , serializeTo "nested/empty"
          (defFoo & c .~ V.fromList [def, def])
          (braced "c" mempty $+$ braced "c" mempty)
          $ tagged 3 (Lengthy mempty) <> tagged 3 (Lengthy mempty)
    , serializeTo "nested/fixed32"
          (defFoo & c .~ V.fromList [defBar & d .~ V.fromList [1..3]])
          (braced "c" $ vcat $ map (keyedInt "d") [1..3])
          $ tagged 3 $ Lengthy $ mconcat [tagged 3 $ Fixed32 x | x <- [1..3]]
    , serializeTo "nested/fixed64"
          (defFoo & c .~ V.fromList [defBar & e .~ V.fromList [1..3]])
          (braced "c" $ vcat $ map (keyedInt "e") [1..3])
          $ tagged 3 $ Lengthy $ mconcat [tagged 4 $ Fixed64 x | x <- [1..3]]
    , serializeTo "nested/repeated"
          (defFoo & c .~ V.fromList [defBar & d .~ V.fromList [1..3], defBar & e .~ V.fromList [1..3]])
          (braced "c" (vcat $ map (keyedInt "d") [1..3])
              $+$ braced "c" (vcat $ map (keyedInt "e") [1..3]))
          $ tagged 3 (Lengthy $ mconcat [tagged 3 $ Fixed32 x | x <- [1..3]])
          <> tagged 3 (Lengthy $ mconcat [tagged 4 $ Fixed64 x | x <- [1..3]])
    -- Test that if the same nested tag appears twice, we append the lists
    -- in the correct order.  (We fake this situation by appending the encoding
    -- of two different messages of the same type.)
    , deserializeFrom "nested/duplicateTag"
        (Just (defFoo & a .~ V.fromList [1,2,3,4] :: Foo))
        $ buildMessage (defFoo & a .~ V.fromList [1,2] :: Foo)
            <> buildMessage (defFoo & a .~ V.fromList [3,4] :: Foo)
    , testGroup "roundtrip"
        [ runTypedTest (roundTripTest "foo" :: TypedTest Foo)
        , runTypedTest (roundTripTest "bar" :: TypedTest Bar)
        ]
   ]
