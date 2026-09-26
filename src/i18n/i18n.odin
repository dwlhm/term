package i18n

import "core:os"
import "core:strings"

// Locale enumerates the supported interface languages.
Locale :: enum u8 {
	en,
	id,
}

// Strings holds localized labels for chrome surfaces, menus, and dialogs.
Strings :: struct {
	tab_untitled:        string,
	menu_close_tab:      string,
	menu_close_others:   string,
	menu_close_to_right: string,
	menu_new_tab:        string,
	menu_rename:         string,
	dialog_close_title:  string,
	dialog_close_body:   string,
	dialog_confirm:      string,
	dialog_cancel:       string,
	search_placeholder:  string,
}

@(private = "file")
current: ^Strings = &strings_en

// i18n_init selects the active locale, defaulting to English for unknown values.
i18n_init :: proc(locale: Locale) {
	i18n_set_locale(locale)
}

// i18n_set_locale switches the active string table.
i18n_set_locale :: proc(locale: Locale) {
	switch locale {
	case .id:
		current = &strings_id
	case .en:
		current = &strings_en
	case:
		current = &strings_en
	}
}

// i18n_get returns the active string table. It never returns nil.
i18n_get :: proc() -> ^Strings {
	if current == nil do return &strings_en
	return current
}

// i18n_locale_from_string parses an "en"/"id" locale tag case-insensitively.
// Unknown or empty tags fall back to English.
i18n_locale_from_string :: proc(s: string) -> Locale {
	trimmed := strings.trim_space(s)
	if len(trimmed) >= 2 {
		prefix := trimmed[:2]
		if strings.equal_fold(prefix, "id") {
			return .id
		}
		if strings.equal_fold(prefix, "en") {
			return .en
		}
	}
	return .en
}

// i18n_locale_from_env reads LC_ALL, LC_MESSAGES, then LANG and parses the
// two-letter prefix. Missing or unknown values fall back to English.
i18n_locale_from_env :: proc() -> Locale {
	for key in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if value, ok := os.lookup_env(key, context.temp_allocator); ok && len(value) >= 2 {
			return i18n_locale_from_string(value)
		}
	}
	return .en
}
