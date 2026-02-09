#!/usr/bin/env python3
"""
Convert DictaBERT (dicta-il/dictabert) to Core ML with INT8 quantization.

Usage:
    pip install transformers torch coremltools
    python convert_dictabert_coreml.py

Outputs:
    ../Resources/DictaBERT_INT8.mlpackage   – quantized Core ML model
    ../Resources/vocab.txt                   – WordPiece vocabulary
"""

import types
import shutil
from pathlib import Path

import torch
import numpy as np
from transformers import AutoTokenizer, AutoModelForMaskedLM
import coremltools as ct

# ── Configuration ──────────────────────────────────────────────────
MODEL_NAME = "dicta-il/dictabert"
MAX_SEQ_LEN = 128       # Sufficient for single-line Hebrew OCR
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "Resources"


class MaskedLMWrapper(torch.nn.Module):
    """
    Wrapper that:
    - Pre-computes position_ids (avoids dynamic int cast in embeddings)
    - Pre-computes 4D attention mask (avoids masking_utils ops unsupported by coremltools)
    """
    def __init__(self, hf_model, max_seq_len):
        super().__init__()
        self.bert = hf_model.bert
        self.cls = hf_model.cls
        self.register_buffer(
            "position_ids",
            torch.arange(max_seq_len).unsqueeze(0)
        )

    def forward(self, input_ids, attention_mask, token_type_ids):
        # Build 4D extended attention mask from 2D using simple ops only.
        # This replaces masking_utils which uses new_ones/bitwise_and/etc.
        # Shape: [batch, 1, 1, seq_len]  — 0.0 for attend, large negative for ignore
        extended_mask = attention_mask.unsqueeze(1).unsqueeze(2).to(torch.float32)
        extended_mask = (1.0 - extended_mask) * (-3.4028e+38)

        # Run BERT encoder directly, passing the pre-computed 4D mask
        embedding_output = self.bert.embeddings(
            input_ids=input_ids,
            position_ids=self.position_ids,
            token_type_ids=token_type_ids,
        )
        encoder_output = self.bert.encoder(
            embedding_output,
            attention_mask=extended_mask,
        )
        sequence_output = encoder_output[0]

        # Run the MLM classification head
        prediction_scores = self.cls(sequence_output)
        return prediction_scores


def main():
    print(f"📦 Loading {MODEL_NAME} from HuggingFace...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = AutoModelForMaskedLM.from_pretrained(
        MODEL_NAME,
        attn_implementation="eager",
    )
    model.eval()

    # ── Export vocabulary ──────────────────────────────────────────
    vocab_path = OUTPUT_DIR / "vocab.txt"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    vocab = tokenizer.get_vocab()
    ordered = sorted(vocab.items(), key=lambda kv: kv[1])
    with open(vocab_path, "w", encoding="utf-8") as f:
        for token, _ in ordered:
            f.write(token + "\n")
    print(f"✅ Wrote vocabulary ({len(ordered)} tokens) → {vocab_path}")

    # ── Trace the model ────────────────────────────────────────────
    print("🔄 Tracing model with torch.jit.trace...")
    wrapper = MaskedLMWrapper(model, MAX_SEQ_LEN)
    wrapper.eval()

    dummy_ids = torch.randint(0, 1000, (1, MAX_SEQ_LEN), dtype=torch.long)
    dummy_mask = torch.ones(1, MAX_SEQ_LEN, dtype=torch.long)
    dummy_type_ids = torch.zeros(1, MAX_SEQ_LEN, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask, dummy_type_ids))
    print("✅ Tracing succeeded")

    # ── Convert to Core ML ─────────────────────────────────────────
    print("🔄 Converting to Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="logits"),
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
    )

    # ── INT8 quantization ──────────────────────────────────────────
    print("🔄 Applying INT8 quantization...")
    mlmodel_int8 = ct.compression_utils.affine_quantize_weights(
        mlmodel, mode="linear", dtype=np.int8
    )

    # ── Save ───────────────────────────────────────────────────────
    mlpackage_path = OUTPUT_DIR / "DictaBERT_INT8.mlpackage"
    if mlpackage_path.exists():
        shutil.rmtree(mlpackage_path)
    mlmodel_int8.save(str(mlpackage_path))

    size_mb = sum(
        f.stat().st_size for f in mlpackage_path.rglob("*") if f.is_file()
    ) / (1024 * 1024)
    print(f"✅ Saved Core ML model ({size_mb:.0f} MB) → {mlpackage_path}")
    print("🎉 Done! Add DictaBERT_INT8.mlpackage and vocab.txt to the Xcode project.")


if __name__ == "__main__":
    main()
