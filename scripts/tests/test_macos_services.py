#!/usr/bin/env python3
"""Static checks for Term's bundled macOS Services declarations and wiring."""

import plistlib
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class MacOSServiceTests(unittest.TestCase):
    def test_info_plist_declares_both_native_services(self):
        info = plistlib.loads((REPO / "assets/Info.plist").read_bytes())
        services = {service["NSMessage"]: service for service in info["NSServices"]}
        self.assertEqual(set(services), {"openTermHere", "restoreTermWorkspace"})
        self.assertEqual(services["openTermHere"]["NSSendTypes"], ["NSFilenamesPboardType", "public.plain-text"])
        self.assertEqual(
            services["openTermHere"]["NSRequiredContext"], {"NSTextContent": "FilePath"}
        )
        self.assertEqual(services["openTermHere"]["NSSendFileTypes"], ["public.folder"])
        self.assertEqual(
            services["openTermHere"]["NSMenuItem"]["default"],
            "Open Term Here (Default Workspace)",
        )
        self.assertEqual(
            services["restoreTermWorkspace"]["NSSendTypes"],
            ["NSFilenamesPboardType", "public.plain-text"],
        )
        self.assertEqual(
            services["restoreTermWorkspace"]["NSRequiredContext"],
            {"NSTextContent": "FilePath"},
        )
        self.assertEqual(services["restoreTermWorkspace"]["NSSendFileTypes"], ["public.item"])
        self.assertEqual(
            services["restoreTermWorkspace"]["NSMenuItem"]["default"],
            "Restore Term Workspace",
        )

    def test_app_build_compiles_and_links_objc_bridge(self):
        makefile = (REPO / "Makefile").read_text()
        self.assertIn("clang -fobjc-arc -mmacosx-version-min=$(MIN_OS_VERSION) -c $<", makefile)
        self.assertIn('$(OUT_DIR)/macos_services.o', makefile)
        self.assertIn("build: version-info $(OUT_DIR)/macos_services.o", makefile)
        self.assertIn("release: version-info $(OUT_DIR)/macos_services.o", makefile)
        self.assertIn("test-app: version-info $(OUT_DIR)/macos_services.o", makefile)
        main = (REPO / "src/app/main.odin").read_text()
        self.assertIn("term_macos_services_init :: proc() -> bool", main)
        self.assertIn('"$(LINK_FLAGS) $(OUT_DIR)/macos_services.o"', makefile)

    def test_dmg_contains_only_app_and_applications_alias(self):
        makefile = (REPO / "Makefile").read_text()
        dmg_recipe = makefile.split("dmg: bundle", 1)[1].split("\nrun:", 1)[0]
        self.assertIn("cp -R $(OUT_DIR)/Term.app $(OUT_DIR)/dmg_staging/", dmg_recipe)
        self.assertIn("ln -s /Applications $(OUT_DIR)/dmg_staging/Applications", dmg_recipe)
        self.assertNotIn("workflow", dmg_recipe.lower())
        self.assertNotIn("installer", dmg_recipe.lower())

    def test_bridge_owns_requests_and_filters_single_supported_selection(self):
        bridge = (REPO / "src/app/macos_services.m").read_text()
        self.assertIn("NSApplication sharedApplication].servicesProvider", bridge)
        self.assertIn("objects.count != 1", bridge)
        self.assertIn("TermSupportedWorkspaceURL", bridge)
        self.assertIn("[path copy]", bridge)
        self.assertIn("SDL_PushEvent(&event)", bridge)
        main = (REPO / "src/app/main.odin").read_text()
        self.assertIn("persistence_load_default_for_folder(request_path)", main)
        self.assertIn("persistence_load_layout_file(request_path)", main)
        self.assertIn("persistence_restore_tab(a, layout, context_dir)", main)


if __name__ == "__main__":
    unittest.main()
