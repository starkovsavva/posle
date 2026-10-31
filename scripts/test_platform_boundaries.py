import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_platform_boundaries as boundaries


class PlatformBoundaryTests(unittest.TestCase):
    def fixture_git(self, root):
        subprocess.run(["git", "init", "--template=", "-q", str(root)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(root), "config", "core.ignorecase", "true"], check=True)

    def violations(self, module, source, filename="Fixture.swift"):
        return boundaries.source_violations(Path("Sources") / module / filename, source)

    def manifest(self, native=True):
        targets = [
            {"name": "AfterCore", "dependencies": []},
            {"name": "AfterPlatform", "dependencies": [{"byName": ["AfterCore", None]}]},
            {"name": "AfterLocalization", "dependencies": []},
        ]
        if native:
            targets += [
                {"name": "AfterPlatformMacOS", "dependencies": [
                    {"target": ["AfterCore", None]}, {"byName": ["AfterPlatform", None]},
                    {"byName": ["AfterLocalization", None]}]},
                {"name": "AfterApp", "dependencies": [
                    {"byName": ["AfterPlatformMacOS", None]}, {"product": ["Sparkle", "Sparkle", None, None]}]},
            ]
        return {"targets": targets, "products": []}

    def test_portable_allowlists_and_scoped_imports(self):
        self.assertEqual(self.violations("AfterCore", "import Foundation\nimport struct Foundation.Date"), [])
        self.assertEqual(self.violations("AfterPlatform", "@preconcurrency import Foundation\nimport AfterCore"), [])
        self.assertEqual(self.violations("AfterLocalization", "import Foundation\nimport Observation"), [])
        self.assertIn("found AfterCore", self.violations("AfterLocalization", "import AfterCore")[0])
        self.assertIn("found SwiftUI", self.violations("AfterLocalization", "public import SwiftUI")[0])
        self.assertIn("found Combine", self.violations("AfterPlatform", "import Combine")[0])

    def test_inactive_conditionals_and_testable_do_not_hide_native_imports(self):
        source = """import Foundation
#if os(macOS)
@testable import AVFoundation
#elseif canImport(Security)
@_implementationOnly import Security
#endif
import struct EventKit.EKEvent
"""
        found = self.violations("AfterPlatform", source)
        self.assertEqual(len(found), 3)
        self.assertTrue(found[0].startswith("Sources/AfterPlatform/Fixture.swift:3:"))
        self.assertIn("found AVFoundation", found[0])
        self.assertIn("found Security", found[1])
        self.assertIn("found EventKit", found[2])

    def test_comments_strings_raw_and_multiline_strings_are_not_dependencies(self):
        source = '''// import AppKit
/* import Security /* import AVFoundation */ import Darwin */
let example = "import AppStore and AppStore"
let escaped = "a \\\"import Network\\\" string"
let raw = #"import EventKit and \\\" text"#
let block = ##"""
@testable import ScreenCaptureKit
AppStore
"""##
import Foundation
'''
        self.assertEqual(self.violations("AfterPlatform", source), [])

    def test_platform_adapters_cannot_import_or_reference_app_state(self):
        for source in ["import AfterApp", "@testable import AfterApp", "import AppStore", "var store: AppStore?", "func load(_ store: AfterApp.AppStore) {}"]:
            with self.subTest(source=source):
                self.assertTrue(self.violations("AfterPlatformMacOS", source))
        self.assertEqual(self.violations("AfterPlatformMacOS", "import Security\nimport AfterPlatform\nimport AfterLocalization"), [])

    def test_workflow_coordinators_use_ports_but_diagnostics_may_use_native_fakes(self):
        for coordinator in boundaries.COORDINATORS:
            with self.subTest(coordinator=coordinator):
                found = self.violations("AfterApp", "import IOKit.pwr_mgt; @testable import Network", coordinator + ".swift")
                self.assertEqual(len(found), 2)
                self.assertEqual(self.violations("AfterApp", "import AppKit\nimport SwiftUI\nimport AfterPlatformMacOS", coordinator + ".swift"), [])
        self.assertEqual(self.violations("AfterApp", "import AVFoundation\n@testable import AfterPlatformMacOS", "Diagnostics/CaptureWriterNativeChecks.swift"), [])

    def test_both_native_and_portable_package_graphs_are_accepted(self):
        self.assertEqual(boundaries.check_graph(self.manifest()), [])
        self.assertEqual(boundaries.check_graph(self.manifest(native=False)), [])

    def test_package_dependency_cannot_bypass_import_allowlist(self):
        package = self.manifest()
        package["targets"][0]["dependencies"] = [{"byName": ["AfterPlatformMacOS", None]}]
        found = boundaries.check_graph(package)
        self.assertTrue(any("AfterCore cannot depend on AfterPlatformMacOS" in line for line in found))
        self.assertTrue(any("dependency cycle" in line for line in found))

    def test_cycle_detection_covers_other_local_targets_and_local_products(self):
        package = self.manifest(native=False)
        package["targets"] += [
            {"name": "AdapterTest", "dependencies": [{"product": ["FixtureProduct", None, None, None]}]},
            {"name": "Fixture", "dependencies": [{"target": ["AdapterTest", None]}]},
        ]
        package["products"] = [{"name": "FixtureProduct", "targets": ["Fixture"]}]
        self.assertTrue(any("AdapterTest -> Fixture -> AdapterTest" in line for line in boundaries.check_graph(package)))

    def test_external_product_cannot_shadow_an_allowed_local_target(self):
        package = self.manifest()
        package["targets"][1]["dependencies"] = [{"product": ["AfterCore", "UnrelatedPackage", None, None]}]
        self.assertTrue(any("AfterPlatform cannot depend on external:AfterCore" in line for line in boundaries.check_graph(package)))

    def test_missing_targets_and_unknown_dependency_shapes_fail_closed(self):
        package = self.manifest(native=False)
        package["targets"].pop(0)
        package["targets"][0]["dependencies"] = [{"futureShape": "AfterCore"}]
        found = boundaries.check_graph(package)
        self.assertTrue(any("required portable target AfterCore" in line for line in found))
        self.assertTrue(any("unsupported dependency" in line for line in found))

    def test_manifest_command_does_not_resolve_or_fetch_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(boundaries.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps(self.manifest())
            boundaries.dump_package(Path(temporary))
            command = run.call_args.args[0]
            self.assertEqual(command[-1], "dump-package")
            self.assertNotIn("resolve", command)
            self.assertNotIn("build", command)
            self.assertNotIn("--disable-sandbox", command)
            boundaries.dump_package(Path(temporary), disable_sandbox=True)
            self.assertIn("--disable-sandbox", run.call_args.args[0])

    def test_ignored_swift_sources_include_app_and_tracked_native_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture_git(root)
            paths = ["Sources/AfterApp/Runtime/Has space.swift",
                     "Sources/AfterPlatformMacOS/Runtime/Worker.swift",
                     "Sources/FutureClient/Runtime/Native.swift"]
            for name in paths:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("import Foundation\n")
            # Even a tracked file must remain visible to the ignore regression
            # check. The next untracked sibling otherwise silently disappears.
            subprocess.run(["git", "-C", str(root), "add", paths[1]], check=True)
            (root / ".gitignore").write_text("runtime/\n")
            found = boundaries.check_ignored_swift_sources(root)
            self.assertEqual({line.split(":", 1)[0] for line in found}, set(paths))

    def test_repo_runtime_exception_keeps_swift_visible_and_runtime_data_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture_git(root)
            (root / ".gitignore").write_text((boundaries.ROOT / ".gitignore").read_text())
            swift = root / "Sources/AfterPlatformMacOS/Runtime/ProcessRunner.swift"
            swift.parent.mkdir(parents=True)
            swift.write_text("import Foundation\n")
            runtime = root / "runtime/private-cache.bin"
            runtime.parent.mkdir()
            runtime.write_bytes(b"fixture")
            sibling = swift.parent / "private-cache.bin"
            sibling.write_bytes(b"fixture")
            self.assertEqual(boundaries.check_ignored_swift_sources(root), [])
            ignored = subprocess.check_output(
                ["git", "-C", str(root), "check-ignore", "--no-index", "-z", "--stdin"],
                input=b"runtime/private-cache.bin\0Sources/AfterPlatformMacOS/Runtime/private-cache.bin\0",
            ).split(b"\0")
            self.assertEqual(len([path for path in ignored if path]), 2)

    def test_ignore_inspection_errors_fail_instead_of_claiming_sources_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Sources/AfterApp/Screen.swift"
            source.parent.mkdir(parents=True)
            source.write_text("import Foundation\n")
            # This directory is not a repository. Never turn Git's failure into
            # the successful empty result used when no source is ignored.
            with self.assertRaisesRegex(RuntimeError, "git check-ignore failed"):
                boundaries.check_ignored_swift_sources(root)


if __name__ == "__main__":
    unittest.main()
