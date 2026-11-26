#!/usr/bin/env python3
"""Run preflight against disposable projects; never build or access a device."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("release_preflight.sh")


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="recoco-preflight-test-")
        self.root = Path(self.temp.name)
        self.write("scripts/release_preflight.sh", SCRIPT.read_text())
        self.settings = {
            "PRODUCT_BUNDLE_IDENTIFIER": "app.recoco.ios",
            "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "84",
            "INFOPLIST_FILE": "Recoco/Info.Release.plist",
            "CODE_SIGN_ENTITLEMENTS": "Recoco/Recoco.Release.entitlements",
        }
        self.objects = {
            "project": {"isa": "PBXProject", "buildConfigurationList": "projectList"},
            "projectList": {"buildConfigurations": ["projectRelease"]},
            "projectRelease": {"name": "Release", "buildSettings": {}},
            "app": {"isa": "PBXNativeTarget", "name": "Recoco", "buildConfigurationList": "appList", "buildPhases": ["resources"]},
            "appList": {"buildConfigurations": ["debug", "release"]},
            "debug": {"name": "Debug", "baseConfigurationReference": "prototypeConfig", "buildSettings": {"DEVELOPMENT_TEAM": "DEBUG12345", "CURRENT_PROJECT_VERSION": "1"}},
            "release": {"name": "Release", "buildSettings": self.settings},
            "resources": {"isa": "PBXResourcesBuildPhase", "files": []},
        }
        self.info = {
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "RECOCO_SUBSCRIPTIONS_ENABLED": False,
            "NSPhotoLibraryUsageDescription": "선택한 사진에서 정리 후보를 찾아요.",
        }
        self.entitlements = {}
        self.write("Config.xcconfig", "GOOGLE_CLIENT_ID = your_debug_placeholder\n")
        self.write("Recoco.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "{}")
        self.write("Recoco.xcodeproj/xcshareddata/xcschemes/Recoco.xcscheme", '<Scheme><ArchiveAction buildConfiguration="Release"/></Scheme>')
        for name in ("Recoco/Resources/PrivacyInfo.xcprivacy", "ExportOptions.TestFlight.plist"):
            self.plist(name, {})
        for name in ("PRIVACY_POLICY.md", "TERMS_OF_SERVICE.md", "APP_STORE_SUBMISSION.md", "TESTING.md"):
            self.write(name, "Fixture")
        self.write("RecocoTests/Test.swift", "func testFixture() {}")
        self.write("RecocoUITests/Test.swift", "func testFixture() {}")
        self.write("Recoco/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", "fixture")
        for name, command in {
            "sw_vers": "printf '26.6.2\\n'",
            "xcode-select": "printf '/Applications/Xcode.app/Contents/Developer\\n'",
            "xcodebuild": "if [ \"$1\" = -version ]; then printf 'Xcode 26.5\\n'; else echo UNEXPECTED_XCODE_ACTION; exit 55; fi",
        }.items():
            path = self.write("bin/" + name, "#!/bin/sh\n" + command + "\n")
            path.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def plist(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def run_check(self, *args, extra_env=None):
        self.write("Recoco.xcodeproj/project.pbxproj", json.dumps({"objects": self.objects}))
        self.plist("Recoco/Info.Release.plist", self.info)
        self.plist("Recoco/Recoco.Release.entitlements", self.entitlements)
        env = dict(os.environ, PATH=str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", RECOCO_RELEASE_VERSION="1.0", RECOCO_RELEASE_BUILD="84")
        env.update(extra_env or {})
        return subprocess.run(["/bin/bash", str(self.root / "scripts/release_preflight.sh"), *args], text=True, capture_output=True, env=env)

    def test_local_scope_ignores_debug_account_setup_but_needs_release_team(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("0 code/config failure(s), 1 distribution blocker(s)", result.stdout)
        self.assertNotIn("[FAIL]", result.stdout)

    def test_team_override_validates_format_not_membership(self):
        result = self.run_check("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("command-line override only", result.stdout)
        self.assertIn("membership, distribution profiles and App Store Connect access remain unverified", result.stdout)
        self.assertNotIn("DEVELOPMENT_TEAM", self.settings)

    def test_auth_checks_are_opt_in(self):
        result = self.run_check("--with-auth", "--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Production Firebase configuration is missing", result.stdout)
        self.assertIn("requires Sign in with Apple entitlement", result.stdout)

    def configure_apple(self):
        self.objects["resources"]["files"] = ["googleBuild"]
        self.objects["googleBuild"] = {"fileRef": "googleFile"}
        self.objects["googleFile"] = {"path": "GoogleService-Info.plist"}
        self.plist("GoogleService-Info.plist", {"BUNDLE_ID": "app.recoco.ios"})
        self.entitlements["com.apple.developer.applesignin"] = ["Default"]
        self.info["RECOCO_APPLE_LOGIN_ENABLED"] = True

    def test_native_apple_login_does_not_require_google_callback(self):
        self.configure_apple()
        result = self.run_check("--with-apple-auth", "--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MANUAL REQUIRED", result.stdout)

    def test_apple_login_cannot_pass_local_release_preflight(self):
        self.info["RECOCO_APPLE_LOGIN_ENABLED"] = True
        result = self.run_check("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires --with-apple-auth", result.stdout)

    def test_apple_login_requires_exact_bundle_and_enabled_flag(self):
        self.configure_apple()
        self.plist("GoogleService-Info.plist", {"BUNDLE_ID": "wrong.bundle"})
        self.info["RECOCO_APPLE_LOGIN_ENABLED"] = False
        result = self.run_check("--with-apple-auth", "--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Firebase Bundle ID does not match", result.stdout)
        self.assertIn("must be explicitly enabled", result.stdout)

    def test_release_only_guards_reject_wrong_scope_or_identity(self):
        mutations = [
            (self.info, "RECOCO_SUBSCRIPTIONS_ENABLED", True, "Subscriptions must be explicitly disabled"),
            (self.info, "CFBundleVersion", "1", "must use CURRENT_PROJECT_VERSION"),
            (self.info, "CFBundleURLTypes", [], "must not include social sign-in callback"),
            (self.settings, "PRODUCT_BUNDLE_IDENTIFIER", "app.recoco.ios.photonativetest", "Bundle ID must be app.recoco.ios"),
            (self.settings, "CURRENT_PROJECT_VERSION", "83", "build number does not match 84"),
        ]
        for data, key, value, message in mutations:
            with self.subTest(key=key):
                old = data.get(key)
                data[key] = value
                result = self.run_check("--team", "ABCDE12345")
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stdout)
                if old is None: data.pop(key)
                else: data[key] = old

    def test_missing_permission_copy_is_not_a_false_pass(self):
        self.info.pop("NSPhotoLibraryUsageDescription")
        result = self.run_check("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Photo permission purpose is missing", result.stdout)

    def test_bundled_firebase_cannot_accidentally_enable_services(self):
        self.objects["resources"]["files"] = ["googleBuild"]
        self.objects["googleBuild"] = {"fileRef": "googleFile"}
        self.objects["googleFile"] = {"path": "GoogleService-Info.plist"}
        result = self.run_check("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("could initialize optional account services", result.stdout)

    def test_tests_cannot_target_physical_user_data(self):
        result = self.run_check("--team", "ABCDE12345", "--run-tests", extra_env={"RECOCO_TEST_DESTINATION": "platform=iOS,id=physical-phone"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("physical user data must not be seeded/reset", result.stdout)
        self.assertNotIn("UNEXPECTED_XCODE_ACTION", result.stdout)

    def test_help_and_invalid_team_do_not_run_checks(self):
        result = self.run_check("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--team validates", result.stdout)
        self.assertEqual(self.run_check("--team", "bad").returncode, 2)


if __name__ == "__main__":
    unittest.main()
