# Third-party notices

Wordy is released under the MIT License (see `LICENSE`). The built application
bundles or downloads the following third-party components.

## whisper.cpp and ggml

Wordy's transcription worker statically links `whisper.cpp` and its `ggml`
tensor library, fetched at build time by `scripts/fetch-whisper.sh` at the
release pinned in `docs/inference.md`. Source: <https://github.com/ggml-org/whisper.cpp>.

```text
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Whisper speech models

Speech models are not part of this repository. At the user's request the app
downloads ggml-format conversions of OpenAI's Whisper models from
<https://huggingface.co/ggerganov/whisper.cpp>, verified against the SHA-256
values pinned in `Core/SpeechModelCatalog.swift`. The Whisper model weights are
released by OpenAI under the MIT License
(<https://github.com/openai/whisper/blob/main/LICENSE>).
