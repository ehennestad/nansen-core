function inside = pathInVolume(path, name)
%pathInVolume The part of a root path inside its volume ("" for the volume itself), or missing when that cannot be told
%
%   After a drive letter, or after a folder named as the volume
%   (/Volumes/<name>, /media/<user>/<name>...), with "/" between folders.
%   Python's nansen.dataset.path_in_volume does the same.
    text = regexprep(replace(string(path), "\", "/"), "/+", "/");
    drive = regexp(text, "^[A-Za-z]:/?", "match", "once");
    if ~isempty(drive) && strlength(drive) > 0
        inside = strip(extractAfter(text, strlength(drive)), "both", "/");
        return
    end
    parts = split(text, "/")';
    parts = parts(parts ~= "");
    index = find(parts == string(name), 1);
    if isempty(index)
        inside = string(missing);
    else
        inside = strjoin(parts(index + 1:end), "/");
    end
end
