# Long recordings

The recording limit controls capture, not Groq quota. New configurations default to three hours; existing saved limits remain intact. The shared configuration validates limits up to 24 hours, and each recording captures its deadline when it starts.

## Transcription contract

1. Files below 25 MB upload directly. This preserves support for Groq formats that the local audio decoder cannot read.
2. Larger files are decoded into consecutive PCM16 WAV parts, each at most ten minutes and below 24 MB. Every decoded frame belongs to exactly one part. The original file is never changed.
3. Before a nonfinal cut, inspect at most the last five seconds, never before the part's midpoint. Prefer the latest quiet interval lasting at least 200 ms, below -60 dBFS on every channel. Cut inside that interval; if quiet reaches the size/duration limit, use the limit. Otherwise use the hard limit. This is a conservative pause hint, not speech detection.
4. Upload one part at a time. When the caller has no explicit prompt, supply up to 224 UTF-8 bytes from the previous part's transcript as context, preserving complete characters. This conservatively fits Whisper's 224-token prompt limit. An explicit caller prompt takes precedence and is forwarded unchanged, just as for direct uploads.
5. Keep every nonblank response as a paragraph, separated by a blank line. Preserve its words, punctuation, and internal whitespace. The whitespace setting controls trimming around each paragraph. Do not align words, reconcile timestamps, or guess whether repeated words are duplicates.
6. Return success only after every upload and the response archive finish. Failure or cancellation removes temporary audio, multipart, and response files, keeps the original recording, and never retries automatically. A manual retry starts from the beginning.

## Tradeoff

[Groq recommends overlapping chunks](https://console.groq.com/docs/speech-to-text), and supports preceding-text prompts. Sotto instead chooses a contiguous audio partition with pause preference and text context: a small, verifiable contract without an ambiguous transcript-merging algorithm. When continuous speech forces a hard cut, recognition of a word crossing that cut can suffer. Paragraph boundaries remain visible; this does not promise seamless prose or unchanged recognition accuracy. All original audio and successful raw API responses remain available for inspection after a completed transcription.

The previous approach tried to reconcile independently recognized words and timestamps. Repeated words, omissions, timestamp drift, and inconsistent punctuation made ownership ambiguous. Successive local fixes increased complexity without resolving that ambiguity. The new guarantee is exact coverage of decoded audio and faithful assembly of API text; it cannot guarantee what the speech model recognizes.

## Memory and verification

One reusable decode buffer, one chunk file, and one multipart file bound audio memory independently of recording length. The multipart writer releases Foundation's temporary buffers per block. Raw responses spool to disk; the finished envelope uses a file-backed mapping. Returned transcript text grows with the amount of recognized speech.

The standalone tests compare exported samples across boundaries, including stereo pauses, uninterrupted audio, byte-limited cuts, and AAC tails. Integration fixtures cover paragraph assembly, opaque direct imports, original response bytes, quota failure, cancellation, and cleanup. The [resource benchmark](performance.md) exercises three hours of audio and speech-heavy responses on Apple Silicon and Intel. Neither deterministic test suite measures real-world speech recognition accuracy.
