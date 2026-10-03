#!/usr/bin/env python3
"""给 `EmoLens --eval` 的结果打分。

    swift run EmoLens --eval eval/en.jsonl results.jsonl --language en
    python3 scripts/score_eval.py eval/en.jsonl results.jsonl

输入每行的 expect 写期望：emotion / consistency 是可接受的英文标签列表，flags 是必须报出的信号，
absent 是绝不能报的信号（比如日常夸张不能报自伤），memory 表示应当提出「要记住吗」。
EmoLens 的结果里情绪等字段是中文规范值，这里换回英文再比。只用标准库。
"""
import json
import sys
from collections import defaultdict

# 和 Sources/EmoLensCore/Language.swift 里的 Vocabulary 一致
EMOTIONS = {"开心": "happy", "平静": "calm", "亲昵": "affectionate", "难过": "sad", "委屈": "hurt",
            "生气": "angry", "失望": "disappointed", "焦虑": "anxious", "冷淡": "cold", "尴尬": "embarrassed"}
CONSISTENCY = {"一致": "sincere", "反话": "sarcastic", "撒娇": "playful", "没说完": "holding back"}
THRESHOLD = 0.5


def load(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def main(expected_path, results_path):
    items, results = load(expected_path), load(results_path)
    if len(items) != len(results):
        sys.exit(f"{expected_path} has {len(items)} items but {results_path} has {len(results)} results")

    checks = defaultdict(lambda: [0, 0])          # dimension -> [passed, total]
    by_category = defaultdict(lambda: [0, 0])
    flag_hits = defaultdict(lambda: [0, 0])       # flag -> [caught, should catch]
    flag_false = defaultdict(lambda: [0, 0])      # flag -> [wrongly raised, must not raise]
    misses = []

    for item, result in zip(items, results):
        expect = item.get("expect", {})
        category = item.get("category", "other")
        if result.get("error"):
            checks["errors"][1] += 1
            misses.append((item["id"], "analysis failed"))
            continue
        flags = {k for k, v in (result.get("flags") or {}).items() if v >= THRESHOLD}
        outcomes = []
        if "emotion" in expect:
            got = EMOTIONS.get(result.get("emotion"), result.get("emotion"))
            outcomes.append(("emotion", got in expect["emotion"], f"emotion {got} not in {expect['emotion']}"))
        if "consistency" in expect:
            got = CONSISTENCY.get(result.get("consistency"), result.get("consistency"))
            outcomes.append(("consistency", got in expect["consistency"], f"consistency {got} not in {expect['consistency']}"))
        for flag in expect.get("flags", []):
            flag_hits[flag][1] += 1
            flag_hits[flag][0] += flag in flags
            outcomes.append(("required flags", flag in flags, f"missed {flag}"))
        for flag in expect.get("absent", []):
            flag_false[flag][1] += 1
            flag_false[flag][0] += flag in flags
            outcomes.append(("forbidden flags", flag not in flags, f"wrongly raised {flag}"))
        if "memory" in expect:
            got = bool(result.get("memoryNote"))
            outcomes.append(("memory note", got == expect["memory"], "no memory note" if expect["memory"] else "unexpected memory note"))
        for dimension, passed, why in outcomes:
            checks[dimension][0] += passed
            checks[dimension][1] += 1
            if not passed:
                misses.append((item["id"], why))
        all_passed = all(p for _, p, _ in outcomes)
        by_category[category][0] += all_passed
        by_category[category][1] += 1

    pct = lambda a, b: f"{a}/{b} ({100 * a / b:.0f}%)" if b else "-"
    print("## By check")
    for dimension, (a, b) in sorted(checks.items()):
        print(f"- {dimension}: {pct(a, b)}")
    print("\n## Required signals caught")
    for flag, (a, b) in sorted(flag_hits.items()):
        print(f"- {flag}: {pct(a, b)}")
    print("\n## Signals raised where they must not be (lower is better)")
    for flag, (a, b) in sorted(flag_false.items()):
        print(f"- {flag}: {pct(a, b)}")
    print("\n## Items fully correct, by category")
    for category, (a, b) in sorted(by_category.items()):
        print(f"- {category}: {pct(a, b)}")
    if misses:
        print("\n## Misses")
        for item_id, why in misses:
            print(f"- #{item_id}: {why}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
