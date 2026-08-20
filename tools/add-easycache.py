#!/usr/bin/env python3
"""Add EasyCache node to H3 workflow JSON files (those without SpectrumApplyMiniMaxH3).

EasyCache is mutually exclusive with Spectrum.  Insert it between the last
model-transform node and the KSampler, then rewrite KSampler.model to
point at the new EasyCache node.

Parameters follow pepikir's research: end_percent=0.90 avoids the final-step
quality degradation seen with 0.95.
"""
import json, glob, os, sys

EASYCACHE_NODE = {
    "class_type": "EasyCache",
    "inputs": {
        "model": None,  # filled per-file
        "reuse_threshold": 0.10,
        "start_percent": 0.15,
        "end_percent": 0.90,
        "verbose": False,
    },
}

SKIP_PREFIXES = ("h3_workflow_qimage", "h3_workflow_zimage", "h3_workflow_src")
SPECTRUM_PATTERN = "SpectrumApplyMiniMaxH3"


def find_k_sampler(prompt: dict) -> str | None:
    """Return the node id of the KSampler node, or None."""
    for nid, node in prompt.items():
        if node.get("class_type") == "KSampler":
            return nid
    return None


def find_model_source(prompt: dict, ksampler_id: str) -> str | None:
    """Return the node id that feeds model into the KSampler."""
    model_input = prompt[ksampler_id]["inputs"].get("model")
    if isinstance(model_input, list) and len(model_input) == 2:
        return str(model_input[0])
    return None


def next_node_id(prompt: dict) -> str:
    """Return the next unused integer node id as a string."""
    try:
        ids = [int(k) for k in prompt.keys() if k.isdigit()]
        return str(max(ids) + 1)
    except ValueError:
        return "99"


def process_file(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    prompt = data.get("prompt")
    if not prompt:
        return False

    # Skip if Spectrum already present (mutually exclusive with EasyCache)
    for node in prompt.values():
        if node.get("class_type") == SPECTRUM_PATTERN:
            return False

    # Skip if EasyCache already present
    for node in prompt.values():
        if node.get("class_type") == "EasyCache":
            return False

    ks_id = find_k_sampler(prompt)
    if not ks_id:
        return False

    model_source = find_model_source(prompt, ks_id)
    if not model_source:
        return False

    # Create EasyCache node
    ec_id = next_node_id(prompt)
    ec_node = json.loads(json.dumps(EASYCACHE_NODE))
    ec_node["inputs"]["model"] = [model_source, 0]

    # Insert into prompt
    prompt[ec_id] = ec_node

    # Rewire KSampler.model → EasyCache
    prompt[ks_id]["inputs"]["model"] = [ec_id, 0]

    # Write back
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

    return True


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(repo, "h3_workflow_*.json")))

    modified = []
    skipped_spectrum = []
    skipped_other = []

    for path in files:
        basename = os.path.basename(path)
        if any(basename.startswith(p) for p in SKIP_PREFIXES):
            skipped_other.append(basename)
            continue

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            prompt = data.get("prompt", {})
            has_spectrum = any(
                n.get("class_type") == SPECTRUM_PATTERN for n in prompt.values()
            )
        except Exception:
            skipped_other.append(basename)
            continue

        if has_spectrum:
            skipped_spectrum.append(basename)
            continue

        if process_file(path):
            modified.append(basename)
        else:
            skipped_other.append(basename)

    print(f"Modified ({len(modified)}):")
    for f in modified:
        print(f"  + {f}")
    print(f"\nSkipped - Spectrum present ({len(skipped_spectrum)}):")
    for f in skipped_spectrum:
        print(f"  - {f}")
    print(f"\nSkipped - other ({len(skipped_other)}):")
    for f in skipped_other:
        print(f"  - {f}")


if __name__ == "__main__":
    main()
