import torch
import torch.nn as nn
from tqdm import tqdm
import csv
import pandas as pd
import time
from pathlib import Path
import argparse
import datasets
from transformers import AutoTokenizer
from torch.utils.data import DataLoader, Dataset
from torch.nn.utils.rnn import pad_sequence

from brain.work.arch.config import Config, ArchType, DataTypeGpt
from brain.work.util.bpe_tokenizer import BPETokenizer, GPT2Tokenizer
import brain.work.arch.gpt1 as gpt1 
import brain.work.arch.gpt2 as gpt2
import brain.work.arch.util as archutil
import brain.work.tmpl.util as tmplutil

class GPTWork:
    """
    ArchType, Config, DataType을 파라미터로 받는 최종 워크로드 클래스.
    """
    def __init__(self, arch_type: ArchType, data_type: DataTypeGpt, config: Config, device):
        self.ctx_window_dec = config.ctx_window_dec

        self.arch_type = arch_type
        self.data_type = data_type
        self.config = config
        self.device = device
        self.model = None
        self.tokenizer = None
    
        self._setup_model()

    def _setup_model(self):
        """arch_type과 config 객체를 기반으로 모델을 준비합니다."""
        # -------------------- toeknizer setting
        if self.arch_type == ArchType.GPT1:
            try:
                self.tokenizer = AutoTokenizer.from_pretrained("openai-gpt")
                if self.tokenizer.pad_token is None:
                    self.tokenizer.add_special_tokens({'pad_token': '[PAD]'}) 
                    self.config.vocab_size += 1
                    # openai-gpt 토크나이저는 pad_token 을 가지고 있지 않음
                    # 않은 상태의 크기가 40477 이며 pad_token 을 임의로 추가하여 활용하여야 함
            except FileNotFoundError:
                self.tokenizer = None
                
        elif self.arch_type in [ArchType.GPT2, ArchType.GPT3]:
            try:
                # self.tokenizer.load(tokenizer_path)
                self.tokenizer = AutoTokenizer.from_pretrained("gpt2")
                if self.tokenizer.pad_token is None:
                    self.tokenizer.pad_token = self.tokenizer.eos_token
            except FileNotFoundError:
                self.tokenizer = None
        # -------------------- model setting
        if self.arch_type == ArchType.GPT1:
            ModelClass = gpt1.GPT1
        elif self.arch_type in [ArchType.GPT2, ArchType.GPT3]:
            ModelClass = gpt2.GPT2
        else:
            raise ValueError(f"지원하지 않는 아키텍처 타입입니다: {self.arch_type.name}")

        try:
            self.model = ModelClass(self.config).to(self.device)
            self.model.eval()
            print("✅ 모델이 성공적으로 GPU에 로드되었습니다.")
        except torch.cuda.OutOfMemoryError:
            print("cuda OOM")
            self.model = None # 진행 불가 상태임을 명시
        except Exception as e:
            print(f"❌ 모델 설정 중 예상치 못한 오류 발생: {e}")
            self.model = None
        
        # -------------------- mask setting
        # self.max_len = self.config.ctx_window_dec
        # mask = torch.triu(torch.ones(self.max_len, self.max_len, device=self.device), diagonal=1).bool()
        # self.causal_mask = mask

    def _load_data(self, path, name, split):
        """Load our dataset for inference.

        The size of a work dataset must be bigger than batch size for proper
        experiments, and we carefully set that the dataset size of work is
        `brain.work.tmpl.util.INF_DATASET_SIZE`. In this respect, the proper
        data split to use differs across datasets.
        """
        return datasets.load_dataset(path, name, split=f"{split}[:{tmplutil.INF_DATASET_SIZE}]")
            
    def _prepare_data(self):
        """
        DataType enum에 따라 지정된 데이터셋을 로드하고 모델 입력으로 처리합니다.
        """
        if self.tokenizer is None:
            raise ValueError("오류: 데이터 처리를 위해 tokenizer가 필요합니다.")

        path, config, split = None, None, "test"  # 기본값 설정
    
        def format_prompt(sample):
            """각 샘플을 프롬프트 문자열로 변환하는 함수"""
            # FIXME: do case-analysis properly
            if self.data_type == DataTypeGpt.MMLU:
                choices = "".join([f"{chr(65+i)}. {choice}\n" for i, choice in enumerate(sample['choices'])])
                return f"Question: {sample['question']}\n\nChoices:\n{choices}Answer:"
            elif self.data_type in [DataTypeGpt.TRIVIAQA, DataTypeGpt.NQ]:
                return f"Question: {sample['question']}\nAnswer:"
            elif self.data_type == DataTypeGpt.GSM8K:
                return f"Question: {sample['question']}\nLet's think step by step."
            return ""

        if self.data_type == DataTypeGpt.MMLU:
            path, config, split = "cais/mmlu", "professional_law", "test"
        elif self.data_type == DataTypeGpt.TRIVIAQA:
            path, config, split = "mandarjoshi/trivia_qa", "rc.nocontext", "test"
        elif self.data_type == DataTypeGpt.NQ:
            path, config, split = "google-research-datasets/nq_open", None, "validation"
        elif self.data_type == DataTypeGpt.GSM8K:
            path, config, split = "openai/gsm8k", "main", "test"
        else:
            raise NotImplementedError(f"'{self.data_type.name}' 데이터셋 처리 로직이 구현되지 않았습니다.")
      
        def tokenize_fn(sample):
            prompt_text = format_prompt(sample)
            toks = self.tokenizer(
                prompt_text,
                add_special_tokens=True,
                return_attention_mask=True,
                truncation=True,
                max_length=self.config.ctx_window_dec,
            )
            return {"input_ids": toks["input_ids"], "attention_mask": toks["attention_mask"]}

        try:
            raw_dataset = self._load_data(path, name=config, split=split)
            
            # processed_inputs = []
            # for sample in tqdm(raw_dataset, desc=f"Processing {self.data_type.name}"):
            #     prompt_text = format_prompt(sample)
            #     input_ids_list = self.tokenizer.encode(prompt_text) 
            #     processed_inputs.append(torch.tensor(input_ids_list, device=self.device))
            # Avoid CUDA re-init in forked subprocesses: run map sequentially
            processed_inputs = raw_dataset.map(
                tokenize_fn,
                remove_columns=raw_dataset.column_names,
                desc=f"Tokenizing {self.data_type.name}",
                num_proc=None
            )

        except Exception as e:
            print(f"{self.data_type.name} 데이터셋 처리 중 오류 발생: {e}")
            # Fallback: process sequentially with simple loop
            try:
                processed_inputs = []
                for sample in tqdm(raw_dataset, desc=f"Processing {self.data_type.name} (fallback)"):
                    toks = self.tokenizer(
                        format_prompt(sample),
                        add_special_tokens=True,
                        return_attention_mask=True,
                        truncation=True,
                        max_length=self.config.ctx_window_dec,
                    )
                    processed_inputs.append({
                        "input_ids": toks["input_ids"],
                        "attention_mask": toks["attention_mask"],
                    })
            except Exception as e2:
                print(f"{self.data_type.name} 데이터셋 처리 fallback 도 실패: {e2}")
                return None

        print(f"--- 데이터 준비 완료: 총 {len(processed_inputs)}개 샘플 처리 ---")
        class CustomTextDataset(Dataset):
            def __init__(self, tokenized_data):
                self.data = tokenized_data
            def __len__(self):
                return len(self.data)
            def __getitem__(self, idx):
                item = self.data[idx]
                return torch.tensor(item["input_ids"], dtype=torch.long), torch.tensor(item["attention_mask"], dtype=torch.long)

        
        tensor_dataset = CustomTextDataset(processed_inputs)
        def collate_fn(batch):
            ids, attn = zip(*batch)
            pad_id = self.tokenizer.pad_token_id or self.tokenizer.eos_token_id
            input_ids = pad_sequence(ids, batch_first=True, padding_value=pad_id).long()
            attention_mask = pad_sequence(attn, batch_first=True, padding_value=0).long()
            return input_ids, attention_mask

        data_loader = DataLoader(
            tensor_dataset,
            batch_size=self.config.batch_size,
            collate_fn=collate_fn,
            shuffle=False,  # 추론 시에는 보통 섞지 않음
            num_workers=0,           # 메모리 복제 방지
            pin_memory=False, 
        )
        return processed_inputs, data_loader

    def run_speed_benchmark(self, prompt_length=100):
        """
        토큰 생성 속도를 측정합니다.
        """
        if prompt_length >= self.config.ctx_window_dec:
            print("오류: 초기 프롬프트 길이가 최대 길이보다 같거나 깁니다.")
            return None

        print(f"--- 최대 {self.config.ctx_window_dec}개 토큰, 초기 입력 {prompt_length}개로 속도 측정 시작 ---")
        self.model.eval() 

        generated_ids = torch.arange(prompt_length, dtype=torch.long).unsqueeze(0).to(self.device)

        with torch.no_grad():
            start_time = time.time()
            
            for _ in tqdm(range(self.config.ctx_window_dec - prompt_length - 1), desc="토큰 생성 중"):
                # seq_len = generated_ids.shape[1]
               
                seq_len = generated_ids.shape[1]
                # batch_size = generated_ids.shape[0]
                causal = torch.triu(torch.ones(seq_len, seq_len, device=self.device), 1).bool()
                # causal_mask = causal.unsqueeze(0).repeat(batch_size, 1, 1)
                mask = causal[:seq_len, :seq_len]
                # GPT 모델은 일반적으로 logits만 반환
                logits = self.model(generated_ids, mask=mask)
                next_token = torch.argmax(logits[:, -1, :], dim=-1).unsqueeze(-1)
                generated_ids = torch.cat([generated_ids, next_token], dim=1)

            end_time = time.time()

        total_time = end_time - start_time
        final_shape = generated_ids.shape
        num_generated = final_shape[1] - prompt_length
        tokens_per_sec = num_generated / total_time if total_time > 0 else 0
        
        return {
            "total_time": total_time,
            "tokens_generated": num_generated,
            "tokens_per_sec": tokens_per_sec,
            "final_shape": final_shape
        }
    
    def generate(self, input_ids: torch.Tensor, attention_mask: torch.Tensor = None, max_new_tokens: int = 256, stop_at_eos: bool = True):
        """
        하나의 입력(input_ids)에 대해 추론을 수행하여 새로운 토큰을 생성합니다.

        :param input_ids: 토큰화된 프롬프트 텐서. (예: tensor([[1, 2, 3]]))
        :param max_new_tokens: 생성할 최대 토큰 수
        :param stop_at_eos: EOS 토큰을 만나면 생성을 중단할지 여부
        :return: (생성된 전체 토큰 ID 텐서, 디코딩된 전체 텍스트)
        """
        self.model.eval()
        

        if attention_mask is not None:
            actual_lengths = attention_mask.sum(dim=1)
            trimmed_inputs = []
            for i in range(input_ids.shape[0]):
                trimmed_inputs.append(input_ids[i, -actual_lengths[i]:])
            # pad_sequence로 다시 배치로 만듦
            input_ids = pad_sequence(trimmed_inputs, batch_first=True, padding_value=self.tokenizer.pad_token_id)
            # attention_mask도 모두 1로 (패딩 없음)
            attention_mask = torch.ones_like(input_ids)

        generated_ids = input_ids.to(self.device)

        with torch.no_grad():
            for _ in range(max_new_tokens):
                generated_ids = archutil.crop_data_to_ctx_window(generated_ids, self.ctx_window_dec)

                seq_len = generated_ids.shape[1]
                batch_size = generated_ids.shape[0]
                causal = torch.triu(torch.ones(seq_len, seq_len, device=self.device), 1).bool()
                causal_mask = causal.unsqueeze(0).repeat(batch_size, 1, 1)

                # mask = self.causal_mask[:seq_len, :seq_len]

                # causal_mask = mask.unsqueeze(0).expand(batch_size, seq_len, seq_len)
                # expand 대신 repeat 사용: 배치 차원 브로드캐스팅으로 인한 크기 불일치 방지
                # causal_mask = mask.unsqueeze(0).repeat(batch_size, 1, 1)

                # attn_mask = attention_mask[:, :seq_len]  # (batch, seq_len)
                # attn_mask = attn_mask.unsqueeze(1).expand(self.config.batch_size, seq_len, seq_len)
                # final_mask = causal_mask | ~attn_mask
                # final_mask = final_mask.bool()
                
                logits = self.model(generated_ids, mask=causal_mask)
                
                next_token_logits = logits[:, -1, :]
                next_token = torch.argmax(next_token_logits, dim=-1).unsqueeze(-1)
                generated_ids = torch.cat([generated_ids, next_token], dim=1)


        # decoded_text = self.tokenizer.decode(generated_ids[0].tolist())
        # decoded_texts = [self.tokenizer.decode(ids.tolist()) for ids in generated_ids]
        return generated_ids #, decoded_texts
        
    def run_dataset_inference(self, data_loader, output_csv_path, max_new_tokens_per_sample=50):
        """
        준비된 전체 데이터셋에 대해 추론을 수행하고, 성능을 측정합니다.

        :param prepared_data: _prepare_data에서 반환된 토큰화된 프롬프트 텐서 리스트
        :param max_new_tokens_per_sample: 각 샘플마다 생성할 최대 토큰 수
        """
        total_samples = len(data_loader.dataset)
        total_tokens_generated = 0
        processed_samples = 0

        csv_file = None
        csv_writer = None
        if output_csv_path:
            try:
                # 파일을 쓰기 모드로 열고, csv writer 준비
                csv_file = open(output_csv_path, 'w', newline='', encoding='utf-8')
                csv_writer = csv.writer(csv_file, quoting=csv.QUOTE_ALL, escapechar='\\')
                # CSV 헤더 작성
                csv_writer.writerow(['input_prompt', 'generated_output'])
                print(f"\n--- 추론 결과를 '{output_csv_path}' 파일에 저장합니다. ---")
            except IOError as e:
                print(f"⚠️ 경고: CSV 파일을 열 수 없습니다. - {e}")
                output_csv_path = None # 저장 기능 비활성화
       
        use_cuda_timing = (isinstance(self.device, str) and self.device.startswith("cuda") and torch.cuda.is_available())
        gpu_time_total = 0.0
        for input_ids_batch, attention_mask_batch in tqdm(data_loader, desc="Dataset Batch Inference"):
            try :
                if use_cuda_timing:
                    start_event = torch.cuda.Event(enable_timing=True)
                    end_event = torch.cuda.Event(enable_timing=True)
                    start_event.record()
                generated_ids = self.generate(
                    input_ids_batch, 
                    attention_mask=attention_mask_batch,  # 모델이 지원하면
                    max_new_tokens=max_new_tokens_per_sample
                )
                if use_cuda_timing:
                    end_event.record(); torch.cuda.synchronize()
                    gpu_time_total += start_event.elapsed_time(end_event) / 1000.0

    
                # prompt_lengths = attention_mask_batch.sum(dim=1)
                # num_new_tokens = (generated_ids.shape[1] - prompt_lengths).sum()
                # total_tokens_generated += num_new_tokens.item()
                # processed_samples += input_ids_batch.shape[0]
                
                # prompt_texts = [self.tokenizer.decode(ids[:len], skip_special_tokens=True) for ids, len in zip(input_ids_batch, prompt_lengths)]
                # for prompt, full_output in zip(prompt_texts, decoded_texts):
                #     results_list.append({'input_prompt': prompt, 'generated_output': full_output})
                decoded_texts = [self.tokenizer.decode(ids.cpu().tolist()) for ids in generated_ids]
                prompt_lengths = attention_mask_batch.sum(dim=1)
                prompt_texts = [
                    self.tokenizer.decode(ids[:plen].tolist(), skip_special_tokens=True)
                    for ids, plen in zip(input_ids_batch, prompt_lengths)
                ]
                for prompt, full_output in zip(prompt_texts, decoded_texts):
                    if csv_writer:
                        csv_writer.writerow([prompt, full_output])

            except torch.cuda.OutOfMemoryError:
                print("cuda OOM")
                torch.cuda.empty_cache()
                if csv_file:
                    csv_file.close()
                return None
            except Exception as e:
                print(f"❌ 추론 실행 중 예상치 못한 오류 발생: {e}")
                return None



        total_tokens_generated_val = total_tokens_generated.item() if isinstance(total_tokens_generated, torch.Tensor) else total_tokens_generated
        tokens_per_sec = total_tokens_generated_val / gpu_time_total if gpu_time_total > 0 else 0
        avg_time_per_sample = gpu_time_total / processed_samples if processed_samples > 0 else 0

 
        results = {
            "dataset_name": self.data_type.name,
            "processed_samples": processed_samples,
            "total_samples": total_samples,
            "total_tokens_generated": total_tokens_generated,
            "total_inference_time_sec": round(gpu_time_total, 2),
            "avg_time_per_sample_sec": round(avg_time_per_sample, 3),
            "tokens_per_sec": round(tokens_per_sec, 2)
        }
        
        print("--- 측정 완료 ---")
        return results

def run(archtype, datatype, config, cuda_idx, seed):
    tmplutil.set_seed(seed)

    # work
    work_runner = GPTWork(arch_type=archtype, data_type=datatype, config=config, device=f"cuda:{cuda_idx}")
    if work_runner.model is None:
        print("모델 로딩에 실패하여 프로그램을 종료합니다.")
        return
    
    # data
    prepared_data, data_loader = work_runner._prepare_data()
    if data_loader is None:
        print("데이터 준비에 실패하여 프로그램을 종료합니다.")
        return

    # inference
    results = work_runner.run_dataset_inference(data_loader,output_csv_path='./res_gpt_inference.csv')
    if results is None:
        print("\n추론 과정에서 오류가 발생하여 벤치마크를 중단했습니다.")
    else:
        print("\n[최종 측정 결과]:", results)
        return results

    # Memory management: make sure to delete references to the objects
    del work_runner, prepared_data, data_loader, results

if __name__ == "__main__":

    # == GPT-1
    all_members_list = list(DataTypeGpt)
    # for member in all_members_list:
    datatype = all_members_list[1]
    archtype = ArchType.GPT3
    config = Config(
        vocab_size=50257,
        batch_size=8,
        ctx_window_enc=2048,
        ctx_window_dec=2048,
        d_emb=768,
        d_q=64,
        d_k=64,
        d_v=64,
        d_ff=3072,
        n_heads_enc=0,
        n_heads_dec_sa=12,
        n_heads_dec_ca=0,
        n_layers_enc=0,
        n_layers_dec=12,
        dropout_rate_enc=0.1,
        dropout_rate_dec=0.1
    )
    run(archtype, datatype, config, cuda_idx=0, seed=2025)
    # archtype = ArchType.GPT1
    # datatype = DataTypeGpt.MMLU
    # config = Config(
    #     vocab_size=40479,
    #     batch_size=8,
    #     ctx_window_enc=512,
    #     ctx_window_dec=512,
    #     d_emb=768,
    #     d_q=64,
    #     d_k=64,
    #     d_v=64,
    #     d_ff=3072,
    #     n_heads_enc=0,
    #     n_heads_dec_sa=12,
    #     n_heads_dec_ca=0,
    #     n_layers_enc=0,
    #     n_layers_dec=12,
    #     dropout_rate_enc=0.1,
    #     dropout_rate_dec=0.1
    # )

    # # == GPT-2
    # archtype = ArchType.GPT2
    # datatype = DataTypeGpt.MMLU
    # config = Config(
    #     vocab_size=50257,
    #     batch_size=8,
	# ctx_window_enc=1024,
    #     ctx_window_dec=1024,
    #     d_emb=768,
    #     d_q=64,
    #     d_k=64,
    #     d_v=64,
    #     d_ff=3072,
    #     n_heads_enc=0,
    #     n_heads_dec_sa=12,
    #     n_heads_dec_ca=0,
    #     n_layers_enc=0,
    #     n_layers_dec=12,
    #     dropout_rate_enc=0.1,
    #     dropout_rate_dec=0.1
    # )

    # # == GPT-3
    # archtype = ArchType.GPT3
    # datatype = DataTypeGpt.MMLU
    # config = Config(
    #     vocab_size=50257,
    #     batch_size=8,
    #     ctx_window_enc=2048,
    #     ctx_window_dec=2048,
    #     d_emb=768,
    #     d_q=64,
    #     d_k=64,
    #     d_v=64,
    #     d_ff=3072,
    #     n_heads_enc=0,
    #     n_heads_dec_sa=12,
    #     n_heads_dec_ca=0,
    #     n_layers_enc=0,
    #     n_layers_dec=12,
    #     dropout_rate_enc=0.1,
    #     dropout_rate_dec=0.1
    # )

    # run(archtype, datatype, config, cuda_idx=0, seed=2025)

