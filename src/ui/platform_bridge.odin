package ui

import platform_tabs "../platform/tabs"
import platform_dialogs "../platform/dialogs"
import platform_chrome "../platform/chrome"

// Re-export / alias types from platform_tabs
Tab_Hit_Target :: platform_tabs.Tab_Hit_Target
Tab_Bar_Anim :: platform_tabs.Tab_Bar_Anim
Tab_Bar_State :: platform_tabs.Tab_Bar_State
Tab_Action :: platform_tabs.Tab_Action
Tab_Drag_Phase :: platform_tabs.Tab_Drag_Phase
Tab_Drag_Action :: platform_tabs.Tab_Drag_Action
Tab_Drag_State :: platform_tabs.Tab_Drag_State
Tab_Menu_Item :: platform_tabs.Tab_Menu_Item
Tab_Menu_Action :: platform_tabs.Tab_Menu_Action
Tab_Menu_State :: platform_tabs.Tab_Menu_State
Tab_Rename_Action :: platform_tabs.Tab_Rename_Action
Tab_Rename_State :: platform_tabs.Tab_Rename_State
Tab_Overflow_State :: platform_tabs.Tab_Overflow_State
Tab_Overflow_Action :: platform_tabs.Tab_Overflow_Action
Tab_Info :: platform_tabs.Tab_Info
UI_Tab_Info :: platform_tabs.UI_Tab_Info

TAB_MENU_ITEM_COUNT :: platform_tabs.TAB_MENU_ITEM_COUNT
TAB_OVERFLOW_WIDTH :: platform_tabs.TAB_OVERFLOW_WIDTH
TAB_OVERFLOW_ROW_HEIGHT :: platform_tabs.TAB_OVERFLOW_ROW_HEIGHT
TAB_GAP :: platform_tabs.TAB_GAP
TRAFFIC_LIGHT_OFFSET_DARWIN :: platform_tabs.TRAFFIC_LIGHT_OFFSET_DARWIN
NEW_TAB_BTN_WIDTH :: platform_tabs.NEW_TAB_BTN_WIDTH
CLOSE_BTN_WIDTH :: platform_tabs.CLOSE_BTN_WIDTH
TAB_CLOSE_MIN_WIDTH :: platform_tabs.TAB_CLOSE_MIN_WIDTH
TAB_SCROLL_WHEEL_STEP :: platform_tabs.TAB_SCROLL_WHEEL_STEP
TAB_TITLE_PAD_LEFT :: platform_tabs.TAB_TITLE_PAD_LEFT
TAB_BAR_MIN_DRAG_W :: platform_tabs.TAB_BAR_MIN_DRAG_W

// Re-export / alias types from platform_dialogs
Confirm_Dialog_Action :: platform_dialogs.Confirm_Dialog_Action
Confirm_Dialog_Target :: platform_dialogs.Confirm_Dialog_Target
Confirm_Dialog_State :: platform_dialogs.Confirm_Dialog_State

CONFIRM_DIALOG_WIDTH :: platform_dialogs.CONFIRM_DIALOG_WIDTH
CONFIRM_DIALOG_HEIGHT :: platform_dialogs.CONFIRM_DIALOG_HEIGHT
CONFIRM_BTN_CANCEL_W :: platform_dialogs.CONFIRM_BTN_CANCEL_W
CONFIRM_BTN_CONFIRM_W :: platform_dialogs.CONFIRM_BTN_CONFIRM_W
CONFIRM_BTN_HEIGHT :: platform_dialogs.CONFIRM_BTN_HEIGHT
CONFIRM_BTN_CANCEL_OFFSET_X :: platform_dialogs.CONFIRM_BTN_CANCEL_OFFSET_X
CONFIRM_BTN_CONFIRM_OFFSET_X :: platform_dialogs.CONFIRM_BTN_CONFIRM_OFFSET_X
CONFIRM_BTN_OFFSET_Y :: platform_dialogs.CONFIRM_BTN_OFFSET_Y

// Re-export / alias types from platform_chrome
Search_Hit_Target :: platform_chrome.Search_Hit_Target
Search_Action :: platform_chrome.Search_Action
Search_Bar_State :: platform_chrome.Search_Bar_State

SEARCH_BAR_MARGIN_RIGHT :: platform_chrome.SEARCH_BAR_MARGIN_RIGHT
SEARCH_BAR_MARGIN_TOP :: platform_chrome.SEARCH_BAR_MARGIN_TOP
BTN_CTRL_WIDTH :: platform_chrome.BTN_CTRL_WIDTH

// Forward procedures to platform_tabs
tab_bar_init :: platform_tabs.tabs_init
tab_bar_anim_activate :: platform_tabs.tab_bar_anim_activate
tab_bar_anim_update :: platform_tabs.tabs_anim_update
tab_bar_layout :: platform_tabs.tabs_layout
tab_bar_scroll :: platform_tabs.tabs_scroll
tab_bar_scroll_to_tab :: platform_tabs.tab_bar_scroll_to_tab
tab_bar_hit_test :: platform_tabs.tab_bar_hit_test
tab_bar_dispatch_pointer :: platform_tabs.tabs_dispatch_pointer

tab_drag_reset :: platform_tabs.tab_drag_reset
tab_drag_begin :: platform_tabs.tab_drag_begin
tab_bar_drop_gap :: platform_tabs.tab_bar_drop_gap
tab_bar_gap_x :: platform_tabs.tab_bar_gap_x
tab_drag_dispatch_pointer :: platform_tabs.tab_drag_dispatch_pointer

tab_menu_init :: platform_tabs.tab_menu_init
tab_menu_refresh :: platform_tabs.tab_menu_refresh
tab_menu_layout :: platform_tabs.tab_menu_layout
tab_menu_open :: platform_tabs.tab_menu_open
tab_menu_close :: platform_tabs.tab_menu_close
tab_menu_dispatch_pointer :: platform_tabs.tab_menu_dispatch_pointer
tab_menu_dispatch_key :: platform_tabs.tab_menu_dispatch_key
tab_menu_item_label :: platform_tabs.tab_menu_item_label
tab_menu_item_shortcut :: platform_tabs.tab_menu_item_shortcut

tab_rename_init :: platform_tabs.tab_rename_init
tab_rename_begin :: platform_tabs.tab_rename_begin
tab_rename_cancel :: platform_tabs.tab_rename_cancel
tab_rename_text :: platform_tabs.tab_rename_text
tab_rename_dispatch_key :: platform_tabs.tab_rename_dispatch_key
tab_rename_dispatch_pointer :: platform_tabs.tab_rename_dispatch_pointer

tab_overflow_close :: platform_tabs.tab_overflow_close
tab_overflow_selected_index :: platform_tabs.tab_overflow_selected_index
tab_overflow_refresh :: platform_tabs.tab_overflow_refresh
tab_overflow_row_rect :: platform_tabs.tab_overflow_row_rect
tab_overflow_dispatch_key :: platform_tabs.tab_overflow_dispatch_key
tab_overflow_dispatch_pointer :: platform_tabs.tab_overflow_dispatch_pointer

// Forward procedures to platform_dialogs
confirm_dialog_init :: platform_dialogs.confirm_dialog_init
confirm_dialog_show :: platform_dialogs.confirm_dialog_show
confirm_dialog_hide :: platform_dialogs.confirm_dialog_hide
confirm_dialog_layout :: platform_dialogs.confirm_dialog_layout
confirm_dialog_dispatch_pointer :: platform_dialogs.confirm_dialog_dispatch_pointer
confirm_dialog_dispatch_key :: platform_dialogs.confirm_dialog_dispatch_key

// Forward procedures to platform_chrome
search_bar_init :: platform_chrome.search_bar_init
search_bar_layout :: platform_chrome.search_bar_layout
search_bar_dispatch_key :: platform_chrome.search_bar_dispatch_key
search_bar_dispatch_pointer :: platform_chrome.search_bar_dispatch_pointer
search_bar_execute_scan :: platform_chrome.search_bar_execute_scan
