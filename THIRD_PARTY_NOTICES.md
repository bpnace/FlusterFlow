# Third-Party Notices

FlusterFlow is currently intended for private use. The following notices record the third-party runtime and model selected for the local speech-to-text path. They do not replace the complete license texts or legal review required before redistribution.

## FluidAudio

- Project: FluidAudio
- Source: <https://github.com/FluidInference/FluidAudio>
- Version: `0.15.5`
- Git revision: `19600a485baa4998812e4654b70d2bab8f2c9949`
- License: Apache License 2.0
- Pinned license file: <https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/LICENSE>

The Swift package is resolved to the version and revision above. The full Apache License 2.0 text is available in the pinned upstream license file and in the checked-out Swift package source.

## FastCluster

FluidAudio `0.15.5` includes a C/C++ wrapper around FastCluster for its speaker-diarization implementation. FlusterFlow does not call that feature directly, but the source is part of the linked Swift package and its notice is therefore retained.

- Project: FastCluster
- Source: <https://github.com/fastcluster/fastcluster>
- License: BSD 2-Clause
- Upstream notice in the pinned FluidAudio source: `ThirdPartyLicenses/fastcluster-LICENSE.md`

Copyright:

- Until package version 1.1.23: © 2011 Daniel Müllner, <https://danifold.net>
- All changes from version 1.1.24 on: © Google Inc., <https://www.google.com>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Parakeet TDT 0.6B v3 Core ML model

- Model repository: `FluidInference/parakeet-tdt-0.6b-v3-coreml`
- Source: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Pinned revision: `aed02740059203c4a87495924f685de3722ae9ce`
- Precision used by FlusterFlow: `int8`
- License recorded by the model-card metadata: Creative Commons Attribution 4.0 International (`CC-BY-4.0`)
- Pinned model card: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/blob/aed02740059203c4a87495924f685de3722ae9ce/README.md>
- Upstream base model named by the model card: `nvidia/parakeet-tdt-0.6b-v3`

Attribution is due to the authors and maintainers identified by the FluidInference model repository and its NVIDIA base model. The source repository and pinned model card above must remain discoverable with any permitted redistribution.

The pinned model card is internally inconsistent: its metadata declares `CC-BY-4.0`, while prose later in the same document mentions Apache 2.0. FlusterFlow therefore records and enforces `CC-BY-4.0` conservatively for this private MVP. The model must not be redistributed until the upstream licensing inconsistency has been resolved and the intended distribution has received a fresh license review.

Model weights are not committed to this source repository or bundled into the bootstrap application. They enter the private installation only through explicit local import or a user-authorized provisioning action, and are accepted only when every pinned artifact passes the size and SHA-256 manifest.

## Argmax OSS / WhisperKit

- Project: Argmax OSS Swift, product `WhisperKit`
- Source: <https://github.com/argmaxinc/argmax-oss-swift>
- Version: `1.0.0`
- Git revision: `25c62997041c134b03ca82731ce2f6fd2cae1eb9`
- License: MIT
- Pinned license: <https://github.com/argmaxinc/argmax-oss-swift/blob/25c62997041c134b03ca82731ce2f6fd2cae1eb9/LICENSE>

The package contains tokenizer code derived from Swift Transformers under Apache License 2.0. Its upstream `NOTICES` and license files remain part of the pinned package checkout.

## Whisper Large v3 Core ML models and tokenizer

- Converted model repository: `argmaxinc/whisperkit-coreml`
- Source: <https://huggingface.co/argmaxinc/whisperkit-coreml>
- Pinned revision: `97a5bf9bbc74c7d9c12c755d04dea59e672e3808`
- Installed variants: `openai_whisper-large-v3-v20240930_626MB` and `openai_whisper-large-v3-v20240930_turbo_632MB`
- Tokenizer repository: `openai/whisper-large-v3`
- Tokenizer revision: `06f233fe06e710322aca913c1bc4249a0d71fce1`
- License declared by the upstream OpenAI model card: Apache License 2.0
- Upstream model card: <https://huggingface.co/openai/whisper-large-v3>

The Argmax conversion repository does not independently declare a license for the converted Core ML artifacts. FlusterFlow therefore records the upstream model-card license together with this unresolved conversion-distribution detail. The models are installed only for private local use and must not be redistributed without a fresh license review.

## MLXAudio Swift and MLX Swift

- Project: MLXAudio Swift, product `MLXAudioSTT`
- Source: <https://github.com/Blaizzy/mlx-audio-swift>
- Version: `0.1.3`
- Git revision: `d302a5c6080d2bb97bae38c7418f82abb76013b6`
- License: MIT
- Project: MLX Swift
- Source: <https://github.com/ml-explore/mlx-swift>
- Directly pinned version: `0.31.4`
- Git revision: `dc43e62d7055353c7f99fa071a4e71d29dfddc44`
- License: MIT

The exact transitive package revisions are retained in `Package.resolved`. These packages provide the Apple-Silicon/Metal runtime used only by the selectable Qwen backend.

## Qwen3-ASR 0.6B 8-bit MLX model

- Converted model repository: `mlx-community/Qwen3-ASR-0.6B-8bit`
- Source: <https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit>
- Pinned revision: `89e96d92ba34aca20b3e29fb10cc284097d1219f`
- Upstream base model: `Qwen/Qwen3-ASR-0.6B`
- Upstream project: <https://github.com/QwenLM/Qwen3-ASR>
- Precision used by FlusterFlow: 8-bit MLX
- License recorded by the model repository: Apache License 2.0

The model is not bundled with the source or application. Its nine remote files and the deterministically derived local tokenizer are accepted only when the complete size and SHA-256 manifest passes.
