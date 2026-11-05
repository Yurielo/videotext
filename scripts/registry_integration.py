#!/usr/bin/env python3
"""VideoText adapter for the authoritative Four-Product Architecture registry.

It prepares a verified SeminarText bundle and records/publishes an already
DELIVERED VideoText activation. It never builds, installs, accepts, or deploys.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid


class Rejected(ValueError):
    pass


def require(value, message):
    if not value:
        raise Rejected(message)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    return json.loads(Path(path).read_bytes())


def now():
    return datetime.now(timezone.utc).isoformat()


def git(root, *arguments):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def regular(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"required regular file missing: {path}")
    return path


def contained(path, root, label):
    require(Path(path).resolve().is_relative_to(Path(root).resolve()), f"{label} escapes its declared root")
    return Path(path)


def same_provider_activation(left, right):
    """Compare the immutable provider activation, not an unrelated registry head.

    The registry can accept BookText/Integra events after a bundle was prepared.
    That must not invalidate an unchanged current SeminarText activation, while a
    changed SeminarText event, release, proof, or component inventory still does.
    """
    left, right = dict(left), dict(right)
    left.pop("central_head", None)
    right.pop("central_head", None)
    return left == right


def retain(path, data):
    """Write evidence atomically without ever replacing a different record."""
    path = Path(path)
    require(not path.is_symlink(), f"evidence path is a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        require(path.read_bytes() == data, f"refusing to overwrite retained evidence: {path}")
        return
    staged = path.with_name(path.name + ".staged-" + uuid.uuid4().hex)
    try:
        with staged.open("xb") as target:
            target.write(data); target.flush(); os.fsync(target.fileno())
        try:
            os.link(staged, path)
        except FileExistsError:
            require(path.read_bytes() == data, f"concurrent evidence differs: {path}")
    finally:
        staged.unlink(missing_ok=True)


@contextmanager
def lock(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".four-product-registry.lock").open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def central_module(root):
    root = Path(root).resolve()
    origin = git(root, "remote", "get-url", "origin").removesuffix(".git")
    require(origin in {"https://github.com/Yurielo/four-product-architecture",
                       "git@github.com:Yurielo/four-product-architecture"}, "unexpected central registry origin")
    require(not git(root, "diff", "HEAD", "--", "registry.py", "schemas/registry.schema.json"),
            "central publisher/schema has local modifications")
    remote = git(root, "ls-remote", "--exit-code", "origin", "refs/heads/main").split()
    require(len(remote) == 2 and remote[1] == "refs/heads/main", "ambiguous central remote main")
    git(root, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", remote[0])
    for relative in ("registry.py", "schemas/registry.schema.json"):
        committed = subprocess.run(["git", "-C", str(root), "show", f"{remote[0]}:{relative}"],
                                   capture_output=True, check=True).stdout
        require((root / relative).read_bytes() == committed,
                f"local central {relative} differs from current remote main")
    spec = importlib.util.spec_from_file_location("four_product_registry", root / "registry.py")
    module = importlib.util.module_from_spec(spec)
    require(spec.loader is not None, "central registry module is unavailable")
    spec.loader.exec_module(module)
    return module


def video_remote_main(root):
    line = git(root, "ls-remote", "--exit-code", "origin", "refs/heads/main").split()
    require(len(line) == 2 and line[1] == "refs/heads/main", "ambiguous VideoText remote main")
    git(root, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", line[0])
    return line[0]


def central_state(root, central):
    head = central.remote_head(root)
    state = central.decode(central.at(root, head, "registry.json"))
    schema = central.decode(central.at(root, head, central.SCHEMA))
    central.validate(state, schema, lambda path: central.at(root, head, path))
    return head, state


def central_event(root, central, state, identity):
    event = next((item for item in state["history"] if item["event_id"] == identity), None)
    require(event is not None, "central current pointer does not identify an event")
    return event


def seminartext_dependency(root, central, activation_event=None):
    head, state = central_state(root, central)
    identity = activation_event or state["products"]["seminartext"]["current"]
    require(identity is not None, "SeminarText has no centrally registered activation; refusing stale bundle fallback")
    event = central_event(root, central, state, identity)
    require(event["product"] == "seminartext" and event["action"] in {"activate", "rollback"},
            "central SeminarText current event is invalid")
    proof_ref = next((ref for ref in event["evidence"]), None)
    require(proof_ref is not None, "SeminarText activation has no retained evidence")
    proof = central.decode(central.at(root, head, proof_ref["path"]))
    require(proof.get("kind") == "native_activation" and proof.get("status") == "SUCCEEDED"
            and proof.get("subject_sha256") == central.subject_hash(event),
            "SeminarText activation proof is not bound to the current event")
    installation = proof.get("native_evidence", {}).get("installation")
    require(isinstance(installation, dict), "SeminarText proof lacks installation identity")
    components = installation.get("components")
    require(isinstance(components, list) and components, "SeminarText proof lacks installed component inventory")
    require(installation.get("source_commit") == event["release"]["source_commit"],
            "SeminarText release/source identity differs from native proof")
    artifacts = {item["role"]: item for item in event["release"]["artifacts"]}
    normalized = []
    for component in components:
        role, relative, digest = component.get("id"), component.get("repository_path"), component.get("sha256")
        artifact = artifacts.get(role)
        require(isinstance(role, str) and isinstance(relative, str) and isinstance(digest, str),
                "SeminarText component identity is incomplete")
        require(Path(relative).is_relative_to(Path(".")) and not Path(relative).is_absolute()
                and ".." not in Path(relative).parts, "SeminarText component path is unsafe")
        require(artifact is not None and artifact["source_commit"] == event["release"]["source_commit"]
                and artifact["digest"] == {"algorithm": "sha256-file", "value": digest},
                f"SeminarText central artifact does not bind component {role}")
        normalized.append({"role": role, "path": relative, "sha256": digest})
    require(set(artifacts) == {item["role"] for item in normalized},
            "SeminarText artifact inventory differs from retained native proof")
    return {"schema_version": 1, "kind": "seminartext-bundled-dependency",
            "central_head": head, "activation_event": event["event_id"],
            "activation_evidence": proof_ref, "release": event["release"],
            "components": sorted(normalized, key=lambda item: item["path"]),
            "dependency": {"provider": "seminartext", "role": "selected-timing-runtime", "mode": "bundled",
                           "source_commit": event["release"]["source_commit"],
                           "artifacts": event["release"]["artifacts"],
                           "manifest": "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"}}


def resolve(registry_root):
    central = central_module(registry_root)
    return seminartext_dependency(Path(registry_root), central)


def prepare(registry_root, material_root, output):
    """Make a bundle only from exact registered material; no source/HEAD fallback."""
    dependency = resolve(registry_root)
    material_root, output = Path(material_root).resolve(), Path(output).resolve()
    require(material_root.is_dir() and not material_root.is_symlink(), "SeminarText material root is unavailable")
    if output.exists():
        manifest = output / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"
        require(manifest.is_file() and same_provider_activation(read(manifest), dependency),
                "prepared SeminarText bundle already represents a different activation")
        verify_bundle(output, dependency)
        return dependency
    staged = output.with_name(output.name + ".staged-" + uuid.uuid4().hex)
    try:
        staged.mkdir(parents=True)
        for component in dependency["components"]:
            source, target = regular(material_root / component["path"]), staged / component["path"]
            contained(source, material_root, "SeminarText material component")
            require(sha256(source.read_bytes()) == component["sha256"],
                    f"SeminarText material differs from registered component {component['role']}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        retain(staged / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json", encode(dependency))
        verify_bundle(staged, dependency)
        os.rename(staged, output)
    except Exception:
        shutil.rmtree(staged, ignore_errors=True)
        raise
    return dependency


def verify(registry_root, bundle):
    dependency = resolve(registry_root)
    verify_bundle(bundle, dependency)
    return dependency


def verify_bundle(bundle, dependency):
    bundle = Path(bundle)
    for component in dependency["components"]:
        path = regular(bundle / component["path"])
        contained(path, bundle, "prepared SeminarText component")
        require(sha256(path.read_bytes()) == component["sha256"],
                f"prepared SeminarText bundle changed: {component['role']}")
    executable = regular(bundle / "seminartext")
    require(os.access(executable, os.X_OK), "prepared SeminarText CLI is not executable")
    require(same_provider_activation(read(bundle / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"), dependency),
            "prepared SeminarText metadata differs from activation")


def parse_evidence(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        # release_gate.sh uses bash %q. shlex decodes that one shell word
        # without evaluating operators, variables, or command substitutions.
        words = shlex.split(value, posix=True)
        require(len(words) == 1, f"invalid release evidence value for {key}")
        values[key] = words[0]
    return values


def evidence_time(value):
    try:
        return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).isoformat()
    except ValueError as error:
        raise Rejected("release evidence completed_at is not a UTC compact timestamp") from error


def file_list_digest(path):
    path = Path(path)
    rows = []
    for item in sorted((entry for entry in path.rglob("*") if entry.is_file() and not entry.is_symlink()),
                       key=lambda entry: str(entry.relative_to(path))):
        rows.append(f"{sha256(item.read_bytes())}  ./{item.relative_to(path)}\n".encode())
    return sha256(b"".join(rows))


def delivery_receipt(root, registry_root, release_evidence, owner_pass_ref, installed_app, output,
                     native_delivery=None):
    """Record only the existing chain's final native facts, then retain them."""
    root, installed_app, output = Path(root).resolve(), Path(installed_app).resolve(), Path(output).resolve()
    values = parse_evidence(release_evidence)
    require(values.get("status") == "PASS", "release evidence is not PASS")
    required = ("source_commit", "candidate_sha256", "seminartext_dependency_sha256",
                "seminartext_dependency_manifest", "candidate_version", "candidate_build")
    require(all(values.get(name) for name in required), "release evidence lacks a completed delivery chain")
    require(owner_pass_ref.startswith("https://"), "Owner PASS reference must be an immutable URL")
    require(native_delivery is not None, "native post-owner delivery receipt is required")
    main_head = video_remote_main(root)
    require(git(root, "merge-base", "--is-ancestor", values["source_commit"], main_head) == "",
            "accepted VideoText source is not merged on main")
    require(installed_app.is_dir() and not installed_app.is_symlink(), "installed VideoText app is unavailable")
    installed_digest = file_list_digest(installed_app)
    if native_delivery is not None:
        native_delivery = Path(native_delivery).resolve()
        native = read(native_delivery)
        require(native.get("kind") == "videotext-native-post-owner-delivery"
                and native.get("status") == "DELIVERED" and native.get("prState") == "MERGED"
                and native.get("mergeTreeEqualsAcceptedHead") is True,
                "native post-owner delivery is incomplete")
        require(native.get("acceptedHead") == values["source_commit"],
                "native delivery accepted a different source")
        require(native.get("candidatePath") == values.get("candidate_path")
                and native.get("contentDigest") == values["candidate_sha256"]
                and native.get("installedContentDigest") == installed_digest
                and installed_digest == values["candidate_sha256"],
                "native delivery differs from accepted candidate")
        require(Path(native.get("installedPath", "")).resolve() == installed_app,
                "native delivery identifies another installed app")
        require(native.get("postInstallLifecycle") == "PASS" and native.get("codesignStrictDeep") == "PASS",
                "native post-install verification did not pass")
        require(native.get("installedVersion") == values["candidate_version"]
                and native.get("installedBuild") == values["candidate_build"],
                "native installed version differs from release evidence")
        candidate = Path(native["candidatePath"])
        require(candidate.is_dir() and file_list_digest(candidate) == installed_digest,
                "accepted Candidate is missing or its content changed")
        owner_receipt = Path(native.get("ownerPassReceipt", ""))
        require(regular(owner_receipt) and sha256(owner_receipt.read_bytes()) == native.get("ownerPassReceiptSha256"),
                "native Owner PASS receipt is missing or changed")
        owner = read(owner_receipt)
        require(owner.get("status") == "PASS" and owner.get("acceptedHead") == values["source_commit"]
                and owner.get("candidatePath") == str(candidate)
                and owner.get("candidatePathIndependentContentSha256") == installed_digest,
                "Owner PASS does not bind the accepted Candidate")
        require(git(root, "merge-base", "--is-ancestor", native["mergeCommit"], main_head) == "",
                "native merge commit is not on main")
        require(git(root, "merge-base", "--is-ancestor", values["source_commit"], native["mergeCommit"]) == "",
                "native merge does not contain accepted source")
        require(git(root, "rev-parse", f"{values['source_commit']}^{{tree}}") ==
                git(root, "rev-parse", f"{native['mergeCommit']}^{{tree}}"),
                "native merge tree differs from accepted source")
        delivered_at = datetime.fromisoformat(native["recordedAt"]).astimezone(timezone.utc).isoformat()
        smoke_ref = native["postInstallLifecycleLog"]
        require(regular(smoke_ref) and sha256(Path(smoke_ref).read_bytes()) == native.get("postInstallLifecycleLogSha256"),
                "native post-install lifecycle log is missing or changed")
        native_reference = str(native_delivery)
    dependency_path = Path(values["seminartext_dependency_manifest"])
    dependency = read(dependency_path)
    require(sha256(dependency_path.read_bytes()) == values["seminartext_dependency_sha256"],
            "release evidence dependency manifest hash differs")
    registered_dependency = seminartext_dependency(registry_root, central_module(registry_root),
                                                   dependency.get("activation_event"))
    verify_bundle(dependency_path.parent, registered_dependency)
    require(same_provider_activation(dependency, registered_dependency),
            "release evidence dependency differs from registered SeminarText activation")
    bundled_manifest = installed_app / "Contents/Resources/SeminarText/FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"
    require(regular(bundled_manifest) and sha256(bundled_manifest.read_bytes()) == values["seminartext_dependency_sha256"],
            "installed app carries another SeminarText dependency")
    verify_bundle(bundled_manifest.parent, dependency)
    bundled_dependency = {"provider": "seminartext", "role": "selected-timing-runtime", "mode": "bundled",
                          "source_commit": dependency["release"]["source_commit"],
                          "artifacts": [{"role": component["role"],
                                         "location": str(bundled_manifest.parent / component["path"]),
                                         "source_commit": dependency["release"]["source_commit"],
                                         "digest": {"algorithm": "sha256-file", "value": component["sha256"]}}
                                        for component in dependency["components"]],
                          "manifest": str(bundled_manifest)}
    receipt = {"schema_version": 1, "product": "videotext", "status": "DELIVERED",
               "delivered_at": delivered_at, "owner_pass_reference": owner_pass_ref,
               "source_commit": values["source_commit"], "release_gate_evidence": str(Path(release_evidence).resolve()),
               "native_delivery_evidence": native_reference,
               "version": values["candidate_version"], "build": values["candidate_build"],
               "installed_app": str(installed_app), "installed_app_sha256": installed_digest,
               "post_install_smoke": {"status": "PASS", "reference": smoke_ref},
               "seminartext_dependency": dependency, "bundled_dependency": bundled_dependency}
    retain(output, encode(receipt))
    return receipt


def publication_event(registry_root, receipt, outbox):
    central = central_module(registry_root)
    head, state = central_state(Path(registry_root), central)
    require(receipt.get("product") == "videotext" and receipt.get("status") == "DELIVERED", "delivery receipt is incomplete")
    dependency = receipt["seminartext_dependency"]
    bundled = receipt["bundled_dependency"]
    release = {"native_ref": receipt["native_delivery_evidence"], "version": receipt["version"],
               "build": receipt["build"], "source_commit": receipt["source_commit"],
               "artifacts": [{"role": "installed-app", "location": receipt["installed_app"],
                              "source_commit": receipt["source_commit"],
                              "digest": {"algorithm": "sha256-file-list-v1", "value": receipt["installed_app_sha256"]}}]}
    outbox = Path(outbox)
    retained_event = outbox / "publication-event.json"
    retained_proof = outbox / "publication-evidence.json"
    pending = outbox / "publication-pending.json"
    if pending.exists():
        sealed = read(pending)
        require(set(sealed) == {"event", "proof"}, "retained pending publication is invalid")
        retain(retained_proof, central.encode(sealed["proof"]))
        retain(retained_event, central.encode(sealed["event"]))
    if retained_event.exists() or retained_proof.exists():
        require(retained_event.is_file() and retained_proof.is_file(), "publication outbox is incomplete")
        event, proof = central.decode(retained_event.read_bytes()), central.decode(retained_proof.read_bytes())
        require(event.get("product") == "videotext", "retained publication event has wrong product")
        require(event.get("release") == release and event.get("target") == "local-primary"
                and event.get("activated_at") == receipt["delivered_at"],
                "retained publication event differs from native delivery")
        require(event.get("release", {}).get("source_commit") == receipt["source_commit"],
                "retained publication event has wrong release")
        require(event.get("dependencies") == [bundled], "retained publication event has wrong dependency")
        require(event.get("event_id") == central.event_id(event), "retained publication event identity changed")
        require(proof.get("kind") == "native_activation" and proof.get("status") == "SUCCEEDED", "retained publication proof failed")
        require(proof.get("native_evidence") == receipt, "retained publication proof has wrong native receipt")
        require(proof.get("subject_sha256") == central.subject_hash(event), "retained publication proof has wrong subject")
        require(len(event.get("evidence", [])) == 1 and event["evidence"][0].get("sha256") == sha256(retained_proof.read_bytes()),
                "retained publication proof identity changed")
        return central, head, event
    # A delivered consumer retains its verified provider pin even when the
    # provider subsequently activates another release. The central registry
    # reports UPDATE_REQUIRED without rewriting historical dependency identity.
    previous = state["products"]["videotext"]["current"]
    old = central_event(registry_root, central, state, previous) if previous else None
    event = {"product": "videotext", "generation": old["generation"] + 1 if old else 1,
             "predecessor": previous, "action": "activate", "rollback_of": None,
             "target": "local-primary", "activated_at": receipt["delivered_at"], "recorded_at": receipt["delivered_at"],
             "release": release, "dependencies": [bundled]}
    proof = {"kind": "native_activation", "status": "SUCCEEDED", "subject_sha256": central.subject_hash(event),
             "native_reference": receipt["native_delivery_evidence"], "native_evidence": receipt}
    payload = central.encode(proof)
    path = "evidence/videotext-activation-" + sha256(payload) + ".json"
    event["evidence"] = [{"path": path, "sha256": sha256(payload)}]
    event["event_id"] = central.event_id(event)
    retain(pending, central.encode({"event": event, "proof": proof}))
    retain(outbox / "publication-evidence.json", payload)
    retain(outbox / "publication-event.json", central.encode(event))
    return central, head, event


def publish(registry_root, receipt_path, outbox):
    outbox = Path(outbox)
    with lock(outbox):
        receipt = read(receipt_path)
        delivery_receipt(Path(__file__).resolve().parents[1], registry_root,
                         receipt["release_gate_evidence"], receipt["owner_pass_reference"],
                         receipt["installed_app"], receipt_path,
                         receipt.get("native_delivery_evidence"))
        central, head, event = publication_event(registry_root, receipt, outbox)
        proof = (outbox / "publication-evidence.json").read_bytes()
        require(sha256(proof) == event["evidence"][0]["sha256"], "retained publication proof changed")
        retain(Path(registry_root) / event["evidence"][0]["path"], proof)
        result = central.publish(Path(registry_root), event, head)
        require(result.get("event_id") == event["event_id"] and result.get("status") in {"PUBLISHED", "ALREADY_PUBLISHED"},
                "central publication is not confirmed")
        retain(outbox / ("publication-confirmed-" + sha256(encode(result)) + ".json"), encode(result))
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("resolve", "prepare", "verify"):
        item = commands.add_parser(name); item.add_argument("--registry-root", type=Path, required=True)
    commands.choices["prepare"].add_argument("--material-root", type=Path, required=True)
    commands.choices["prepare"].add_argument("--output", type=Path, required=True)
    commands.choices["verify"].add_argument("--bundle", type=Path, required=True)
    delivery = commands.add_parser("record-delivery")
    delivery.add_argument("--root", type=Path, required=True); delivery.add_argument("--registry-root", type=Path, required=True)
    delivery.add_argument("--release-evidence", type=Path, required=True); delivery.add_argument("--owner-pass-reference", required=True)
    delivery.add_argument("--installed-app", type=Path, required=True); delivery.add_argument("--output", type=Path, required=True)
    delivery.add_argument("--native-delivery", type=Path, required=True)
    send = commands.add_parser("publish")
    send.add_argument("--registry-root", type=Path, required=True); send.add_argument("--receipt", type=Path, required=True)
    send.add_argument("--outbox", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "resolve": result = resolve(args.registry_root)
        elif args.command == "prepare": result = prepare(args.registry_root, args.material_root, args.output)
        elif args.command == "verify": result = verify(args.registry_root, args.bundle)
        elif args.command == "record-delivery": result = delivery_receipt(args.root, args.registry_root, args.release_evidence, args.owner_pass_reference, args.installed_app, args.output, args.native_delivery)
        else: result = publish(args.registry_root, args.receipt, args.outbox)
        print(json.dumps(result, ensure_ascii=False, indent=2)); return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("REGISTRY_INTEGRATION_REJECTED: " + str(error), file=sys.stderr); return 2


if __name__ == "__main__":
    sys.exit(main())
