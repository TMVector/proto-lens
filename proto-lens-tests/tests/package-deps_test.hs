module Main where

import Data.ProtoLens.Vector (def)
import Lens.Family2 ((&), (.~), (^.))
import Test.Framework.Providers.HUnit (testCase)
import Test.HUnit ((@=?))

import Data.ProtoLens.Vector.TestUtil (Test, testMain)
import Proto.PackageDeps (Bar, foo)
import Proto.TestDep.Foo (value)

main :: IO ()
main = testMain [testWrapper]

testWrapper :: Test
testWrapper = testCase "testWrapper" $
    42 @=? (def & foo . value .~ 42 :: Bar) ^. foo . value
