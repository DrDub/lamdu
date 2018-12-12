module GUI.Momentu.FocusDirection
    ( FocusDirection(..), translate, scale
    ) where

import Data.Vector.Vector2 (Vector2(..))
import GUI.Momentu.Rect (R, Range, rangeStart)

import Lamdu.Prelude

-- RelativePos pos is relative to the top-left of the widget
data FocusDirection
    = Point (Vector2 R)
    | FromOutside
    | FromAbove (Range R) -- ^ horizontal virtual cursor
    | FromBelow (Range R) -- ^ horizontal virtual cursor
    | FromLeft  (Range R) -- ^ vertical virtual cursor
    | FromRight (Range R) -- ^ vertical virtual cursor

translate :: Vector2 R -> FocusDirection -> FocusDirection
translate _ FromOutside = FromOutside
translate pos (Point x) = x + pos & Point
translate pos (FromAbove r) = r & rangeStart +~ pos ^. _1 & FromAbove
translate pos (FromBelow r) = r & rangeStart +~ pos ^. _1 & FromBelow
translate pos (FromLeft  r) = r & rangeStart +~ pos ^. _2 & FromLeft
translate pos (FromRight r) = r & rangeStart +~ pos ^. _2 & FromRight

scale :: Vector2 R -> FocusDirection -> FocusDirection
scale _ FromOutside = FromOutside
scale ratio (Point x) = x * ratio & Point
scale ratio (FromAbove r) = r <&> (* ratio ^. _1) & FromAbove
scale ratio (FromBelow r) = r <&> (* ratio ^. _1) & FromBelow
scale ratio (FromLeft  r) = r <&> (* ratio ^. _2) & FromLeft
scale ratio (FromRight r) = r <&> (* ratio ^. _2) & FromRight
