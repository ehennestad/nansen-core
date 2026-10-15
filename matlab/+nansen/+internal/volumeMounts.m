function mounts = volumeMounts(name)
%volumeMounts Where a volume of this name is mounted now (a string row)
%
%   /Volumes on macOS; /media, /run/media and /mnt on Linux; a drive with this
%   label on Windows; and the folders in the NANSEN_VOLUME_ROOTS environment
%   variable (pathsep-separated). Python's nansen.dataset.volume_mounts does the same.
    name = string(name);
    parents = strings(1, 0);
    listed = string(getenv("NANSEN_VOLUME_ROOTS"));
    if listed ~= ""
        parents = split(listed, pathsep)';
        parents = parents(parents ~= "");
    end
    mounts = strings(1, 0);
    if ispc
        for letter = 'A':'Z'
            root = string(letter) + ":\";
            if ~isfolder(root)
                continue
            end
            [status, out] = system("vol " + letter + ":");
            label = regexp(string(out), "is (.+?)\s*$", "tokens", "once", "lineanchors");
            if status == 0 && ~isempty(label) && strtrim(label{1}) == name
                mounts(end + 1) = root; %#ok<AGROW>
            end
        end
    elseif ismac
        parents(end + 1) = "/Volumes";
    else
        user = string(getenv("USER"));
        parents = [parents, "/media/" + user, "/run/media/" + user, "/media", "/mnt"];
    end
    for parent = parents
        candidate = string(fullfile(parent, name));
        if isfolder(candidate) && ~ismember(candidate, mounts)
            mounts(end + 1) = candidate; %#ok<AGROW>
        end
    end
end
