package feature_automation

// Re-exports from features/screen_model so automation and callers keep their API.

import model "../screen_model"

Screen           :: model.Screen
Element          :: model.Element
Role             :: model.Role
Source           :: model.Source
Box              :: model.Box
Screen_Cell      :: model.Screen_Cell

screen_build     :: model.screen_build
screen_elements  :: model.screen_elements
screen_text      :: model.screen_text
screen_cell      :: model.screen_cell
element_ref      :: model.element_ref
element_describe :: model.element_describe
snapshot_load    :: model.snapshot_load
snapshot_parse   :: model.snapshot_parse
