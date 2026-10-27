# Economical provider presets

Verified against official documentation on 2026-10-23. Prices are estimates in USD, before taxes and account-specific pricing. Selecting a provider in the connection editor chooses its economical preset. Existing model IDs remain available as custom selections, and credentials stay in Windows Credential Manager.

| Provider | Purpose | Default | Published price |
| --- | --- | --- | --- |
| OpenAI | Speech | `gpt-4o-mini-transcribe` | Approximately $0.003/min |
| OpenAI | Cleanup and summaries | `gpt-5.6-luna` | $0.20 input / $1.20 output per million tokens |
| Google Gemini | Speech, cleanup and summaries | `gemini-3.5-flash-lite` | $0.30 input / $2.50 output per million tokens |

OpenAI's `gpt-4o-transcribe` remains an explicit speech choice at approximately $0.006/min when accuracy matters more than cost. No automatic switch to it is made. Gemini uses native audio input to generateContent for saved chunks; it does not provide live partial text through OpenScribe's existing realtime transports. Account access and real-world speech accuracy have not been tested using the saved keys.

Gemini authentication uses the `x-goog-api-key` header. Response parsing excludes thought parts and combines visible text parts. The transcription instruction preserves language/script, supplies vocabulary/context, and requests no invented speech. OpenAI Luna requests use `reasoning_effort: none` and a completion-token bound to control unnecessary output cost.

Sources: [OpenAI transcription pricing](https://platform.openai.com/pricing), [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), [Gemini audio](https://ai.google.dev/gemini-api/docs/audio), [Gemini 3.5 Flash-Lite compatibility](https://ai.google.dev/gemini-api/docs/generate-content/whats-new-gemini-3.6).
