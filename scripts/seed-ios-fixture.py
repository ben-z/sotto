#!/usr/bin/env python3
"""Seed a completed note in a disposable simulator for UI persistence tests."""
import datetime
import json
from pathlib import Path
import shutil
import sys

container = Path(sys.argv[1])
if sys.argv[2:] not in ([], ["--long-list"]):
    raise SystemExit("Expected a simulator app data directory and optional --long-list")
if not container.is_absolute() or not container.is_dir() or "CoreSimulator" not in container.parts:
    raise SystemExit("Expected an existing simulator app data directory")
fixture = Path(__file__).resolve().parents[1] / "iOS/UITests/Fixtures/tone.m4a"
playback_fixture = fixture.with_name("tone-10s.m4a")
for required in (fixture, playback_fixture):
    if not required.is_file():
        raise SystemExit(f"Required audio fixture is missing: {required}")
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

# Dedicated rows for destructive UI checks; never reuse the editor fixture.
for suffix in ("a", "b"):
    identifier = f"ios-delete-fixture-{suffix}"
    record = json.loads((library / "ios-ui-fixture.json").read_text())
    record.update(id=identifier, title=f"Delete fixture {suffix.upper()}", audioFile=f"{identifier}.m4a")
    shutil.copyfile(fixture, library / record["audioFile"])
    (library / f"{identifier}.json").write_text(json.dumps(record))
    (library / f"{identifier}.txt").write_text(text)
    (library / f"{identifier}.response.json").write_text(json.dumps({"text": text}))

identifier = "ios-recovery-fixture"
record = json.loads((library / "ios-ui-fixture.json").read_text())
record.update(id=identifier, title="Unfinished fixture", status="recording", audioFile=f"{identifier}.m4a")
shutil.copyfile(fixture, library / record["audioFile"])
(library / f"{identifier}.json").write_text(json.dumps(record))
(library / f"{identifier}.md").write_text("Retained recovery text.")

identifier = "ios-unreadable-text-fixture"
record = json.loads((library / "ios-ui-fixture.json").read_text())
record.update(id=identifier, title="Unreadable edited note", audioFile=f"{identifier}.m4a")
shutil.copyfile(fixture, library / record["audioFile"])
(library / f"{identifier}.json").write_text(json.dumps(record))
(library / f"{identifier}.md").write_bytes(bytes([0xff]))
(library / f"{identifier}.txt").write_text("Recoverable machine transcript.")

# Keep the permission-denial fixture separate from the normal persistence checks.
for pattern in ("ios-feedback-fixture-*", "ios-corrupt-audio-fixture.*", "ios-playback-fixture.*"):
    for path in library.glob(pattern):
        path.unlink()
if sys.argv[2:]:
    for index in range(20):
        identifier = f"ios-feedback-fixture-{index:02}"
        record = json.loads((library / "ios-ui-fixture.json").read_text())
        record.update(id=identifier, title=f"Earlier note {index + 1}", audioFile=f"{identifier}.m4a",
                      startedAt="2020-01-01T00:00:00Z")
        shutil.copyfile(fixture, library / record["audioFile"])
        (library / f"{identifier}.json").write_text(json.dumps(record))
else:
    # Playback recovery uses real corrupt and playable files, without app test modes.
    for identifier, title, duration in (
        ("ios-corrupt-audio-fixture", "Corrupt audio fixture", 1),
        ("ios-playback-fixture", "Playback fixture", 10),
    ):
        record = json.loads((library / "ios-ui-fixture.json").read_text())
        record.update(id=identifier, title=title, audioFile=f"{identifier}.m4a", durationSeconds=duration)
        audio = library / record["audioFile"]
        if identifier == "ios-corrupt-audio-fixture":
            audio.write_bytes(b"This is not an audio file.")
        else:
            shutil.copyfile(playback_fixture, audio)
        record["audioBytes"] = audio.stat().st_size
        (library / f"{identifier}.json").write_text(json.dumps(record))
        (library / f"{identifier}.txt").write_text(text)
        (library / f"{identifier}.response.json").write_text(json.dumps({"text": text}))
