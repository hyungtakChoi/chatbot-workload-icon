import torch
import torch.nn as nn
import torch.optim as optim
from torch.nn import functional as F
import math

import brain.work.arch.transformer as transformer
import brain.work.arch.util as archutil

class PE(nn.Module):
    """Learnable Positional Encoding (BERT-style)"""
    def __init__(self, max_position_embeddings, d_emb, dropout_rate):
        super().__init__()
        self.dropout = nn.Dropout(p=dropout_rate)
        self.position_embeddings = nn.Embedding(max_position_embeddings, d_emb)

    def forward(self, x):
        # x: (batch, seq_len, d_emb)
        batch_size, seq_len, _ = x.size()
        position_ids = torch.arange(seq_len, dtype=torch.long, device=x.device)
        position_ids = position_ids.unsqueeze(0).expand(batch_size, seq_len)  # (batch, seq_len)
        pos_emb = self.position_embeddings(position_ids)  # (batch, seq_len, d_emb)
        x = x + pos_emb
        return self.dropout(x)

class GPTDecoderLayer(nn.Module):
    """Decoder layer for GPT (self-attention only, no cross-attention)."""
    def __init__(self, d_emb, d_q, d_k, d_ff, n_heads, dropout_rate):
        super().__init__()
        self.mhsa = transformer.MHA(d_emb, d_q, d_k, n_heads)
        self.ff = transformer.FF(d_emb, d_ff)
        self.slc = nn.ModuleList([transformer.SublayerConnection(d_emb, dropout_rate) for _ in range(2)])

    def forward(self, x, mask_sa):
        # Masked multi-head self-attention
        x = self.slc[0](x, lambda x: self.mhsa(x, x, x, mask_sa))
        x = self.slc[1](x, self.ff)
        return x

class GPTDecoder(nn.Module):
    """Stacked GPTDecoderLayers (self-attention only)."""
    def __init__(self, d_emb, d_q, d_k, d_ff, n_heads, n_layers, dropout_rate):
        super().__init__()
        self.layers = nn.ModuleList([
            GPTDecoderLayer(d_emb, d_q, d_k, d_ff, n_heads, dropout_rate) for _ in range(n_layers)
        ])

    def forward(self, x, mask_sa):
        for layer in self.layers:
            x = layer(x, mask_sa)
        return x 

class GPT1(nn.Module):
    """GPT-style Transformer (decoder-only)"""
    def __init__(self, config):
        super().__init__()

        self.ctx_window_dec = config.ctx_window_dec

        self.elut = transformer.ELUT(config.vocab_size, config.d_emb)
        self.pe = PE(config.ctx_window_dec, config.d_emb, config.dropout_rate_dec)
        self.decoder = GPTDecoder(
            config.d_emb, config.d_q, config.d_k, config.d_ff,
            config.n_heads_dec_sa, config.n_layers_dec, config.dropout_rate_dec
        )
        self.linear = nn.Linear(config.d_emb, config.vocab_size, bias=False)
        self.linear.weight = self.elut.lut.weight

    def forward(self, x, mask):
        x = archutil.crop_data_to_ctx_window(x, self.ctx_window_dec)

        x = self.elut(x)
        x = self.pe(x)
        x = self.decoder(x, mask)
        logits = self.linear(x)
        return logits
