-- Copyright 2016 Google Inc. All Rights Reserved.
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
-- | Datatypes for reflection of protocol buffer messages.
module Data.ProtoLens.Message (
    -- * Reflection of Messages
    Message(..),
    Tag(..),
    MessageDescriptor(..),
    FieldDescriptor(..),
    fieldDescriptorName,
    isRequired,
    FieldAccessor(..),
    WireDefault(..),
    Packing(..),
    FieldTypeDescriptor(..),
    FieldDefault(..),
    MessageEnum(..),
    -- * Building protocol buffers
    Default(..),
    build,
    -- * Internal utilities for parsing protocol buffers
    reverseRepeatedFields,
    ) where

import qualified Data.ByteString as B
import Data.Default.Class
import Data.Int
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Text as T
import Data.Word
import Lens.Family2 (Lens', over)
import qualified Data.Vector as V

-- | Every protocol buffer is an instance of 'Message'.  This class enables
-- serialization by providing reflection of all of the fields that may be used
-- by this type.
class Default msg => Message msg where
    descriptor :: MessageDescriptor msg

-- | The description of a particular protocol buffer message type.
data MessageDescriptor msg = MessageDescriptor
    { fieldsByTag :: Map Tag (FieldDescriptor msg)
    , fieldsByTextFormatName :: Map String (FieldDescriptor msg)
      -- ^ This map is keyed by the name of the field used for text format protos.
      -- This is just the field name for every field except for group fields,
      -- which use their Message type name in text protos instead of their
      -- field name. For example, "optional group Foo" has the field name "foo"
      -- but in this map it is stored with the key "Foo".
    }

-- | A tag that identifies a particular field of the message when converting
-- to/from the wire format.
newtype Tag = Tag { unTag :: Int}
    deriving (Show, Eq, Ord, Num)


-- | A description of a specific field of a protocol buffer.
--
-- The 'String' parameter is the original name of the field in the .proto file.
-- (Haddock doesn't support per-argument docs for GADTs.)
data FieldDescriptor msg where
    FieldDescriptor :: String
                    -> FieldTypeDescriptor value -> FieldAccessor msg value
                    -> FieldDescriptor msg

-- | The original name of the field in the .proto file.
fieldDescriptorName :: FieldDescriptor msg -> String
fieldDescriptorName (FieldDescriptor name _ _) = name

-- | Whether the given field is required.  Specifically, if its 'FieldAccessor'
-- is a 'Required' 'PlainField'.
isRequired :: FieldDescriptor msg -> Bool
isRequired (FieldDescriptor _ _ (PlainField Required _)) = True
isRequired _ = False

-- | A Lens for accessing the value of an individual field in a protocol buffer
-- message.
data FieldAccessor msg value where
    -- A field which is stored in the proto as just a value.  Used for
    -- required fields and proto3 optional scalar fields.
    PlainField :: WireDefault value -> Lens' msg value
                     -> FieldAccessor msg value
    -- An optional field where the "unset" and "default" values are
    -- distinguishable.  In particular: proto2 optional fields, proto3
    -- messages, and "oneof" fields.
    OptionalField :: Lens' msg (Maybe value) -> FieldAccessor msg value
    RepeatedField :: Packing -> Lens' msg [value] -> FieldAccessor msg value
    RepeatedField' :: Packing -> Lens' msg (V.Vector value) -> FieldAccessor msg value
    -- A proto "map" field is serialized as a repeated field of an
    -- autogenerated "entry" type, where each entry contains a single key/value
    -- pair.  This constructor provides lenses for accessing the key and value
    -- of each entry, so that we can covert between a list of entries and a Map.
    MapField :: (Ord key, Message entry) => Lens' entry key -> Lens' entry value
                      -> Lens' msg (Map key value) -> FieldAccessor msg entry

-- | The default value (if any) for a 'PlainField' on the wire.
data WireDefault value where
    -- Required fields have no default.
    Required :: WireDefault value
    -- Corresponds to proto3 scalar fields.
    Optional :: (FieldDefault value, Eq value) => WireDefault value

-- | A proto3 field type with an implicit default value.
--
-- This is distinct from 'Data.Default' to avoid orphan instances, and because
-- 'Bool' doesn't necessarily have a good Default instance for general usage.
class FieldDefault value where
    fieldDefault :: value

instance FieldDefault Bool where
    fieldDefault = False

instance FieldDefault Int32 where
    fieldDefault = 0

instance FieldDefault Int64 where
    fieldDefault = 0

instance FieldDefault Word32 where
    fieldDefault = 0

instance FieldDefault Word64 where
    fieldDefault = 0

instance FieldDefault Float where
    fieldDefault = 0

instance FieldDefault Double where
    fieldDefault = 0

instance FieldDefault B.ByteString where
    fieldDefault = B.empty

instance FieldDefault T.Text where
    fieldDefault = T.empty


-- | How a given repeated field is transmitted on the wire format.
data Packing = Packed | Unpacked

-- | A description of the type of a given field value.
data FieldTypeDescriptor value where
    MessageField :: Message value => FieldTypeDescriptor value
    GroupField :: Message value => FieldTypeDescriptor value
    EnumField :: MessageEnum value => FieldTypeDescriptor value
    Int32Field :: FieldTypeDescriptor Int32
    Int64Field :: FieldTypeDescriptor Int64
    UInt32Field :: FieldTypeDescriptor Word32
    UInt64Field :: FieldTypeDescriptor Word64
    SInt32Field :: FieldTypeDescriptor Int32
    SInt64Field :: FieldTypeDescriptor Int64
    Fixed32Field :: FieldTypeDescriptor Word32
    Fixed64Field :: FieldTypeDescriptor Word64
    SFixed32Field :: FieldTypeDescriptor Int32
    SFixed64Field :: FieldTypeDescriptor Int64
    FloatField :: FieldTypeDescriptor Float
    DoubleField :: FieldTypeDescriptor Double
    BoolField :: FieldTypeDescriptor Bool
    StringField :: FieldTypeDescriptor T.Text
    BytesField :: FieldTypeDescriptor B.ByteString

deriving instance Show (FieldTypeDescriptor value)

-- | A class for protocol buffer enums that enables safe decoding.
class (Enum a, Bounded a) => MessageEnum a where
    -- | Convert the given 'Int' to an enum value.  Returns 'Nothing' if
    -- no corresponding value was defined in the .proto file.
    maybeToEnum :: Int -> Maybe a
    -- | Get the name of this enum as defined in the .proto file.
    showEnum :: a -> String
    -- | Convert the given 'String' to an enum value. Returns 'Nothing' if
    -- no corresponding value was defined in the .proto file.
    readEnum :: String -> Maybe a

-- | Utility function for building a message from a default value.
-- For example:
--
-- > instance Default A where ...
-- > x, y :: Lens' A Int
-- > m :: A
-- > m = build ((x .~ 5) . (y .~ 7))
build :: Default a => (a -> a) -> a
build = ($ def)

-- | Reverse every repeated (list) field in the message.
--
-- During parsing, we store fields temporarily in reverse order,
-- and then un-reverse them at the end.  This helps avoid the quadratic blowup
-- from repeatedly appending to lists.
-- TODO: Benchmark how much of a problem this is in practice,
-- and whether it's still a net win for small protobufs.
-- If we decide on it more permanently, consider moving it to a more internal
-- module.
reverseRepeatedFields :: Map k (FieldDescriptor msg) -> msg -> msg
reverseRepeatedFields fields x0
    -- TODO: if it becomes a bottleneck, consider forcing
    -- the full spine of each list.
    = Map.foldl' reverseListField x0 fields
  where
    reverseListField :: a -> FieldDescriptor a -> a
    reverseListField x (FieldDescriptor _ _ (RepeatedField _ f))
        = over f reverse x
    reverseListField x (FieldDescriptor _ _ (RepeatedField' _ f))
        = over f (V.fromList . reverse . V.toList) x
    reverseListField x _ = x
