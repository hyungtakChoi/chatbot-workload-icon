import torch
import torch.nn as nn
from torch.nn import functional as F
import math

import brain.work.arch.transformer as transformer
import brain.work.arch.gpt1 as gpt1
import brain.work.arch.util as archutil

class GPT2SublayerConnection(nn.Module):
    """GPT-2 Style Sublayer Connection with Pre-norm and Residual Scaling"""
    def __init__(self, d_emb, dropout_rate, num_layers):
        super().__init__()
        self.layer_norm = nn.LayerNorm(d_emb, eps=1e-5)
        self.dropout = nn.Dropout(dropout_rate)
        self.num_layers = num_layers

    def forward(self, x, sublayer):
        # Pre-norm + residual scaling (1/√N where N is number of residual layers)
        residual = x
        x = self.layer_norm(x)  # Pre-norm: normalize before sublayer
        x = sublayer(x)
        x = self.dropout(x)
        # Residual scaling: 1/√N where N is the number of residual layers
        return residual + x * (1.0 / math.sqrt(self.num_layers))

class SparseAttention(nn.Module):
    """Sparse Attention Implementation (GPT-2 Style)"""
    def __init__(self, d_emb, d_q, d_k, n_heads, sparse_type='strided', sparse_factor=4):
        super().__init__()
        self.mhsa = transformer.MHA(d_emb, d_q, d_k, n_heads)
        self.sparse_type = sparse_type
        self.sparse_factor = sparse_factor

    def forward(self, x_q, x_k, x_v, mask):
        batch_size, seq_len, d_emb = x_q.shape
        
        if self.sparse_type == 'strided':
            # Strided attention: every sparse_factor tokens
            sparse_mask = torch.zeros_like(mask)
            for i in range(0, seq_len, self.sparse_factor):
                sparse_mask[:, i:i+self.sparse_factor, i:i+self.sparse_factor] = 1
        elif self.sparse_type == 'fixed':
            # Fixed attention: only attend to specific positions
            sparse_mask = torch.zeros_like(mask)
            # 예: 첫 번째, 중간, 마지막 토큰만 attention
            sparse_mask[:, 0, :] = 1  # 첫 번째 토큰
            sparse_mask[:, seq_len//2, :] = 1  # 중간 토큰
            sparse_mask[:, -1, :] = 1  # 마지막 토큰
        else:
            # Full attention (fallback)
            sparse_mask = torch.ones_like(mask)
        
        # Apply sparse attention
        return self.mhsa(x_q, x_k, x_v, mask & sparse_mask)

class GPT2DecoderLayer(nn.Module):
    """GPT-2 Decoder Layer with Standard Attention"""
    def __init__(self, d_emb, d_q, d_k, d_ff, n_heads, dropout_rate):
        super().__init__()
        self.mhsa = transformer.MHA(d_emb, d_q, d_k, n_heads)
        self.ff = transformer.FF(d_emb, d_ff)
        self.slc = nn.ModuleList([
            GPT2SublayerConnection(d_emb, dropout_rate, 2) for _ in range(2)
        ])

    def forward(self, x, mask_sa):
        # Pre-norm + residual scaling
        x = self.slc[0](x, lambda x: self.mhsa(x, x, x, mask_sa))
        x = self.slc[1](x, self.ff)
        return x

class GPT2SparseDecoderLayer(nn.Module):
    """GPT-2 Decoder Layer with Sparse Attention"""
    def __init__(self, d_emb, d_q, d_k, d_ff, n_heads, dropout_rate, 
                 sparse_type='strided', sparse_factor=4):
        super().__init__()
        self.mhsa = SparseAttention(d_emb, d_q, d_k, n_heads, sparse_type, sparse_factor)
        self.ff = transformer.FF(d_emb, d_ff)
        self.slc = nn.ModuleList([
            GPT2SublayerConnection(d_emb, dropout_rate, 2) for _ in range(2)
        ])

    def forward(self, x, mask_sa):
        # Pre-norm + residual scaling
        x = self.slc[0](x, lambda x: self.mhsa(x, x, x, mask_sa))
        x = self.slc[1](x, self.ff)
        return x

class GPT2Decoder(nn.Module):
    """GPT-2 Decoder with Optional Partial Sparse Attention"""
    def __init__(self, d_emb, d_q, d_k, d_ff, n_heads, n_layers, dropout_rate, 
                 sparse_layers=None, sparse_type='strided', sparse_factor=4):
        super().__init__()
        self.layers = nn.ModuleList()
        
        for i in range(n_layers):
            if sparse_layers is not None and i in sparse_layers:
                # Sparse attention layer
                layer = GPT2SparseDecoderLayer(
                    d_emb, d_q, d_k, d_ff, n_heads, dropout_rate, 
                    sparse_type=sparse_type, sparse_factor=sparse_factor
                )
            else:
                # Standard attention layer
                layer = GPT2DecoderLayer(
                    d_emb, d_q, d_k, d_ff, n_heads, dropout_rate
                )
            self.layers.append(layer)
        
        # Final layer normalization
        self.final_layer_norm = nn.LayerNorm(d_emb, eps=1e-5)

    def forward(self, x, mask_sa):
        for layer in self.layers:
            x = layer(x, mask_sa)
        # Final normalization
        x = self.final_layer_norm(x)
        return x

class GPT2(nn.Module):
    """GPT-2 Model with Key Improvements"""
    def __init__(self, config, sparse_layers=None, sparse_type='strided', sparse_factor=4):
        super().__init__()

        self.ctx_window_dec = config.ctx_window_dec

        self.config = config
        
        # Token embeddings
        self.token_embeddings = transformer.ELUT(config.vocab_size, config.d_emb)
        
        # Positional embeddings (기존 PE 사용)
        self.position_embeddings = gpt1.PE(config.ctx_window_dec, config.d_emb, config.dropout_rate_dec)
        
        # Decoder layers with optional partial sparse attention
        self.decoder = GPT2Decoder(
            config.d_emb, config.d_q, config.d_k, config.d_ff,
            config.n_heads_dec_sa, config.n_layers_dec, config.dropout_rate_dec,
            sparse_layers=config.sparse_layers, sparse_type=config.sparse_type, sparse_factor=config.sparse_factor
        )
        
        # Output projection with normalization
        self.output_projection = nn.Linear(config.d_emb, config.vocab_size, bias=False)
        self.output_projection.weight = self.token_embeddings.lut.weight  # Weight tying
        
        # Initialize weights
        self.apply(self._init_weights)

    def _init_weights(self, module):
        """GPT-2 style weight initialization"""
        if isinstance(module, nn.Linear):
            # Xavier initialization for linear layers
            nn.init.xavier_uniform_(module.weight)
            if module.bias is not None:
                nn.init.zeros_(module.bias)
        elif isinstance(module, nn.Embedding):
            # Normal initialization for embeddings
            nn.init.normal_(module.weight, mean=0.0, std=0.02)
        elif isinstance(module, nn.LayerNorm):
            # Layer norm initialization
            nn.init.ones_(module.weight)
            nn.init.zeros_(module.bias)

    def forward(self, x, mask):
        archutil.crop_data_to_ctx_window(x, self.ctx_window_dec)

        # Token embeddings
        x = self.token_embeddings(x)
        
        # Positional embeddings
        x = self.position_embeddings(x)
        
        # Decoder layers (final layer norm 포함)
        x = self.decoder(x, mask)
        
        # Output projection
        logits = self.output_projection(x)
        
        return logits 
