# Live transcription routing

Reviewed against provider documentation on 2026-09-06. `StreamingCapability` is the single allowlist for model suggestions, connection validation, transport selection, and file recovery. Unknown models, custom endpoints, OpenRouter, and Groq use finalized 15-second WAV uploads. Model-name substrings never enable streaming.

| Provider | Live input models mapped | Protocol | File recovery |
| --- | --- | --- | --- |
| Mistral direct | `voxtral-mini-transcribe-realtime-2602` | WebSocket, PCM16 mono 16 kHz | `voxtral-mini-latest` |
| OpenAI direct | `gpt-live-transcribe`, `gpt-realtime-whisper`, `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, dated mini 2025-12-15, `whisper-1` | WebSocket, PCM16 mono 24 kHz | Same model for 4o/Whisper; `gpt-4o-mini-transcribe` for the other three |
| Deepgram direct | Nova-3/general, Nova-2/general/meeting/phonecall/medical/conversationalai | Listen v1 WebSocket, PCM16 mono 16 kHz | Same model |
| AssemblyAI direct | `universal-3-5-pro`, `universal-streaming-english`, `universal-streaming-multilingual` | Streaming v3 WebSocket, PCM16 mono 16 kHz | Existing file pipeline with `best` |

Settings → Transcription shows the resolved mode. Advanced settings can disable automatic streaming. Dictation's “Transcribe while recording” and each meeting's live-transcription choice still govern whether any audio leaves during capture. Unanswered calendar auto-starts remain local until recording ends. A late No cancels live connections.

## Current implementation

Audio is saved locally first, converted to mono PCM16, and sent in roughly 100 ms packets. Each recovery section has its own streaming connection, renewed at approximately 15 seconds; this is genuine live input within a section, not an uninterrupted meeting-long connection. Mic and system audio use separate streams. OpenAI's older committed-turn models receive a commit about every two seconds for incremental text; the continuous live models receive a final commit at the section boundary. This trades some context at boundaries for straightforward, durable recovery.

Provisional text is displayed but never checkpointed. Only a successful final transcript replaces its WAV section in the recovery manifest. Failed, timed-out, or overloaded streams disable streaming for that capture and use the complete local WAV through file transcription. Other completed sections are reused. File-only processing and crash recovery apply the explicit same-provider fallback model above; the UI discloses model changes. No credentials are moved between providers.

Each socket has a 45-second deadline including capture and finalization. Audio queues hold at most 200 packets and at most eight sections can wait for consumption. Cancellation closes sockets, including a connection stalled during its handshake. Local audio remains governed by the existing recovery and retention policy.

## Sources

- [Mistral realtime guide](https://docs.mistral.ai/studio/audio/speech_to_text/realtime_transcription), [official Python realtime transport](https://github.com/mistralai/client-python/blob/main/src/mistralai/extra/realtime/connection.py)
- [OpenAI realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription), [official realtime transcription model schema](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py)
- [Deepgram Listen v1 streaming](https://developers.deepgram.com/reference/speech-to-text/listen-streaming)
- [AssemblyAI streaming v3 specification](https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket)
- [OpenRouter file transcription](https://openrouter.ai/docs/guides/overview/multimodal/stt)
- [Groq file speech-to-text](https://console.groq.com/docs/speech-to-text)

## Verification and limits

Tests use synthetic PCM and scripted sockets; they cover sending before file close, sample conversion, final replacement, provider/endpoint mapping, recovery fallback, handshakes, and timeout cancellation. Live provider acceptance, latency, accuracy, and account model access require a recording with the corresponding provider key. A mapped model can still be rejected by the account or provider; that rejection falls back to file transcription. Adding a model to the allowlist requires verifying both its provider endpoint and event protocol.
