import json
import math
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
STAMP_SCRIPT = REPO_ROOT / "scripts" / "shared" / "stamp-map-default-view.py"


class StampMapDefaultViewTests(unittest.TestCase):
    def test_generates_platform_defaults_from_semantic_target_and_map_metadata(self):
        self.assertTrue(STAMP_SCRIPT.exists(), f"Missing stamping helper: {STAMP_SCRIPT}")

        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            manifest_path = repo / "shared" / "map-default-view.json"
            metadata_path = repo / "cache" / "binary-assets" / "mbtiles" / "map-metadata.json"
            manifest_path.parent.mkdir(parents=True)
            metadata_path.parent.mkdir(parents=True)

            manifest_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "name": "lumbridge-spawn-courtyard",
                        "gameCoordinates": {"x": 3222.0, "y": 3218.0, "plane": 0},
                        "mapLibre": {"zoom": "7.3414426741929"},
                    }
                )
            )
            metadata_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "gameCoordScale": 4.0,
                        "gameBounds": {
                            "minX": 960.0,
                            "maxX": 4224.0,
                            "minY": 1216.0,
                            "maxY": 12608.0,
                        },
                        "sourceImage": {"width": 13056.0, "height": 45568.0},
                        "tilePyramid": {"tileSize": 1024.0, "maxZoom": 6, "canvasSize": 65536.0},
                    }
                )
            )

            subprocess.run(
                [
                    "python3",
                    str(STAMP_SCRIPT),
                    "--repo-root",
                    str(repo),
                    "--manifest",
                    str(manifest_path),
                    "--metadata",
                    str(metadata_path),
                ],
                check=True,
                text=True,
                capture_output=True,
            )

            expected_lon = -180.0 + ((3222.0 - 960.0) * 4.0 / 65536.0) * 360.0
            expected_lat = math.degrees(
                math.atan(math.sinh(math.pi * (1.0 - 2.0 * ((12608.0 - 3218.0) * 4.0 / 65536.0))))
            )

            kotlin = (
                repo
                / "platforms/android/app/src/main/java/com/omiyawaki/osrswiki/ui/map/osrsMapDefaultView.kt"
            ).read_text()
            swift = (repo / "platforms/ios/osrswiki/Models/osrsMapDefaultView.swift").read_text()

            self.assertIn("const val GAME_MIN_X = 960.0", kotlin)
            self.assertIn("const val SOURCE_IMAGE_WIDTH = 13056.0", kotlin)
            self.assertIn(f"const val LONGITUDE = {expected_lon}", kotlin)
            self.assertIn(f"static let longitude = {expected_lon}", swift)
            self.assertIn(f"static let latitude = {expected_lat}", swift)
            self.assertIn("static func mapCoordinate(gameX: Double, gameY: Double)", swift)


if __name__ == "__main__":
    unittest.main()
