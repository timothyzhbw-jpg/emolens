#!/usr/bin/env python3
"""用 Adaption Labs 的 Adaptive Data API 把英文评测集「本地化」成别的英语地区的说法，测 EmoLens 换个口音还认不认得出潜台词。

为什么：eval/en.jsonl 是按美式英语写的。英国人的反话、澳洲人的玩笑、印度英语的客气话，表面意思和真实想法的差距都不一样。
Adaption 的 localize 接口会把每条对话改写成目标国家/语言的说法（不只是翻译，还按当地习惯改），
标注（期望的情绪、信号）保持不变，于是同一套期望就能检验 EmoLens 在不同英语地区的表现。

用法（需要 Adaption 的 API Key；云端会话的网络出不去，在自己电脑上跑）：

    pip install adaption
    export ADAPTION_API_KEY=...

    # 1. 只报价，不花钱：上传评测集，问 localize 要多少 credits
    python3 scripts/adaption_localize_eval.py estimate

    # 2. 真跑：默认本地化到英国、澳大利亚、印度、加拿大，结果写到 eval/en.localized.jsonl
    python3 scripts/adaption_localize_eval.py run --countries GB AU IN CA

    # 3. 用 EmoLens 跑新评测集并打分（macOS 上）
    swift run EmoLens --eval eval/en.localized.jsonl results.jsonl --language en
    python3 scripts/score_eval.py eval/en.localized.jsonl results.jsonl

    # 只想看看要上传的数据长什么样（不联网）：
    python3 scripts/adaption_localize_eval.py prepare

上传的只有 eval/en.jsonl 里虚构的对话，不碰任何真实聊天，也不碰联系人记忆。
"""
import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "eval" / "en.jsonl"
UPLOAD = ROOT / "eval" / ".adaption-upload.jsonl"
OUTPUT = ROOT / "eval" / "en.localized.jsonl"
STATE = ROOT / "eval" / ".adaption-state.json"

# prompt 用和 EmoLens 给模型看的一样的框架：本地化后再按这个格式拆回 relationship / context / text。
RELATIONSHIP = "Relationship: "
LATEST = "Analyze only their latest message:"


def to_row(item):
    lines = []
    if item.get("relationship"):
        lines.append(RELATIONSHIP + item["relationship"])
    lines.append("Chat log:")
    lines += [line for line in item.get("context", "").splitlines() if line.strip()]
    lines += ["", LATEST, "Them: " + item["text"]]
    # completion 只放期望的标签和 id，本地化时应当原样保留；拆回来时以它为准。
    completion = json.dumps({"id": item["id"], "category": item.get("category"), "expect": item.get("expect", {})},
                            ensure_ascii=False)
    return {"prompt": "\n".join(lines), "completion": completion}


def from_row(prompt, completion):
    """把（可能被改写过的）prompt 拆回评测项；格式不对就返回 None，宁可丢掉也不要错标。"""
    try:
        meta = json.loads(completion)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(meta, dict) or "expect" not in meta:
        return None
    head, sep, tail = prompt.partition(LATEST)
    latest = tail.strip()
    if not sep or not latest.startswith("Them:"):
        return None
    relationship, context = None, []
    for line in head.splitlines():
        line = line.strip()
        if line.startswith(RELATIONSHIP):
            relationship = line[len(RELATIONSHIP):].strip()
        elif line.startswith(("Me:", "Them:")):
            context.append(line)
    return {"relationship": relationship, "context": "\n".join(context), "text": latest[len("Them:"):].strip(),
            "category": meta.get("category"), "expect": meta["expect"], "source_id": meta.get("id")}


def prepare():
    items = [json.loads(line) for line in SOURCE.read_text(encoding="utf-8").splitlines() if line.strip()]
    rows = [to_row(item) for item in items]
    assert all(from_row(r["prompt"], r["completion"]) for r in rows), "round trip failed"
    UPLOAD.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    print(f"{len(rows)} rows → {UPLOAD.relative_to(ROOT)}")
    return rows


def client():
    try:
        from adaption import Adaption
    except ImportError:
        sys.exit("pip install adaption")
    if not os.environ.get("ADAPTION_API_KEY"):
        sys.exit("Set ADAPTION_API_KEY first.")
    return Adaption()


def wait(api, dataset_id, label):
    """轮询状态直到 succeeded / failed。"""
    while True:
        status = api.datasets.get_status(dataset_id)
        progress = status.progress.percent if status.progress and status.progress.percent is not None else "?"
        print(f"  {label} {dataset_id}: {status.status} ({progress}%)", flush=True)
        if status.status == "succeeded":
            return status
        if status.status == "failed":
            detail = status.error_data.message if status.error_data else "unknown error"
            sys.exit(f"{label} failed: {detail}")
        if status.status == "awaiting_input":
            sys.exit(f"{label} is waiting for input; check it in the Adaption dashboard.")
        time.sleep(10)


def upload(api):
    """上传评测集，按 raw 模式直接存成 prompt / completion 两列（不跑改写，不额外花 credits）。同一份文件只传一次。"""
    prepare()
    data = UPLOAD.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if state.get("sha256") == digest and state.get("dataset_id"):
        print(f"Reusing uploaded dataset {state['dataset_id']}")
        return state["dataset_id"]
    import httpx
    created = api.datasets.create(source={
        "name": "emolens-eval-en.jsonl", "file_format": "jsonl", "processing_mode": "raw",
        "column_mapping": {"prompt": "prompt", "completion": "completion"},
    })
    instructions = created.upload_instructions
    if instructions is None:
        sys.exit("Adaption returned no upload URL")
    response = httpx.request(instructions.method or "PUT", instructions.url, content=data, timeout=120)
    response.raise_for_status()
    api.datasets.upload.complete_by_id(created.dataset_id, file_size_bytes=len(data), sha256=digest)
    wait(api, created.dataset_id, "upload")
    STATE.write_text(json.dumps({"sha256": digest, "dataset_id": created.dataset_id}, indent=2))
    return created.dataset_id


def localize(api, dataset_id, countries, sample_rate, estimate):
    pairs = [{"country": country.upper(), "language": "en"} for country in countries]
    extra = {} if estimate else {"idempotency_key": f"emolens-{dataset_id}-{'-'.join(countries)}-{sample_rate}"}
    response = api.datasets.localize(dataset_id, sample_rate=sample_rate, pairs=pairs, estimate=estimate, **extra)
    print(f"Localize to {', '.join(countries)} at sample rate {sample_rate}: "
          f"~{response.estimated_new_rows:.0f} new rows, ~{response.estimated_credits_consumed:.0f} credits"
          + (" (estimate only, nothing charged)" if estimate else ""))
    return response


def pick(row, *keys):
    for key in keys:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return None


def download(api, dataset_id):
    raw = api.datasets.download(dataset_id, file_format="jsonl").read().decode("utf-8")
    originals = {json.loads(line)["prompt"] for line in UPLOAD.read_text(encoding="utf-8").splitlines() if line.strip()}
    items, dropped = [], 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        prompt = pick(row, "enhanced_prompt", "prompt", "original_prompt")
        completion = pick(row, "original_completion", "completion", "enhanced_completion")
        if prompt is None or prompt in originals:
            continue   # 新数据集里也带着原来的行，跳过
        item = from_row(prompt, completion) if completion else None
        if item is None:
            dropped += 1
            continue
        # EmoLens --eval 要求 id 是整数；原来的编号放在 source_id，方便对照
        item["id"] = len(items) + 1
        locale = "-".join(str(row[k]) for k in ("country", "language") if row.get(k))
        if locale:
            item["locale"] = locale
        items.append(item)
    OUTPUT.write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items), encoding="utf-8")
    print(f"{len(items)} localized items → {OUTPUT.relative_to(ROOT)}" + (f" ({dropped} dropped: format changed)" if dropped else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["prepare", "estimate", "run"])
    parser.add_argument("--countries", nargs="+", default=["GB", "AU", "IN", "CA"])
    parser.add_argument("--sample-rate", type=float, default=1.0, help="share of rows to localize per country (0-1)")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
        return
    api = client()
    dataset_id = upload(api)
    if args.command == "estimate":
        localize(api, dataset_id, args.countries, args.sample_rate, estimate=True)
        return
    response = localize(api, dataset_id, args.countries, args.sample_rate, estimate=False)
    if not response.dataset_id:
        sys.exit("Adaption did not return a dataset id")
    wait(api, response.dataset_id, "localize")
    download(api, response.dataset_id)


if __name__ == "__main__":
    main()
