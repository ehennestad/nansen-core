"""Python implementations of the core module's methods."""

import csv
import shutil
import time
from pathlib import Path


def file_stats(entity, options, context):
    """Count the files in the entity's folders in every data location, and their total size in MB."""
    dataset = context.project.dataset
    count, total = 0, 0
    for location in entity.locations:
        root = dataset.root(location["dataLocationIdentifier"], location["rootStoragePathIdentifier"]).path
        for relative in location["paths"]:
            path = root / relative
            files = [path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()] if path.is_dir() else []
            for file in files:
                if not options["includeHidden"] and any(part.startswith(".") for part in file.relative_to(root).parts):
                    continue
                count += 1
                total += file.stat().st_size
    context.log(f"{' / '.join(map(str, entity.key.values()))}: {count} files")
    return {"n_files": count, "size_mb": round(total / 1e6, 6)}


def export_keys(entities, options, context):
    """Write the selected entities' keys to exports/<fileName> in the project folder."""
    folder = Path(context.project.folder) / "exports"
    folder.mkdir(exist_ok=True)
    path = folder / options["fileName"]
    names = list(entities[0].key) if entities else []
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(names)
        for entity in entities:
            writer.writerow([entity.key[n] for n in names])
    context.log(f"wrote {len(entities)} keys to {path}")
    return {"path": str(path), "count": len(entities)}


def wait(entity, options, context):
    """Wait in steps, reporting progress and stopping when cancelled."""
    steps = options["steps"]
    for step in range(steps):
        context.check_cancelled()
        time.sleep(options["seconds"] / steps)
        context.progress((step + 1) / steps, f"{options['message']} {step + 1}/{steps}")
    context.log(f"{' / '.join(map(str, entity.key.values()))}: done {options['message']}")
    if options["fail"]:
        raise RuntimeError("failed on purpose")
    return {"waited": options["seconds"]}


def backup(entity, options, context):
    """Copy the entity's folders to <destination>/<data location>/<the same path>, leaving up-to-date copies alone."""
    dataset = context.project.dataset
    destination = Path(options["destination"])
    if not destination.is_absolute():
        destination = Path(context.project.folder) / destination
    destination = destination.resolve()
    copied, unchanged, size = 0, 0, 0
    for location in entity.locations:
        if options["dataLocation"] and location["dataLocationIdentifier"] != options["dataLocation"]:
            continue
        root = dataset.root(location["dataLocationIdentifier"], location["rootStoragePathIdentifier"]).path.resolve()
        for relative in location["paths"]:
            source = root / relative
            if destination == source or source in destination.parents:
                raise ValueError(f"the destination {destination} is inside {source}")
            files = [source] if source.is_file() else sorted(p for p in source.rglob("*") if p.is_file()) if source.is_dir() else []
            for file in files:
                target = destination / location["dataLocationIdentifier"] / file.relative_to(root)
                info = file.stat()
                if not options["overwrite"] and target.is_file():
                    copy = target.stat()
                    if copy.st_size == info.st_size and copy.st_mtime + 1 >= info.st_mtime:
                        unchanged += 1
                        continue
                context.check_cancelled()
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(file, target)
                copied += 1
                size += info.st_size
    context.log(f"{' / '.join(map(str, entity.key.values()))}: {copied} copied, {unchanged} up to date")
    return {"copied": copied, "unchanged": unchanged, "size_mb": round(size / 1e6, 6)}
