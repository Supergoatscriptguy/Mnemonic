# Mnemonic

Mnemonic is a small chat language model, and everything that made it is written in assembly. The CPU side is
x86-64 in NASM: reading the dataset's parquet files (with its own zstd and snappy decoders), the byte-level BPE
tokenizer, the training loop, and the program you chat with. The GPU side is hand-written PTX, every kernel that
training needs, from the tensor core matmuls to flash attention and AdamW. There's no C, no Python, no CUDA toolkit
and no libraries. The programs talk to Windows through kernel32 (and winhttp for downloads) and to the GPU through
nvcuda.dll, which comes with the NVIDIA driver. I trained it on one RTX 5070 Ti at home.

- **How it was built:** [mnemonic-site.vercel.app](https://mnemonic-site.vercel.app) has a chapter for each stage.
  Its home page runs the model in your browser, on an engine I also wrote by hand in WebAssembly.
- **The models:** [huggingface.co/SuperGoatScriptGuy/Mnemonic](https://huggingface.co/SuperGoatScriptGuy/Mnemonic)
- **Ollama:** `ollama run supergoatscriptguy/mnemonic`

## The models

| | 126M | 300M |
| --- | --- | --- |
| Layers and width | 16 x 768 | 24 x 1024 |
| Context | 1,024 tokens | 2,048 tokens |
| Pretraining | 5B tokens of FineWeb-Edu, 19.5 hours | 10B tokens, 90 hours |
| Validation loss | 3.101 | 2.841 |

Both are Llama-style (RoPE, RMSNorm, SwiGLU, grouped-query attention, tied embeddings) with a 32,768-token
vocabulary, and both were fine-tuned for chat on smol-smoltalk plus a small set of conversations about who the model
is. They're small models: they write fluently, get facts wrong often, and can't do arithmetic.

## What's in here

| Folder | What it has |
| --- | --- |
| `lib` | Shared routines: console output, number formatting (floats included), files, memory, threads, timers, random numbers, the progress bar, Ctrl+C handling |
| `data` | The parquet reader, zstd and snappy decompression, a WinHTTP downloader, text extraction |
| `tokenizer` | BPE training, encoding and decoding, tokenizing the dataset on every core |
| `gpu` | The CUDA driver API from assembly, the matmul kernels (bf16 and MXFP8), benchmarks |
| `model` | The transformer: parameter layout, forward and backward passes as kernel launches, and the PTX for norms, attention and the rest |
| `train` | The trainer (checkpoints, resuming, the progress bar, logs), chat data packing, a profiler |
| `chat` | int8 and int4 quantization, the CPU inference engine (AVX2 and AVX-VNNI), the console chat, GGUF export for Ollama |
| `site` | The WebAssembly engine behind the browser demo |
| `test` | Self-checking tests for all of the above |
| `asmdata` | Tools for a NASM fine-tuning set, on hold for now |

It comes to about 40,500 lines of NASM, 5,300 lines of PTX and 1,300 lines of WebAssembly text.

## Building

You need:

- Windows 10 or 11 on x64.
- [NASM](https://www.nasm.us). `build.bat` looks for it in `%LOCALAPPDATA%\bin\NASM\`.
- The MSVC linker from the Visual Studio Build Tools, and the Windows SDK for `kernel32.lib`. `build.bat` finds
  `link.exe` with vswhere and expects SDK 10.0.26100.0. Change the `SDKLIB` line if yours is different.
- For training, an NVIDIA GPU with bf16 tensor cores (RTX 30 series or newer). `fp8=1` needs an RTX 50 series card.

```
.\build.bat chat\chat     assembles chat\chat.asm and everything it uses into bin\chat.exe
.\test.bat                builds every program and runs all the tests
```

## Chatting with it

The browser demo and Ollama are the quickest ways. To run my own engine, build `bin\chat`, then put a model in
`models\` and the tokenizer in `datasets\`:

```
.\build.bat chat\chat
mkdir models
mkdir datasets
curl.exe -L -o models\mnemonic-300m-q8.mnm https://huggingface.co/SuperGoatScriptGuy/Mnemonic/resolve/main/mnemonic-300m-q8.mnm
curl.exe -L -o datasets\tokenizer.bin https://mnemonic-site.vercel.app/tokenizer.bin
.\bin\chat
```

It runs on the CPU. On mine the 300M in int8 writes about 220 tokens a second and the 126M about 540. It takes
`model=`, `temp=`, `top_p=` and `threads=`, and `/reset` starts a new conversation.

## Training it yourself

Each step is a program in this repo:

1. `bin\download fineweb 0 199` fetches 200 shards of FineWeb-Edu (about 11B tokens), and
   `bin\download fineweb 1822 1822` the shard used for validation.
2. `bin\extract` turns parquet files into plain documents, `bin\bpetrain` learns the tokenizer from the first
   gigabyte of them, and `bin\tokenize` turns the documents into token files.
3. `bin\train dev` trains the 22M test model in under an hour. `bin\train main` trains the 126M and
   `bin\train stretch` the 300M. Ctrl+C saves a checkpoint and stops, and the same command resumes.
4. `bin\train main gen="Once upon a time"` samples from your newest checkpoint.

A pretrained model only continues text. The chat fine-tune, the quantizer and the GGUF export each have a chapter
on the site.

## Training in FP8

`fp8=1` runs the matmuls inside the transformer layers in MXFP8 on RTX 50 series tensor cores: 8-bit values with a
shared scale per 32, summed in fp32, with fp32 master weights. I retrained the 126M this way to compare. It ended at
a validation loss of 3.105 against 3.101 in bf16, and took 14.4 hours instead of 19.5.

## How it's checked

Every optimized kernel has a slow, obviously correct reference version, and `test.bat` compares the two on every
run, bit for bit wherever the math allows it. The backward pass is checked with finite differences, stopping and
resuming a training run has to give the same bits as not stopping, and the browser engine is checked against the
native one.

## Credits

The pretraining data is [FineWeb-Edu](https://huggingface.co/datasets/HuggingFaceFW/fineweb-edu) from Hugging Face,
through Andrej Karpathy's shuffled shards
([karpathy/fineweb-edu-100b-shuffle](https://huggingface.co/datasets/karpathy/fineweb-edu-100b-shuffle)). The chat
data is [smol-smoltalk](https://huggingface.co/datasets/HuggingFaceTB/smol-smoltalk), also from Hugging Face.
