//// Typed OpenTelemetry span and event attributes.

pub opaque type Key {
  Key(value: String)
}

pub type KeyError {
  EmptyKey
}

pub type Value {
  StringValue(String)
  BoolValue(Bool)
  IntValue(Int)
  FloatValue(Float)
  StringList(List(String))
  BoolList(List(Bool))
  IntList(List(Int))
  FloatList(List(Float))
}

pub type Attribute {
  Attribute(key: Key, value: Value)
}

pub fn key(value: String) -> Result(Key, KeyError) {
  case value {
    "" -> Error(EmptyKey)
    value -> Ok(Key(value))
  }
}

pub fn string(key: Key, value: String) -> Attribute {
  Attribute(key, StringValue(value))
}

pub fn bool(key: Key, value: Bool) -> Attribute {
  Attribute(key, BoolValue(value))
}

pub fn int(key: Key, value: Int) -> Attribute {
  Attribute(key, IntValue(value))
}

pub fn float(key: Key, value: Float) -> Attribute {
  Attribute(key, FloatValue(value))
}

pub fn strings(key: Key, value: List(String)) -> Attribute {
  Attribute(key, StringList(value))
}

pub fn bools(key: Key, value: List(Bool)) -> Attribute {
  Attribute(key, BoolList(value))
}

pub fn ints(key: Key, value: List(Int)) -> Attribute {
  Attribute(key, IntList(value))
}

pub fn floats(key: Key, value: List(Float)) -> Attribute {
  Attribute(key, FloatList(value))
}
