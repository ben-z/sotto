#!/usr/bin/env python3
"""Seed a completed note in a disposable simulator for UI persistence tests."""
import datetime
import json
from pathlib import Path
import shutil
import sys

container = Path(sys.argv[1])
if not container.is_absolute() or not container.is_dir() or "CoreSimulator" not in container.parts:
    raise SystemExit("Expected an existing simulator app data directory")
fixture = Path(__file__).resolve().parents[1] / "iOS/UITests/Fixtures/tone.m4a"
if not fixture.is_file():
    raise SystemExit(f"Required audio fixture is missing: {fixture}")
library = container / "Documents/Recordings"
library.mkdir(parents=True, exist_ok=True)
identifier = "ios-ui-fixture"
(library / f"{identifier}.md").unlink(missing_ok=True)
audio = library / f"{identifier}.m4a"
shutil.copyfile(fixture, audio)
text = "Original fixture transcript."
(library / f"{identifier}.txt").write_text(text)
(library / f"{identifier}.response.json").write_text(json.dumps({"text": text}))
(library / f"{identifier}.json").write_text(json.dumps({
    "id": identifier, "title": "UI test fixture",
    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "status": "complete", "model": "whisper-large-v3-turbo", "language": "en",
    "prompt": "", "contextTerms": [], "audioFile": audio.name,
    "durationSeconds": 1, "audioBytes": audio.stat().st_size,
    "requestMilliseconds": 1, "requestID": "fixture",
}))
print(f"Seeded UI test fixture in {library}")
