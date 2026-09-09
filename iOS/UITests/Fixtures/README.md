`tone.m4a` is a one-second, 440 Hz AAC tone used for the saved-note UI fixture. It contains no speech and is not an ASR accuracy fixture. It is copied into the disposable simulator by `scripts/seed-ios-fixture.py`, not bundled with the app.

Generated with:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=16000:duration=1' -ac 1 -c:a aac -b:a 32k tone.m4a
```
