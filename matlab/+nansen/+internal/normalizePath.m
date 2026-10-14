function path = normalizePath(path)
%normalizePath Resolve "." and ".." and use "/" (as Python's os.path.normpath, then "\" -> "/")
    path = replace(string(path), "\", "/");
    parts = split(path, "/")';
    kept = strings(1, 0);
    for part = parts
        if part == "." || (part == "" && ~isempty(kept))
            continue
        elseif part == ".." && ~isempty(kept) && kept(end) ~= ".." && kept(end) ~= ""
            kept(end) = [];
        else
            kept(end + 1) = part; %#ok<AGROW>
        end
    end
    path = join(kept, "/");
    if path == ""
        path = "/";
    end
end
