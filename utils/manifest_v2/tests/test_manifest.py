import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from typer.testing import CliRunner

import cli
from cli import (
    LEGACY_MANIFEST_KEY,
    MANIFEST_V2_KEY,
    infer_artifact_type,
    load_manifest_v2,
    save_manifest_outputs,
)
from manifest import (
    Announcement,
    ArtifactChecksums,
    ChangelogEntry,
    SemesterDataFile,
    LoveACEManifest,
    ManifestV2,
    OTA,
    PlatformManifest,
    PlatformRelease,
    Release,
    ReleaseArtifact,
    SemesterEntry,
    SemesterManifest,
)
from s3_client import CANONICAL_CDN_BASE_URL


def semester_data() -> SemesterDataFile:
    return SemesterDataFile(
        version=1,
        updated_at="2026-07-23T00:00:00+08:00",
        semesters=[
            SemesterEntry(
                code="2026-2027-1",
                name="2026-2027学年第一学期",
                start_date="2026-08-31",
                weeks=18,
            )
        ],
    )


class FakeClient:
    def __init__(self, objects=None):
        self.objects = objects or {}

    def get_json(self, key, *, missing_ok=False):
        value = self.objects.get(key)
        if value is None and not missing_ok:
            raise FileNotFoundError(key)
        return value

    def upload_content(self, content, key):
        self.objects[key] = json.loads(content)
        return f"https://release.loveace.top/{key}"


class FakeReleaseClient:
    """In-memory stand-in for ``S3Client``; performs no network I/O.

    Mirrors only the surface ``cli.release`` relies on: ``get_json``,
    ``upload_content`` and ``upload_file``.
    """

    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.uploaded_files = {}

    def get_json(self, key, *, missing_ok=False):
        value = self.objects.get(key)
        if value is None and not missing_ok:
            raise FileNotFoundError(key)
        return value

    def upload_content(self, content, key):
        if isinstance(content, str):
            content = content.encode("utf-8")
        self.objects[key] = json.loads(content.decode("utf-8"))
        return f"{CANONICAL_CDN_BASE_URL}/{key}"

    def upload_file(self, local_path, key):
        self.uploaded_files[key] = Path(local_path).read_bytes()
        return f"{CANONICAL_CDN_BASE_URL}/{key}"


class ManifestTests(unittest.TestCase):
    def test_legacy_announcement_serializes_md5(self):
        announcement = Announcement(title="Title", content="Body")
        payload = json.loads(announcement.model_dump_json())
        self.assertEqual(payload["md5"], announcement.md5)

    def test_migration_rewrites_native_release_to_canonical_cdn(self):
        legacy = LoveACEManifest(
            ota=OTA(
                content="Update",
                changelog=[ChangelogEntry(version="1.2.3", changes="Fixed")],
                android=PlatformRelease(
                    version="1.2.3",
                    url=(
                        "https://release-oss.loveace.tech/loveace/releases/"
                        "android/1.2.3/app-release.apk"
                    ),
                    md5="abc",
                ),
            )
        )
        manifest = ManifestV2.from_legacy(legacy, semester_data())
        release = manifest.platforms["android"].releases[0]
        self.assertEqual(
            release.artifacts[0].url,
            (
                "https://release.loveace.top/loveace/releases/"
                "android/1.2.3/app-release.apk"
            ),
        )
        self.assertEqual(release.changelog, ["Fixed"])

    def test_v2_projects_platform_release_to_legacy(self):
        manifest = ManifestV2(
            semester=SemesterManifest.from_data_file(semester_data()),
            platforms={
                "android": PlatformManifest(
                    minimum_supported_build=10203,
                    releases=[
                        Release(
                            id="android-1.2.3-10203",
                            version="1.2.3",
                            build=10203,
                            published_at="2026-07-23T00:00:00Z",
                            summary="Update now",
                            changelog=["Fixed Android"],
                            artifacts=[
                                ReleaseArtifact(
                                    type="apk",
                                    arch="universal",
                                    url=(
                                        "https://release.loveace.top/loveace/releases/"
                                        "android/1.2.3/10203/app.apk"
                                    ),
                                    checksums=ArtifactChecksums(
                                        sha256="sha", md5="md5"
                                    ),
                                )
                            ],
                        )
                    ],
                )
            },
        )
        legacy = manifest.to_legacy_manifest()
        self.assertEqual(legacy.ota.android.version, "1.2.3")
        self.assertTrue(legacy.ota.android.force_ota)
        self.assertEqual(legacy.ota.android.md5, "md5")
        self.assertEqual(legacy.ota.changelog[0].version, "Android 1.2.3")

    def test_save_outputs_share_one_v2_snapshot(self):
        client = FakeClient()
        manifest = ManifestV2(
            semester=SemesterManifest.from_data_file(semester_data())
        )
        urls = save_manifest_outputs(client, manifest)
        self.assertEqual(set(urls), {"v2", "legacy_ota"})
        self.assertEqual(
            client.objects[MANIFEST_V2_KEY]["revision"], manifest.revision
        )
        self.assertIn("ota", client.objects[LEGACY_MANIFEST_KEY])

    def test_load_bootstraps_from_legacy(self):
        client = FakeClient(
            {
                LEGACY_MANIFEST_KEY: LoveACEManifest(
                    announcement=Announcement(title="Hello", content="World")
                ).model_dump(mode="json", exclude_none=True)
            }
        )
        manifest, migrated = load_manifest_v2(client)
        self.assertTrue(migrated)
        self.assertEqual(manifest.announcements[0].title, "Hello")


class AppImageReleasePathTests(unittest.TestCase):
    """Regression coverage for the Linux AppImage release path.

    The CI workflow invokes::

        cli.py release --platform linux --arch x86_64 --file *.AppImage

    A previous blocker was that the ``ReleaseArtifact.type`` Literal did not
    accept ``"appimage"``, so publishing an AppImage failed pydantic
    validation *after* the upload had already happened.  These tests never
    touch the network: ``S3Client`` is replaced by ``FakeReleaseClient``.
    """

    VERSION = "1.1.12"
    BUILD = "23"
    APPIMAGE_NAME = "LoveACE-1.1.12-x86_64.AppImage"
    OBJECT_KEY = "loveace/releases/linux/1.1.12/23/LoveACE-1.1.12-x86_64.AppImage"

    def run_release(self, client, file_path, *extra_args):
        with mock.patch.object(cli, "S3Client", lambda: client):
            return CliRunner().invoke(
                cli.app,
                [
                    "release",
                    "--version",
                    self.VERSION,
                    "--build",
                    self.BUILD,
                    "--platform",
                    "linux",
                    *extra_args,
                    "--file",
                    str(file_path),
                ],
            )

    def test_release_artifact_literal_accepts_appimage(self):
        artifact = ReleaseArtifact(
            type="appimage",
            arch="x86_64",
            url=f"{CANONICAL_CDN_BASE_URL}/{self.OBJECT_KEY}",
            checksums=ArtifactChecksums(sha256="sha", md5="md5"),
        )
        self.assertEqual(artifact.type, "appimage")

    def test_infer_artifact_type_accepts_appimage_regardless_of_case(self):
        for name in (
            "LoveACE-1.1.12-x86_64.AppImage",
            "LoveACE-1.1.12-x86_64.appimage",
            "LoveACE-1.1.12-x86_64.APPIMAGE",
        ):
            with self.subTest(name=name):
                self.assertEqual(infer_artifact_type(Path(name)), "appimage")

    def test_release_cli_publishes_linux_appimage(self):
        payload = b"loveace-appimage-payload"
        client = FakeReleaseClient()

        with tempfile.TemporaryDirectory() as tmp:
            appimage = Path(tmp) / self.APPIMAGE_NAME
            appimage.write_bytes(payload)
            result = self.run_release(client, appimage, "--arch", "x86_64")

        self.assertEqual(result.exit_code, 0, msg=result.output)

        expected_url = f"{CANONICAL_CDN_BASE_URL}/{self.OBJECT_KEY}"
        self.assertEqual(client.uploaded_files[self.OBJECT_KEY], payload)

        stored_release = client.objects[MANIFEST_V2_KEY]["platforms"]["linux"][
            "releases"
        ][0]
        self.assertEqual(stored_release["id"], "linux-1.1.12-23")
        artifact = stored_release["artifacts"][0]
        self.assertEqual(artifact["type"], "appimage")
        self.assertEqual(artifact["arch"], "x86_64")
        self.assertEqual(artifact["url"], expected_url)
        self.assertEqual(artifact["size"], len(payload))
        self.assertEqual(
            artifact["checksums"]["sha256"], hashlib.sha256(payload).hexdigest()
        )
        self.assertEqual(
            artifact["checksums"]["md5"], hashlib.md5(payload).hexdigest()
        )

        # The shipped clients read the legacy projection, so the linux entry
        # must be present there too.
        legacy_linux = client.objects[LEGACY_MANIFEST_KEY]["ota"]["linux"]
        self.assertEqual(legacy_linux["version"], self.VERSION)
        self.assertEqual(legacy_linux["url"], expected_url)
        self.assertEqual(legacy_linux["md5"], hashlib.md5(payload).hexdigest())
        self.assertEqual(legacy_linux["type"], "native")

    def test_release_cli_rejects_non_native_artifact(self):
        client = FakeReleaseClient()

        with tempfile.TemporaryDirectory() as tmp:
            deb = Path(tmp) / "loveace_1.1.12_amd64.deb"
            deb.write_bytes(b"not-a-native-artifact")
            result = self.run_release(client, deb)

        self.assertNotEqual(result.exit_code, 0)
        self.assertEqual(client.uploaded_files, {})


if __name__ == "__main__":
    unittest.main()
